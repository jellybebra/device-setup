import Foundation
import Darwin

enum VLESSProfile {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.jellybebra.zapret-cudy", isDirectory: true)
    }
    static func load() throws -> Data {
        guard let selected = try ServerStore.shared.read().selected else {
            throw ProxyError("Добавьте VLESS-сервер в меню «Управление серверами»")
        }
        return selected.outbound
    }

    static func save(_ server: ProxyServer) throws {
        try ServerStore.shared.change { try $0.put(server, select: true) }
    }

    static func connectionProfile(_ data: Data, fastRetry: Bool) throws -> Data {
        guard var value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProxyError("Некорректный профиль сервера")
        }
        value["fastConnectRetry"] = fastRetry
        return try JSONSerialization.data(withJSONObject: value)
    }

    static func probe(_ server: ProxyServer, fastRetry: Bool = false) throws {
        _ = try measure(server, fastRetry: fastRetry)
    }

    static func measure(_ server: ProxyServer, fastRetry: Bool = false) throws -> Int {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("zapret-helper")
        process.arguments = ["--probe-node"]
        let pipe = Pipe()
        let output = Pipe()
        process.standardInput = pipe
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? pipe.fileHandleForWriting.close()
            if process.isRunning {
                // --probe-node owns a separate process group, including Xray/curl.
                // If it has not set up the group yet, no children exist either.
                if kill(-process.processIdentifier, SIGKILL) != 0 {
                    kill(process.processIdentifier, SIGKILL)
                }
                _ = ProcessShutdown.stop(process)
            }
        }
        try pipe.fileHandleForWriting.write(contentsOf: connectionProfile(server.outbound, fastRetry: fastRetry))
        try pipe.fileHandleForWriting.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ProxyError("Время проверки истекло") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw ProxyError("Сервер не прошёл проверку подключения") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        struct Reply: Decodable { let latency_ms: Int }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              (1...12_000).contains(reply.latency_ms) else {
            throw ProxyError("Помощник не вернул время проверки. Обновите приложение")
        }
        return reply.latency_ms
    }
}
