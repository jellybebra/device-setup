import Foundation
import Security
import Darwin

struct TelegramState: Sendable {
    var port: UInt16 = 44950
    var running = false
    var error: String?
}

private struct TelegramSettings: Codable {
    var port: UInt16
    var secret: String
}

// Owned exclusively by ProxyService. No independent LaunchAgent or system Python.
final class TelegramBridge {
    private let root: URL
    private var settings: TelegramSettings?
    private var process: Process?
    private var lifetime: Pipe?
    private var log: FileHandle?
    private var socksPort: UInt16?
    private var retryAfter = Date.distantPast
    private(set) var state = TelegramState()

    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.jellybebra.zapret-local/telegram", isDirectory: true)
        if let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
           let saved = try? JSONDecoder().decode(TelegramSettings.self, from: data),
           (try? valid(saved)) != nil {
            settings = saved
            state.port = saved.port
        }
    }

    private func valid(_ value: TelegramSettings) throws {
        guard value.port >= 1024, value.secret.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
            throw ProxyError("Некорректные настройки Telegram")
        }
    }

    private func newPort(avoiding socks: UInt16) throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyError("Не удалось выбрать порт Telegram") }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = (socks == 44950 ? UInt16(0) : UInt16(44950)).bigEndian
        func bindAddress() -> Int32 {
            withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }
        }
        if bindAddress() != 0 {
            address.sin_port = 0
            guard bindAddress() == 0 else { throw ProxyError("Не удалось выбрать порт Telegram") }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &size)
        } }
        guard result == 0 else { throw ProxyError("Не удалось прочитать порт Telegram") }
        return UInt16(bigEndian: address.sin_port)
    }

    private func launchctl(_ args: [String]) throws -> Int32 {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        command.arguments = args
        command.standardOutput = FileHandle.nullDevice
        command.standardError = FileHandle.nullDevice
        try command.run()
        command.waitUntilExit()
        return command.terminationStatus
    }

    private func prepare(socks: UInt16) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("settings.json")
        let support = root.deletingLastPathComponent().deletingLastPathComponent()
        let legacy = support.appendingPathComponent("Zapret Local Telegram")
        if settings == nil {
            if fm.fileExists(atPath: file.path) {
                settings = try JSONDecoder().decode(TelegramSettings.self, from: Data(contentsOf: file))
            } else if fm.fileExists(atPath: legacy.appendingPathComponent("settings.json").path) {
                settings = try JSONDecoder().decode(TelegramSettings.self, from: Data(contentsOf: legacy.appendingPathComponent("settings.json")))
            } else {
                var bytes = [UInt8](repeating: 0, count: 16)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                    throw ProxyError("Не удалось создать ключ Telegram")
                }
                settings = TelegramSettings(port: try newPort(avoiding: socks), secret: bytes.map { String(format: "%02x", $0) }.joined())
            }
            try valid(settings!)
            guard settings!.port != socks else { throw ProxyError("Порты Telegram и SOCKS должны отличаться") }
            try JSONEncoder().encode(settings!).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        state.port = settings!.port
        guard state.port != socks else { throw ProxyError("Порты Telegram и SOCKS должны отличаться") }
        // Migrate only our known companion; preserve its credentials and backup.
        let label = "com.jellybebra.zapret-local.telegram"
        let plist = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        if fm.fileExists(atPath: plist.path) {
            let data = try Data(contentsOf: plist)
            let config = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            guard config?["Label"] as? String == label,
                  config?["ProgramArguments"] as? [String] == [legacy.appendingPathComponent("venv/bin/python").path, legacy.appendingPathComponent("run.py").path] else {
                throw ProxyError("Неизвестный автозапуск Telegram: миграция остановлена")
            }
            let domain = "gui/\(getuid())"
            if try launchctl(["print", "\(domain)/\(label)"]) == 0 {
                guard try launchctl(["bootout", domain, plist.path]) == 0 else {
                    throw ProxyError("Не удалось остановить отдельный мост Telegram")
                }
            }
            let backup = root.appendingPathComponent("legacy-launch-agent.plist.disabled")
            try data.write(to: backup, options: .atomic)
            try fm.removeItem(at: plist)
        }
    }

    func sync(enabled: Bool, socks: UInt16) {
        if !enabled { stop(); return }
        if let process {
            if process.isRunning, socksPort == socks { return }
            if !process.isRunning {
                stop()
                state.error = "Telegram перезапустится через 10 секунд"
                retryAfter = Date().addingTimeInterval(10)
                return
            }
        }
        guard Date() >= retryAfter else { return }
        stop()
        do {
            try prepare(socks: socks)
            guard let executable = Bundle.main.resourceURL?.appendingPathComponent("telegram/zapret-telegram"),
                  FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw ProxyError("В приложении отсутствует модуль Telegram")
            }
            let ready = root.appendingPathComponent("ready.json")
            try? FileManager.default.removeItem(at: ready)
            let logURL = root.appendingPathComponent("launcher.log")
            if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber, size.intValue > 1_000_000 {
                try? FileManager.default.removeItem(at: logURL)
            }
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            log = try FileHandle(forWritingTo: logURL)
            try log?.seekToEnd()
            let child = Process()
            let pipe = Pipe()
            child.executableURL = executable
            child.arguments = ["--managed", "--state-dir", root.path, "--socks-port", String(socks)]
            child.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            child.standardInput = pipe
            child.standardOutput = FileHandle.nullDevice
            child.standardError = log
            try child.run()
            process = child
            lifetime = pipe
            socksPort = socks
            for _ in 0..<100 {
                guard child.isRunning else { throw ProxyError("Модуль Telegram завершился. См. launcher.log") }
                if let data = try? Data(contentsOf: ready),
                   let status = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
                   status["pid"] == Int(child.processIdentifier), status["port"] == Int(state.port) {
                    state.running = true
                    state.error = nil
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            throw ProxyError("Telegram не запустился: проверьте порт \(state.port) и launcher.log")
        } catch {
            stop()
            state.error = error.localizedDescription
            retryAfter = Date().addingTimeInterval(10)
        }
    }

    func stop() {
        try? lifetime?.fileHandleForWriting.close()
        lifetime = nil
        if let process {
            for _ in 0..<40 {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { process.terminate() }
            for _ in 0..<20 {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        process = nil
        socksPort = nil
        try? log?.close()
        log = nil
        state.running = false
    }

    func setPort(_ port: UInt16, socks: UInt16, enabled: Bool) throws {
        try ProxyService.validatePort(port)
        guard port != socks else { throw ProxyError("Порты Telegram и Zapret должны отличаться") }
        try prepare(socks: socks)
        guard let previous = settings, previous.port != port else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyError("Не удалось проверить порт Telegram") }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let available = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        Darwin.close(fd)
        guard available else { throw ProxyError("Порт \(port) уже занят") }
        func persist(_ value: TelegramSettings) throws {
            let file = root.appendingPathComponent("settings.json")
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        stop()
        settings = TelegramSettings(port: port, secret: previous.secret)
        state.port = port
        retryAfter = .distantPast
        do {
            try persist(settings!)
            sync(enabled: enabled, socks: socks)
            if enabled && !state.running { throw ProxyError(state.error ?? "Не удалось запустить Telegram") }
            state.error = nil
        } catch {
            let failure = error
            stop()
            settings = previous
            state.port = previous.port
            try persist(previous)
            retryAfter = .distantPast
            sync(enabled: enabled, socks: socks)
            throw failure
        }
    }

    func connectionURL() -> URL? {
        guard state.running, let settings else { return nil }
        var url = URLComponents()
        url.scheme = "tg"
        url.host = "proxy"
        url.queryItems = [URLQueryItem(name: "server", value: "127.0.0.1"),
                          URLQueryItem(name: "port", value: String(settings.port)),
                          URLQueryItem(name: "secret", value: "dd" + settings.secret)]
        return url.url
    }
}
