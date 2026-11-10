import Foundation
import Darwin

/// The selected ID and its outbound change together, in one private file.
struct ServerLibrary: Codable {
    var servers: [ProxyServer] = []
    var selectedID: String?
    var selected: ProxyServer? { servers.first { $0.id == selectedID } }

    mutating func put(_ server: ProxyServer, select: Bool = false) throws {
        guard !servers.contains(where: { $0.id != server.id && $0.matches(server.outbound) }) else {
            throw ProxyError("Такой сервер уже есть в списке")
        }
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        if select || selectedID == nil { selectedID = server.id }
    }

    mutating func remove(_ id: String, enabled: Bool) throws {
        if selectedID == id && enabled {
            throw ProxyError("Сначала выберите другой сервер или выключите V2DPI")
        }
        servers.removeAll { $0.id == id }
        if selectedID == id { selectedID = servers.first?.id }
    }
}

struct ServerStore {
    static let shared = ServerStore(directory: VLESSProfile.directory)
    let directory: URL
    private static let lock = NSLock()
    private var file: URL { directory.appendingPathComponent("servers.json") }

    func read() throws -> ServerLibrary {
        try Self.lock.withLock { try load() }
    }

    @discardableResult
    func change(_ mutate: (inout ServerLibrary) throws -> Void) throws -> ServerLibrary {
        try Self.lock.withLock {
            var library = try load()
            try mutate(&library)
            try write(library)
            return library
        }
    }

    private func load() throws -> ServerLibrary {
        if FileManager.default.fileExists(atPath: file.path) {
            return try JSONDecoder().decode(ServerLibrary.self, from: Data(contentsOf: file))
        }
        // Only the application's own earlier formats are eligible for migration.
        let selection = directory.appendingPathComponent("selected-server.json")
        let profile = directory.appendingPathComponent("vless.json")
        var library = ServerLibrary()
        if FileManager.default.fileExists(atPath: selection.path) {
            try library.put(JSONDecoder().decode(ProxyServer.self, from: Data(contentsOf: selection)))
        } else if FileManager.default.fileExists(atPath: profile.path) {
            let active = ProxyServer(id: UUID().uuidString, name: "Текущий сервер", outbound: try Data(contentsOf: profile))
            try library.put(active)
        }
        try write(library)
        return library
    }

    private func write(_ library: ServerLibrary) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temp = directory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let data = try JSONEncoder().encode(library)
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temp.path, file.path) == 0 else { throw ProxyError("Не удалось сохранить список серверов") }
    }
}
