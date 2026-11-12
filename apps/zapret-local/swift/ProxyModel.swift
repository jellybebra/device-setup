import Foundation
import ServiceManagement
import AppKit
import Darwin
import Combine
import OSLog

struct StrategySelection: Codable, Equatable, Sendable {
    var strategy = "general-exp"
    var ipset = "cloudflare"
    var custom: CustomPolicyConfiguration?
    var networkProfiles: [NetworkRuleProfile]?
}

struct ProxySettings: Codable, Sendable {
    var port: UInt16 = 49956
    var defaultConfiguration: ProfileConfiguration? // Legacy Wi-Fi storage, removed during migration.
    var selectedProfileID: String?
    var configurations: [ProfileConfiguration]?
    var lastEnabled = false
    var fastRetry: Bool?
    var selection: StrategySelection?
}

struct ProxyState: Sendable {
    var port: UInt16 = 49956
    var running = false
    var enabled = false
    var fastRetry = false
    var error: String?
    var selection = StrategySelection()
    var configurations: [ProfileConfiguration] = []
    var selectedProfileID: String?
    var activeConfiguration: ProfileConfiguration?
}

actor ProxyService {
    private let checkTunnel: () throws -> Void
    private let profile: () throws -> Data
    private let clientFactory: () throws -> HelperClient
    private let logger = Logger(subsystem: "com.jellybebra.zapret-cudy", category: "lifecycle")
    private var recoveryPending = false
    private var migrateSettings = false
    private var settings = ProxySettings()
    private var client: HelperClient?
    private var activeConfiguration: ProfileConfiguration?
    private var running = false
    private var error: String?
    private var reconnectAfter = Date.distantPast
    private let settingsURL: URL

    init(settingsURL: URL? = nil, profile: @escaping () throws -> Data = VLESSProfile.load,
         checkTunnel: @escaping () throws -> Void = ProxyService.checkTunnelConflict,
         clientFactory: @escaping () throws -> HelperClient = { try HelperClient() }) {
        self.profile = profile
        self.checkTunnel = checkTunnel
        self.clientFactory = clientFactory
        self.settingsURL = settingsURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.jellybebra.zapret-cudy", isDirectory: true)
            .appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: self.settingsURL.path) {
            do {
                settings = try JSONDecoder().decode(ProxySettings.self, from: Data(contentsOf: self.settingsURL))
                try Self.validatePort(settings.port)
                let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: self.settingsURL)) as? [String: Any]
                let configs = (raw?["configurations"] as? [[String: Any]] ?? []) + [raw?["defaultConfiguration"] as? [String: Any]].compactMap { $0 }
                migrateSettings = configs.contains { $0["savedAt"] != nil || $0["server"] != nil || $0["port"] != nil }
            } catch {
                settings = ProxySettings()
                self.error = "Не удалось прочитать настройки. Укажите порт заново"
            }
        }
    }

    static func checkTunnelConflict() throws {
        let probe = Process()
        guard let exe = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("zapret-helper") else {
            throw ProxyError("Не найден сетевой помощник")
        }
        probe.executableURL = exe
        probe.arguments = ["--check-tun"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else {
            throw ProxyError("Системный маршрут уже занят другим TUN либо недоступен")
        }
    }

    static func validatePort(_ port: UInt16) throws {
        guard port >= 1024, !(41000...42023).contains(port) else {
            throw ProxyError("Порт: 1024–65535, кроме служебных 41000–42023")
        }
    }

    private func checkPort(_ port: UInt16) throws {
        try Self.validatePort(port)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyError("Не удалось проверить порт") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // A user-owned bind can fail on TIME_WAIT sockets from the broker's UID
        // after a clean restart. Detect listeners here; the helper owns the final bind.
        guard result != 0 else { throw ProxyError("Порт \(port) уже занят. Выберите другой") }
        guard errno == ECONNREFUSED else { throw ProxyError("Не удалось проверить порт \(port)") }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(settings)
        try data.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    private func connect(allowInstall: Bool) throws {
        if client != nil { return }
        // An authenticated error status describes the previous worker failure;
        // it does not mean the helper needs reinstalling.
        if let connection = try? clientFactory(), (try? connection.request("status")) != nil {
            client = connection
            return
        }
        guard allowInstall else { throw ProxyError("Нажмите «Включить», чтобы установить помощник") }
        try HelperInstaller.install()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let connection = try? clientFactory(), (try? connection.request("status")) != nil {
                client = connection
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ProxyError("Помощник не запустился после установки")
    }

    private func start(allowInstall: Bool, nodeOverride: Data? = nil) throws {
        if running { return }
        try connect(allowInstall: allowInstall)
        let configuration = selectedConfiguration
        if let config = configuration {
            let policy = try inspectPolicy(selection: config.selection, networkKey: nil)
            guard try ProfileConfiguration.canonical(policy) == ProfileConfiguration.canonical(config.policy) else {
                throw ProxyError("Движок изменился: профиль «\(config.name)» требует проверки и повторного сохранения")
            }
        }
        let port = settings.port
        let node = try VLESSProfile.connectionProfile(nodeOverride ?? profile(), fastRetry: configuration?.fastRetry ?? settings.fastRetry ?? false)
        try checkTunnel()
        try checkPort(port)
        let reply = try client!.request("start", port: port, selection: configuration?.selection ?? settings.selection ?? StrategySelection(), node: node)
        activeConfiguration = configuration
        running = reply.running
        logger.notice("Proxy start replied: ok=\(reply.ok), running=\(reply.running)")
        guard reply.ok, reply.running, reply.port == port else {
            // A failed network activation must not be retried by the periodic status poll.
            settings.lastEnabled = false
            recoveryPending = false
            try save()
            throw ProxyError(reply.error ?? "Не удалось запустить маршрутизацию")
        }
    }

    private func stop() throws {
        logger.notice("Stopping network session")
        if let client {
            let reply: HelperReply
            do { reply = try client.request("stop") }
            catch {
                client.disconnect()
                self.client = nil
                running = false
                throw error
            }
            running = reply.running
            logger.notice("Proxy stop replied: ok=\(reply.ok), running=\(reply.running)")
            guard reply.ok, !reply.running else { throw ProxyError(reply.error ?? "Не удалось остановить прокси") }
        }
        running = false
    }

    private var selectedConfiguration: ProfileConfiguration? {
        settings.configurations?.first { $0.key == settings.selectedProfileID }
    }

    func state() -> ProxyState {
        return ProxyState(port: settings.port, running: running, enabled: settings.lastEnabled, fastRetry: selectedConfiguration?.fastRetry ?? settings.fastRetry ?? false, error: error, selection: selectedConfiguration?.selection ?? settings.selection ?? StrategySelection(), configurations: settings.configurations ?? [], selectedProfileID: settings.selectedProfileID, activeConfiguration: activeConfiguration)
    }

    func choose(_ candidate: ProxyServer) -> ProxyState {
        error = nil
        do {
            if settings.lastEnabled {
                let previous = try profile()
                try VLESSProfile.probe(candidate, fastRetry: activeConfiguration?.fastRetry ?? settings.fastRetry ?? false)
                try stop()
                do {
                    try start(allowInstall: false, nodeOverride: candidate.outbound)
                    try VLESSProfile.save(candidate)
                } catch {
                    let failure = error.localizedDescription
                    try stop()
                    settings.lastEnabled = true
                    try save()
                    try start(allowInstall: false, nodeOverride: previous)
                    throw ProxyError("Смена сервера не удалась. Восстановлен предыдущий сервер. " + failure)
                }
            } else {
                try VLESSProfile.save(candidate)
            }
        } catch { self.error = error.localizedDescription }
        return state()
    }

    func setPort(_ port: UInt16) -> ProxyState {
        guard port != settings.port else { return state() }
        let previous = settings.port
        let wasEnabled = settings.lastEnabled
        var stopped = false
        error = nil
        do {
            try checkPort(port)
            if running { stopped = true; try stop() }
            settings.port = port
            if wasEnabled { try start(allowInstall: false) }
            try save()
        } catch {
            let failure = error.localizedDescription
            settings.port = previous
            if stopped {
                do { try stop(); settings.lastEnabled = wasEnabled; try save(); if wasEnabled { try start(allowInstall: false) } }
                catch { self.error = failure + ". Восстановление: " + error.localizedDescription; return state() }
            }
            self.error = failure
        }
        return state()
    }

    func setFastRetry(_ enabled: Bool) -> ProxyState {
        if var config = activeConfiguration { config.fastRetry = enabled; return saveConfiguration(config) }
        guard enabled != (settings.fastRetry ?? false) else { return state() }
        let previous = settings.fastRetry
        let wasEnabled = settings.lastEnabled
        error = nil
        do {
            settings.fastRetry = enabled
            try save()
            if wasEnabled {
                try stop()
                try start(allowInstall: false)
            }
        } catch {
            let failure = error.localizedDescription
            settings.fastRetry = previous
            settings.lastEnabled = wasEnabled
            do {
                try save()
                if wasEnabled {
                    try stop()
                    try start(allowInstall: false)
                }
                self.error = "Настройка не применена. " + failure
            } catch {
                settings.lastEnabled = false
                try? save()
                self.error = "Не удалось восстановить подключение. " + error.localizedDescription
            }
        }
        return state()
    }

    func resume() -> ProxyState {
        do { try migrateWiFiConfigurations() }
        catch { self.error = "Не удалось перенести профили: " + error.localizedDescription; return state() }
        if migrateSettings {
            do { try save(); migrateSettings = false }
            catch { self.error = "Не удалось обновить настройки: " + error.localizedDescription; return state() }
        }
        if settings.lastEnabled {
            do { try start(allowInstall: false) }
            catch { self.error = error.localizedDescription }
        }
        return state()
    }

    func setEnabled(_ enabled: Bool) -> ProxyState {
        error = nil
        do {
            // Record user intent before cleanup: a failed stop must never re-enable us.
            settings.lastEnabled = enabled
            recoveryPending = false
            try save()
            logger.notice("User requested enabled=\(enabled)")
            if enabled { try start(allowInstall: true) } else { try stop() }
        } catch {
            self.error = error.localizedDescription
            if enabled {
                try? stop()
                settings.lastEnabled = false
                try? save()
            }
        }
        return state()
    }

    func currentNetwork() throws -> HelperReply {
        try connect(allowInstall: false)
        let reply = try client!.request("network")
        guard reply.ok, reply.networkKey != nil else { throw ProxyError(reply.error ?? "Не удалось определить сеть") }
        return reply
    }

    func inspectPolicy(selection: StrategySelection, networkKey: String?) throws -> PolicySnapshot {
        try connect(allowInstall: false)
        let reply = try client!.request("policy", selection: selection, timeout: 10, networkKey: networkKey)
        guard reply.ok, let policy = reply.policy else { throw ProxyError(reply.error ?? "Не удалось прочитать правила") }
        return policy
    }

    func setNetworkProfiles(_ profiles: [NetworkRuleProfile]) -> ProxyState {
        let previous = settings
        error = nil
        var selection = settings.selection ?? StrategySelection()
        selection.networkProfiles = profiles
        do { try NetworkRuleProfile.validate(selection) }
        catch { self.error = error.localizedDescription; return state() }
        do {
            if settings.lastEnabled { try stop() }
            settings.selection = selection
            if previous.lastEnabled { try start(allowInstall: false) }
            try save()
        } catch {
            let failure = error.localizedDescription
            try? stop()
            settings = previous
            do {
                try save()
                if previous.lastEnabled { try start(allowInstall: false) }
                self.error = "Правила не применены. Восстановлены прежние настройки. " + failure
            } catch { self.error = failure + ". Восстановление: " + error.localizedDescription }
        }
        return state()
    }

    private func migrateWiFiConfigurations() throws {
        guard settings.selectedProfileID == nil,
              settings.defaultConfiguration != nil || !(settings.configurations ?? []).isEmpty else { return }
        let before = settings
        do {
            try connect(allowInstall: false)
            // Only migration consults the former binding, to retain the currently used profile.
            let previousKey = (try? client!.request("network"))?.networkKey
            var old = settings.configurations ?? []
            if let base = settings.defaultConfiguration { old.append(base) }
            var converted: [ProfileConfiguration] = []
            var selectedID: String?
            for previous in old {
                var config = try EditableProfileConfiguration(previous).updating(previous)
                config.key = UUID().uuidString
                config.name = ProfileConfiguration.availableName(previous.name, among: converted.map(\.name))
                config.policy = try inspectPolicy(selection: config.selection, networkKey: nil)
                if previous.key == previousKey { selectedID = config.key }
                converted.append(config)
            }
            settings.configurations = converted
            settings.selectedProfileID = selectedID ?? converted.first?.key
            settings.defaultConfiguration = nil
            settings.selection = nil; settings.fastRetry = nil
            try save()
            migrateSettings = false
        } catch { settings = before; throw error }
    }

    func newConfiguration() -> (ProxyState, ProfileConfiguration?) {
        error = nil
        do {
            try connect(allowInstall: true)
            var selection = settings.selection ?? StrategySelection(); selection.networkProfiles = nil
            let policy = try inspectPolicy(selection: selection, networkKey: nil)
            let initial = ProfileConfiguration(key: UUID().uuidString,
                name: ProfileConfiguration.availableName("Новый профиль", among: (settings.configurations ?? []).map(\.name)),
                fastRetry: false, selection: selection, policy: policy)
            let config = try EditableProfileConfiguration(initial).updating(initial)
            return (state(), config)
        } catch { self.error = error.localizedDescription; return (state(), nil) }
    }

    func createConfiguration(copying key: String) -> ProxyState {
        error = nil
        guard let original = settings.configurations?.first(where: { $0.key == key }) else {
            error = "Профиль не найден"; return state()
        }
        let config = original.copied(to: UUID().uuidString, name: ProfileConfiguration.copyName(original.name, among: (settings.configurations ?? []).map(\.name)))
        return saveConfiguration(config)
    }

    func selectConfiguration(_ key: String) -> ProxyState {
        guard key != settings.selectedProfileID else { return state() }
        let before = settings
        var activationAttempted = false
        error = nil
        do {
            guard let config = settings.configurations?.first(where: { $0.key == key }) else { throw ProxyError("Профиль не найден") }
            let policy = try inspectPolicy(selection: config.selection, networkKey: nil)
            guard try ProfileConfiguration.canonical(policy) == ProfileConfiguration.canonical(config.policy) else { throw ProxyError("Профиль требует проверки после обновления движка") }
            settings.selectedProfileID = key
            if before.lastEnabled { activationAttempted = true; try stop(); try start(allowInstall: false) }
            try save()
        } catch {
            let failure = error.localizedDescription
            settings = before
            if activationAttempted {
                do { try stop(); try save(); if before.lastEnabled { try start(allowInstall: false) } }
                catch { self.error = failure + ". Восстановление: " + error.localizedDescription; return state() }
            }
            self.error = "Профиль не переключён: " + failure
        }
        return state()
    }

    func removeConfiguration(_ key: String) -> ProxyState {
        error = nil
        let before = settings
        do {
            guard key != settings.selectedProfileID else { throw ProxyError("Сначала выберите другой профиль") }
            settings.configurations?.removeAll { $0.key == key }
            try save()
        } catch { settings = before; self.error = error.localizedDescription }
        return state()
    }

    func saveConfiguration(_ configuration: ProfileConfiguration) -> ProxyState {
        let before = settings
        let wasEnabled = settings.lastEnabled
        var activationAttempted = false
        error = nil
        do {
            var updated = configuration
            updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !updated.name.isEmpty && updated.name.count <= 100 else { throw ProxyError("Название профиля: от 1 до 100 символов") }
            guard !(settings.configurations ?? []).contains(where: { $0.key != updated.key && $0.name.localizedCaseInsensitiveCompare(updated.name) == .orderedSame }) else { throw ProxyError("Профиль с таким названием уже существует") }
            guard updated.selection.networkProfiles?.isEmpty != false else { throw ProxyError("Профиль не должен содержать привязку к сети") }
            try NetworkRuleProfile.validate(updated.selection)
            updated.policy = try inspectPolicy(selection: updated.selection, networkKey: nil)
            let validation = try client!.request("validate", port: settings.port, selection: updated.selection)
            guard validation.ok else { throw ProxyError(validation.error ?? "Ошибка проверки конфигурации") }
            let previous = selectedConfiguration
            var configs = settings.configurations ?? []
            if let index = configs.firstIndex(where: { $0.key == updated.key }) { configs[index] = updated }
            else { configs.append(updated) }
            settings.configurations = configs
            if settings.selectedProfileID == nil { settings.selectedProfileID = updated.key }
            let changed = previous?.selection != updated.selection || previous?.fastRetry != updated.fastRetry
            if settings.selectedProfileID == updated.key && changed && wasEnabled {
                activationAttempted = true
                try stop(); try start(allowInstall: false)
            } else if activeConfiguration?.key == updated.key { activeConfiguration = updated }
            try save()
        } catch {
            let failure = error.localizedDescription
            settings = before
            if !activationAttempted {
                self.error = "Конфигурация не применена: " + failure
                return state()
            }
            do {
                try stop(); try save()
                if wasEnabled { try start(allowInstall: false) }
                self.error = "Изменения не применены; восстановлена сохранённая конфигурация. " + failure
            } catch { self.error = failure + ". Восстановление: " + error.localizedDescription }
        }
        return state()
    }

    func networkDidWake() {
        recoveryPending = settings.lastEnabled
        logger.notice("System woke; recovery pending=\(self.recoveryPending)")
    }

    func refresh() -> ProxyState {
        if recoveryPending {
            recoveryPending = false
            if settings.lastEnabled {
                logger.notice("Restarting local proxy after wake")
                do { try stop() }
                catch {
                    self.error = error.localizedDescription
                    reconnectAfter = Date().addingTimeInterval(10)
                    return state()
                }
                reconnectAfter = .distantPast
            }
        }
        if let client {
            do {
                let reply = try client.request("status")
                if running && !reply.running {
                    error = reply.error ?? "Прокси остановлен. Проверьте подключение к сети"
                }
                running = reply.running
                if !reply.ok { error = reply.error ?? "Ошибка сетевого помощника" }
            } catch {
                self.client = nil
                running = false
                self.error = error.localizedDescription
                logger.error("Helper status failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !running && settings.lastEnabled && Date() >= reconnectAfter {
            reconnectAfter = Date().addingTimeInterval(10)
            do { try start(allowInstall: false); error = nil }
            catch { self.error = error.localizedDescription }
        }
        return state()
    }

    func shutdown() {
        // Keep the last chosen state for the next launch, but terminate the
        // running session. EOF is also watched by the privileged service.
        try? stop()
        client = nil
    }
}

@MainActor
final class ProxyModel: ObservableObject {
    let probes = ServerProbes()
    @Published private(set) var state = ProxyState()
    @Published private(set) var busy = false
    @Published var notice: String?
    @Published private(set) var servers: [ProxyServer] = []
    @Published private(set) var selectedServer: ProxyServer?
    @Published private(set) var pendingServerID: String?

    func refreshServers() {
        do {
            apply(try ServerStore.shared.read())
        } catch { notice = error.localizedDescription }
    }

    private func apply(_ library: ServerLibrary) {
        probes.reconcile(library.servers)
        servers = library.servers
        selectedServer = library.selected
        notice = servers.isEmpty ? "Добавьте VLESS-сервер в меню «Управление серверами»" : nil
    }

    func saveServer(id: String?, name: String, link: String) throws {
        guard !busy else { throw ProxyError("Дождитесь завершения переключения") }
        let library = try ServerStore.shared.change { library in
            var server: ProxyServer
            if let id {
                guard let existing = library.servers.first(where: { $0.id == id }) else { throw ProxyError("Сервер уже удалён") }
                if link.isEmpty {
                    server = existing
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { throw ProxyError("Укажите название сервера") }
                    server.name = title
                } else {
                    guard library.selectedID != id || !state.enabled else {
                        throw ProxyError("Для замены ссылки сначала выберите другой сервер или выключите V2DPI")
                    }
                    server = try ProxyServer.fromLink(link, name: name, id: id)
                }
            } else {
                server = try ProxyServer.fromLink(link, name: name)
            }
            try library.put(server)
        }
        apply(library)
    }

    func removeServer(_ id: String) throws {
        guard !busy else { throw ProxyError("Дождитесь завершения переключения") }
        apply(try ServerStore.shared.change { try $0.remove(id, enabled: state.enabled) })
    }

    func choose(_ server: ProxyServer) {
        guard !busy, server.id != selectedServer?.id else { return }
        busy = true
        pendingServerID = server.id
        Task {
            defer {
                pendingServerID = nil
                busy = false
            }
            update(await service.choose(server))
            refreshServers()
        }
    }
    func saveConfiguration(_ configuration: ProfileConfiguration) async {
        guard !busy else { return }; busy = true
        update(await service.saveConfiguration(configuration)); busy = false
    }

    func newConfiguration() async -> ProfileConfiguration? {
        guard !busy else { return nil }; busy = true
        let (state, config) = await service.newConfiguration()
        update(state); busy = false
        return config
    }

    func createConfiguration(copying key: String) async -> ProfileConfiguration? {
        guard !busy else { return nil }; busy = true
        let previous = Set(state.configurations.map(\.key))
        update(await service.createConfiguration(copying: key)); busy = false
        return state.configurations.first { !previous.contains($0.key) }
    }

    func selectConfiguration(_ key: String) {
        guard !busy else { return }; busy = true
        Task { await probes.shutdown(); update(await service.selectConfiguration(key)); busy = false }
    }

    func removeConfiguration(_ key: String) async {
        guard !busy else { return }; busy = true
        update(await service.removeConfiguration(key)); busy = false
    }

    private let service = ProxyService()
    private var monitor: Task<Void, Never>?
    private var wakeObserver: AnyCancellable?

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.service.networkDidWake() }
            }
        monitor = Task { [weak self] in
            guard let self else { return }
            self.update(await service.state())
            self.busy = true
            self.update(await service.resume())
            self.busy = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                if !self.busy { self.update(await service.refresh()) }
            }
        }
    }

    private func update(_ newState: ProxyState) {
        state = newState
        probes.setFastRetry(newState.fastRetry)
    }

    func setFastRetry(_ enabled: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            await probes.shutdown()
            update(await service.setFastRetry(enabled))
            busy = false
        }
    }

    func setPort(_ port: UInt16) async {
        guard !busy else { return }; busy = true
        update(await service.setPort(port)); busy = false
    }

    func toggle() {
        guard !busy else { return }
        busy = true
        notice = nil
        let enable = !state.enabled
        Task {
            update(await service.setEnabled(enable))
            busy = false
        }
    }

    func shutdown(completion: @escaping @MainActor () -> Void) {
        busy = true
        wakeObserver?.cancel()
        monitor?.cancel()
        Task { await probes.shutdown(); await service.shutdown(); completion() }
    }
}
