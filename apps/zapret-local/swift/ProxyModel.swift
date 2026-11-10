import Foundation
import ServiceManagement
import AppKit
import Darwin
import Combine
import OSLog

struct StrategySelection: Codable, Equatable, Sendable {
    var strategy = "general-exp"
    var ipset = "cloudflare"
}

struct ProxySettings: Codable, Sendable {
    var port: UInt16 = 49956
    var lastEnabled = false
    var selection: StrategySelection?
}

struct ProxyState: Sendable {
    var port: UInt16 = 49956
    var running = false
    var enabled = false
    var error: String?
    var selection = StrategySelection()
}

actor ProxyService {
    private let checkTunnel: () throws -> Void
    private let profile: () throws -> Data
    private let clientFactory: () throws -> HelperClient
    private let logger = Logger(subsystem: "com.jellybebra.zapret-cudy", category: "lifecycle")
    private var recoveryPending = false
    private var settings = ProxySettings()
    private var client: HelperClient?
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
        let node = try nodeOverride ?? profile()
        try checkTunnel()
        try checkPort(settings.port)
        try connect(allowInstall: allowInstall)
        let reply = try client!.request("start", port: settings.port, selection: settings.selection ?? StrategySelection(), node: node)
        running = reply.running
        logger.notice("Proxy start replied: ok=\(reply.ok), running=\(reply.running)")
        guard reply.ok, reply.running, reply.port == settings.port else {
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

    func state() -> ProxyState {
        return ProxyState(port: settings.port, running: running, enabled: settings.lastEnabled, error: error, selection: settings.selection ?? StrategySelection())
    }

    func choose(_ candidate: ProxyServer) -> ProxyState {
        error = nil
        do {
            if settings.lastEnabled {
                let previous = try profile()
                try VLESSProfile.probe(candidate)
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

    func resume() -> ProxyState {
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
    @Published private(set) var state = ProxyState()
    @Published private(set) var busy = false
    @Published var notice: String?
    @Published private(set) var servers: [ProxyServer] = []
    @Published private(set) var selectedServer: ProxyServer?

    func refreshServers() {
        do {
            apply(try ServerStore.shared.read())
        } catch { notice = error.localizedDescription }
    }

    private func apply(_ library: ServerLibrary) {
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
        Task {
            update(await service.choose(server))
            refreshServers()
            busy = false
        }
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

    private func update(_ newState: ProxyState) { state = newState }

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
        Task { await service.shutdown(); completion() }
    }
}
