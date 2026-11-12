import Foundation
import Darwin

struct HelperReply: Decodable, Sendable {
    let ok: Bool
    let running: Bool
    let port: UInt16
    let error: String?
    let version: String
    let protocolVersion: Int?
    let selection: StrategySelection?
    let networkKey: String?
    let networkInterface: String?
    let policy: PolicySnapshot?
}

struct ProxyError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

final class HelperClient {
    static let path = "/var/run/com.jellybebra.zapret-cudy.sock"
    private var descriptor: Int32 = -1
    private var pending = Data()

    init(path: String = HelperClient.path, expectedUID: uid_t = 0) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyError("Не удалось открыть соединение с помощником") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd); throw ProxyError("Некорректный путь помощника")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { Darwin.close(fd); throw ProxyError("Сетевой помощник не установлен") }
        var uid: uid_t = .max
        var gid: gid_t = .max
        guard getpeereid(fd, &uid, &gid) == 0, uid == expectedUID else {
            Darwin.close(fd)
            throw ProxyError("Не удалось проверить сетевой помощник")
        }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(fd); throw ProxyError("Не удалось настроить соединение с помощником")
        }
        descriptor = fd
    }

    deinit { disconnect() }

    func disconnect() {
        guard descriptor >= 0 else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        descriptor = -1
        pending.removeAll()
    }

    func request(_ command: String, port: UInt16? = nil, selection: StrategySelection? = nil, node: Data? = nil, timeout: TimeInterval? = nil, networkKey: String? = nil) throws -> HelperReply {
        // A status check must not hold the service actor for a full minute.
        // Start/stop retain the helper's existing startup and cleanup budgets.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64((timeout ?? (command == "status" ? 3 : 100)) * 1000)))
        var completed = false
        defer { if !completed { disconnect() } }
        guard descriptor >= 0 else { throw ProxyError("Нет связи с сетевым помощником") }
        var request: [String: Any] = ["command": command]
        if let networkKey { request["networkKey"] = networkKey }
        if let node { request["node"] = try JSONSerialization.jsonObject(with: node) }
        if let port { request["port"] = Int(port) }
        if let selection { request["selection"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) }
        var data = try JSONSerialization.data(withJSONObject: request)
        guard data.count < 1_200_000 else { throw ProxyError("Слишком много правил сетей") }
        data.append(10)
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                try wait(for: Int16(POLLOUT), until: deadline)
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard count > 0 else { throw ProxyError("Нет связи с сетевым помощником") }
                written += count
            }
        }
        while pending.firstIndex(of: 10) == nil {
            try wait(for: Int16(POLLIN), until: deadline)
            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0 else { throw ProxyError("Сетевой помощник не отвечает") }
            pending.append(contentsOf: buffer.prefix(count))
            guard pending.count <= 4_194_304 else { throw ProxyError("Некорректный ответ помощника") }
        }
        let end = pending.firstIndex(of: 10)!
        let line = pending.prefix(upTo: end)
        let reply = try JSONDecoder().decode(HelperReply.self, from: line)
        pending.removeSubrange(...end)
        guard reply.version == (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") else {
            throw ProxyError("Сетевой помощник требует обновления")
        }
        guard reply.protocolVersion == 23 else { throw ProxyError("Сетевой помощник требует обновления") }
        completed = true
        return reply
    }

    private func wait(for events: Int16, until deadline: ContinuousClock.Instant) throws {
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let milliseconds = remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000
            guard milliseconds > 0 else { throw ProxyError("Сетевой помощник не отвечает: время ожидания истекло") }
            var event = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&event, 1, Int32(min(milliseconds, 1000)))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw ProxyError("Нет связи с сетевым помощником") }
            if result > 0 { return }
        }
    }
}
