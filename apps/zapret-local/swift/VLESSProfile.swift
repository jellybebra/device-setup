import Foundation

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

    static func probe(_ server: ProxyServer) throws {
        let process = Process()
        process.executableURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("zapret-helper")
        process.arguments = ["--probe-node"]
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try pipe.fileHandleForWriting.write(contentsOf: server.outbound)
            try pipe.fileHandleForWriting.close()
        } catch {
            try? pipe.fileHandleForWriting.close()
            process.terminate()
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProxyError("Сервер не прошёл проверку подключения") }
    }
}
