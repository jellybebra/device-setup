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
}

struct ProxyError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

final class HelperClient {
    static let path = "/var/run/com.jellybebra.zapret-local.sock"
    private var descriptor: Int32 = -1
    private var pending = Data()

    init() throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyError("Не удалось открыть соединение с помощником") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(Self.path.utf8CString)
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
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else {
            Darwin.close(fd)
            throw ProxyError("Не удалось проверить сетевой помощник")
        }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        // Allow the helper's 40 s startup and 45 s cleanup budgets to finish.
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        timeout.tv_sec = 5
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        descriptor = fd
    }

    deinit { disconnect() }

    func disconnect() {
        guard descriptor >= 0 else { return }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        descriptor = -1
    }

    func request(_ command: String, port: UInt16? = nil, selection: StrategySelection? = nil) throws -> HelperReply {
        var request: [String: Any] = ["command": command]
        if let port { request["port"] = Int(port) }
        if let selection { request["selection"] = ["strategy": selection.strategy, "ipset": selection.ipset] }
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(10)
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ProxyError("Нет связи с сетевым помощником") }
                written += count
            }
        }
        while pending.firstIndex(of: 10) == nil {
            var buffer = [UInt8](repeating: 0, count: 2048)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ProxyError("Сетевой помощник не отвечает") }
            pending.append(contentsOf: buffer.prefix(count))
            guard pending.count <= 16_384 else { throw ProxyError("Некорректный ответ помощника") }
        }
        let end = pending.firstIndex(of: 10)!
        let line = pending.prefix(upTo: end)
        let reply = try JSONDecoder().decode(HelperReply.self, from: line)
        pending.removeSubrange(...end)
        guard reply.version == (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") else {
            throw ProxyError("Сетевой помощник требует обновления")
        }
        guard reply.protocolVersion == 2 else { throw ProxyError("Сетевой помощник требует обновления для выбора стратегий") }
        return reply
    }
}
