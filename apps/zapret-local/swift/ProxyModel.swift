import Foundation
import ServiceManagement
import AppKit
import Darwin

struct StrategySelection: Codable, Equatable, Sendable {
    var strategy = "local"
    var ipset = "cloudflare"
}

struct StrategyPreset: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    static let all: [StrategyPreset] = {
        let local = StrategyPreset(id: "local", title: "Моя проверенная настройка")
        guard let file = Bundle.main.resourceURL?.appendingPathComponent("engine/strategies.json"),
              let data = try? Data(contentsOf: file),
              let presets = try? JSONDecoder().decode([StrategyPreset].self, from: data) else { return [local] }
        return [local] + presets
    }()
}

struct ProxySettings: Codable, Sendable {
    var port: UInt16 = 49946
    var lastEnabled = false
    var selection: StrategySelection?
}

struct ProxyState: Sendable {
    var port: UInt16 = 49946
    var running = false
    var error: String?
    var telegram = TelegramState()
    var selection = StrategySelection()
}

actor ProxyService {
    private let telegram = TelegramBridge()
    private var settings = ProxySettings()
    private var client: HelperClient?
    private var running = false
    private var error: String?
    private var reconnectAfter = Date.distantPast
    private let settingsURL: URL

    init() {
        settingsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.jellybebra.zapret-local", isDirectory: true)
            .appendingPathComponent("settings.json")
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                settings = try JSONDecoder().decode(ProxySettings.self, from: Data(contentsOf: settingsURL))
                try Self.validatePort(settings.port)
            } catch {
                settings = ProxySettings()
                self.error = "Не удалось прочитать настройки. Укажите порт заново"
            }
        }
    }

    static func validatePort(_ port: UInt16) throws {
        guard port >= 1024, !(42600...43623).contains(port) else {
            throw ProxyError("Порт: 1024–65535, кроме служебных 42600–43623")
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
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(settings)
        try data.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    private func connect(allowInstall: Bool) throws {
        if client != nil { return }
        if let connection = try? HelperClient(), let status = try? connection.request("status"), status.ok {
            client = connection
            return
        }
        guard allowInstall else { throw ProxyError("Нажмите «Включить», чтобы установить помощник") }
        try HelperInstaller.install()
        for _ in 0..<50 {
            if let connection = try? HelperClient(), let status = try? connection.request("status"), status.ok {
                client = connection
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ProxyError("Помощник не запустился после установки")
    }

    private func start(allowInstall: Bool) throws {
        if running { return }
        try checkPort(settings.port)
        try connect(allowInstall: allowInstall)
        let reply = try client!.request("start", port: settings.port, selection: settings.selection ?? StrategySelection())
        running = reply.running
        guard reply.ok, reply.running, reply.port == settings.port else {
            throw ProxyError(reply.error ?? "Не удалось запустить прокси")
        }
    }

    private func stop() throws {
        telegram.stop()
        if let client {
            let reply = try client.request("stop")
            running = reply.running
            guard reply.ok, !reply.running else { throw ProxyError(reply.error ?? "Не удалось остановить прокси") }
        }
        running = false
    }

    func state() -> ProxyState {
        telegram.sync(enabled: running, socks: settings.port)
        return ProxyState(port: settings.port, running: running, error: error, telegram: telegram.state, selection: settings.selection ?? StrategySelection())
    }

    func telegramURL() -> URL? { telegram.connectionURL() }

    func setTelegramPort(_ port: UInt16) -> ProxyState {
        error = nil
        do { try telegram.setPort(port, socks: settings.port, enabled: running) }
        catch { self.error = error.localizedDescription }
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
            if enabled { try start(allowInstall: true) } else { try stop() }
            settings.lastEnabled = enabled
            try save()
        } catch { self.error = error.localizedDescription }
        return state()
    }

    func setPort(_ port: UInt16) -> ProxyState {
        guard port != settings.port else { return state() }
        error = nil
        let previous = settings.port
        let wasRunning = running
        do {
            guard port != telegram.state.port else { throw ProxyError("Порты Telegram и Zapret должны отличаться") }
            try checkPort(port)
            if wasRunning { try stop() }
            settings.port = port
            do {
                if wasRunning { try start(allowInstall: false) }
                try save()
            } catch {
                try? stop()
                settings.port = previous
                if wasRunning { try? start(allowInstall: false) }
                throw error
            }
        } catch { self.error = error.localizedDescription }
        return state()
    }

    func setSelection(_ selection: StrategySelection, force: Bool = false) -> ProxyState {
        guard force || selection != (settings.selection ?? StrategySelection()) else { return state() }
        guard StrategyPreset.all.contains(where: { $0.id == selection.strategy }),
              ["none", "cloudflare", "loaded", "any"].contains(selection.ipset) else {
            error = "Неизвестная стратегия"; return state()
        }
        let previous = settings.selection
        let wasRunning = running || settings.lastEnabled
        error = nil
        do {
            try stop()
            settings.selection = selection
            do {
                if wasRunning { try start(allowInstall: true) }
                try save()
            } catch {
                try? stop()
                settings.selection = previous
                if wasRunning { try? start(allowInstall: false) }
                throw error
            }
        } catch { self.error = error.localizedDescription }
        return state()
    }

    func refresh() -> ProxyState {
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
    @Published private(set) var autostart = false
    @Published var portText = "49946"
    @Published var telegramPortText = "44950"
    @Published var notice: String?
    private let service = ProxyService()
    private var monitor: Task<Void, Never>?

    init() {
        autostart = SMAppService.mainApp.status == .enabled
        monitor = Task { [weak self] in
            guard let self else { return }
            self.update(await service.state())
            self.busy = true
            self.update(await service.resume())
            self.busy = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if !self.busy { self.update(await service.refresh(), updatePort: false) }
            }
        }
    }

    private func update(_ newState: ProxyState, updatePort: Bool = true) {
        state = newState
        if updatePort {
            portText = String(newState.port)
            telegramPortText = String(newState.telegram.port)
        }
    }

    func toggle() {
        guard !busy else { return }
        busy = true
        notice = nil
        let enable = !state.running
        Task {
            update(await service.setEnabled(enable))
            busy = false
        }
    }

    func applyPort() {
        guard !busy else { return }
        guard let port = UInt16(portText), (try? ProxyService.validatePort(port)) != nil else {
            notice = "Порт: 1024–65535, кроме служебных 42600–43623"
            return
        }
        busy = true
        notice = nil
        Task {
            update(await service.setPort(port))
            busy = false
        }
    }

    func selectStrategy(_ id: String) {
        var selection = state.selection; selection.strategy = id; applySelection(selection)
    }

    func applyTelegramPort() {
        guard !busy else { return }
        guard let port = UInt16(telegramPortText), (try? ProxyService.validatePort(port)) != nil else {
            notice = "Порт: 1024–65535, кроме служебных 42600–43623"
            return
        }
        busy = true; notice = nil
        Task {
            update(await service.setTelegramPort(port))
            busy = false
        }
    }

    func copyTelegram() {
        Task {
            if let url = await service.telegramURL() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }

    func selectIPSet(_ mode: String) {
        var selection = state.selection; selection.ipset = mode; applySelection(selection)
    }

    func reconnect() { applySelection(state.selection, force: true) }

    private func applySelection(_ selection: StrategySelection, force: Bool = false) {
        guard !busy else { return }
        busy = true; notice = nil
        Task {
            update(await service.setSelection(selection, force: force))
            busy = false
        }
    }

    func setAutostart(_ enabled: Bool) {
        guard !busy else { return }
        notice = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            autostart = SMAppService.mainApp.status == .enabled
            if enabled && SMAppService.mainApp.status == .requiresApproval {
                notice = "Разрешите автозапуск в настройках macOS"
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            notice = "Не удалось изменить автозапуск: \(error.localizedDescription)"
            autostart = SMAppService.mainApp.status == .enabled
        }
    }

    func appeared() { autostart = SMAppService.mainApp.status == .enabled }

    func copyProxy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("socks://127.0.0.1:\(state.port)#Zapret-Local", forType: .string)
    }

    func connectTelegram() {
        Task {
            if let url = await service.telegramURL() { NSWorkspace.shared.open(url) }
        }
    }

    func shutdown(completion: @escaping @MainActor () -> Void) {
        monitor?.cancel()
        Task { await service.shutdown(); completion() }
    }
}
