import Foundation
import Darwin

actor ProbeFixture {
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<Int, Error>] = [:]

    func measure(_ server: ProxyServer) async throws -> Int {
        calls += 1
        let call = calls
        return try await withCheckedThrowingContinuation { pending[call] = $0 }
    }

    func finish(_ call: Int, _ result: Result<Int, Error>) {
        pending.removeValue(forKey: call)!.resume(with: result)
    }
}

// Real Unix sockets with scripted replies: never connects to the installed helper.
final class FakeHelper: @unchecked Sendable {
    let path = "/tmp/zapret-test-\(UUID().uuidString).sock"
    private let listener: Int32
    private let lock = NSLock()
    private var history: [String] = []
    private let done = DispatchSemaphore(value: 0)
    var commands: [String] { lock.withLock { history } }

    init(reply: @escaping (String, [String: Any], Int32) -> Bool) throws {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(result == 0 && listen(listener, 1) == 0)
        DispatchQueue.global().async { [self] in
            defer { done.signal() }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            defer { Darwin.close(fd) }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count <= 0 { return }
                pending.append(contentsOf: buffer.prefix(count))
                while let end = pending.firstIndex(of: 10) {
                    let request = try! JSONSerialization.jsonObject(with: pending.prefix(upTo: end)) as! [String: Any]
                    pending.removeSubrange(...end)
                    let command = request["command"] as! String
                    lock.withLock { history.append(command) }
                    if !reply(command, request, fd) { return }
                }
            }
        }
    }

    func finish() {
        precondition(done.wait(timeout: .now() + 5) == .success, "Fake helper did not see EOF")
        Darwin.close(listener)
        unlink(path)
    }

    static func send(_ fd: Int32, running: Bool = false, ok: Bool = true, port: Int = 49946) {
        let value: [String: Any] = ["ok": ok, "running": running, "port": port,
            "version": "0.1.0", "protocolVersion": 15, "error": ok ? NSNull() : "Network changed" as Any]
        var data = try! JSONSerialization.data(withJSONObject: value)
        data.append(10)
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count <= 0 { return }
                offset += count
            }
        }
    }
}

@main
struct LifecycleTests {
    @MainActor
    static func checkServerProbes() async throws {
        let fixture = ProbeFixture()
        let probes = ServerProbes { try await fixture.measure($0) }
        let first = ProxyServer(id: "one", name: "One", outbound: Data("first".utf8))
        let second = ProxyServer(id: "two", name: "Two", outbound: Data("second".utf8))
        func waitFor(_ condition: () async -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !(await condition()) {
                precondition(ContinuousClock.now < deadline, "Probe test timed out")
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        probes.check(first)
        probes.check(first)
        probes.checkAll([first, second])
        precondition(probes.results[first.id] == .checking && probes.results[second.id] == .checking)
        try await waitFor { await fixture.calls == 2 }
        await fixture.finish(1, .success(42))
        await fixture.finish(2, .failure(ProxyError("Unavailable")))
        try await waitFor { !probes.isChecking }
        precondition(probes.results.values.contains(.success(42)))
        precondition(probes.results.values.contains(.failure("Unavailable")))

        probes.check(first)
        try await waitFor { await fixture.calls == 3 }
        let changed = ProxyServer(id: first.id, name: first.name, outbound: Data("changed".utf8))
        probes.reconcile([changed, second])
        precondition(probes.results[first.id] == nil)
        probes.check(changed)
        try await waitFor { await fixture.calls == 4 }
        await fixture.finish(3, .success(999))
        await fixture.finish(4, .success(24))
        try await waitFor { !probes.isChecking }
        precondition(probes.results[first.id] == .success(24), "Stale profile result replaced the new check")
        probes.reconcile([second])
        precondition(probes.results[first.id] == nil)

        probes.check(second)
        try await waitFor { await fixture.calls == 5 }
        let closing = Task { await probes.shutdown() }
        try await waitFor { !probes.isChecking }
        await fixture.finish(5, .success(88))
        await closing.value
        precondition(probes.results[second.id] == nil, "Cancelled probe published a result")
        print("PASS: per-server checks, deduplication, partial failure, profile invalidation and shutdown")
    }

    static func checkServerLibrary() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        // An unrelated client's configs alongside a fresh install must not become servers.
        let clean = temp.appendingPathComponent("Zapret Local")
        let neighbor = temp.appendingPathComponent("v2rayN/binConfigs")
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: true)
        try Data(#"{"outbounds":[{"tag":"proxy","protocol":"vless"}]}"#.utf8).write(to: neighbor.appendingPathComponent("config.json"))
        let fresh = try ServerStore(directory: clean).read()
        precondition(fresh.servers.isEmpty && fresh.selectedID == nil)
        let store = ServerStore(directory: temp)
        let uri = "vless://11111111-1111-4111-8111-111111111111@vpn.example.com:443?security=tls&type=tcp&sni=example.com&alpn=h2%2Chttp%2F1.1#Office%20TLS"
        let first = try ProxyServer.fromLink(uri, id: "one")
        precondition(first.name == "Office TLS")
        // Old versions could keep only an outbound without a selected-server.json.
        try first.outbound.write(to: temp.appendingPathComponent("vless.json"))
        let migrated = try store.read()
        precondition(migrated.selected?.matches(first.outbound) == true)
        let current = migrated.selected!
        let second = try ProxyServer.fromLink(uri.replacingOccurrences(of: "vpn.example", with: "other.example"), id: "two")
        try store.change { try $0.put(second) }
        do {
            try store.change { try $0.put(first) }
            fatalError("Duplicate accepted")
        } catch is ProxyError {}
        do {
            try store.change { try $0.remove(current.id, enabled: true) }
            fatalError("Removed active server")
        } catch is ProxyError {}
        let afterFailure = try store.read()
        precondition(afterFailure.selectedID == current.id && afterFailure.servers.count == 2)
        try store.change { try $0.put(second, select: true) }
        try store.change { try $0.remove(current.id, enabled: true) }
        var renamed = second
        renamed.name = "Renamed"
        try store.change { try $0.put(renamed) }
        let reopened = try store.read()
        precondition(reopened.selected?.name == "Renamed" && reopened.servers.count == 1)
        try store.change { try $0.remove(second.id, enabled: false) }
        let empty = try store.read()
        precondition(empty.servers.isEmpty && empty.selected == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: temp.appendingPathComponent("servers.json").path)
        precondition((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let key = Data(repeating: 42, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let reality = uri.replacingOccurrences(of: "security=tls", with: "security=reality")
            .replacingOccurrences(of: "alpn=h2%2Chttp%2F1.1", with: "pbk=" + key + "&sid=aabb&spx=%2Fhello")
        let node = try ProxyServer.fromLink(reality)
        let json = try JSONSerialization.jsonObject(with: node.outbound) as! [String:Any]
        let tls = (json["streamSettings"] as! [String:Any])["realitySettings"] as! [String:Any]
        precondition(tls["spiderX"] as? String == "/hello" && tls["publicKey"] as? String == key)
        for bad in [uri.replacingOccurrences(of: "tcp", with: "ws"), uri.replacingOccurrences(of: "443", with: "99999"),
                    uri.replacingOccurrences(of: "type=tcp", with: "type=tcp&allowInsecure=1"),
                    reality.replacingOccurrences(of: key, with: "bad")] {
            do { _ = try ProxyServer.fromLink(bad); fatalError("Invalid link accepted") }
            catch is ProxyError {}
        }
        print("PASS: independent server catalog, migration, TLS/REALITY links, active deletion and persistence")
    }

    static func main() async throws {
        try await checkServerProbes()
        try checkServerLibrary()
        // A suspended child ignores graceful exit and SIGTERM until continued.
        // Shutdown must reach SIGKILL without ever waiting indefinitely.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        kill(child.processIdentifier, SIGSTOP)
        let stopStart = ContinuousClock.now
        precondition(ProcessShutdown.stop(child))
        precondition(stopStart.duration(to: .now) < .seconds(5))
        print("PASS: bounded termination of a suspended child")

        // A silent or trickling helper must hit one total deadline and see EOF.
        for trickle in [false, true] {
            let fake = try FakeHelper { _, _, fd in
                for _ in 0..<20 {
                    if trickle {
                        var byte: UInt8 = 32
                        if Darwin.write(fd, &byte, 1) <= 0 { break }
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                return false
            }
            let client = try HelperClient(path: fake.path, expectedUID: getuid())
            let start = ContinuousClock.now
            do {
                _ = try client.request("status", timeout: 0.1)
                fatalError("Unresponsive helper accepted")
            } catch {}
            precondition(start.duration(to: .now) < .seconds(1))
            do {
                _ = try client.request("stop")
                fatalError("Timed-out connection was reused")
            } catch {}
            fake.finish()
            precondition(fake.commands == ["status"])
        }
        print("PASS: silent/trickling helper deadline, disconnect and no stale connection reuse")

        for failStop in [false, true] {
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            // Pick a free task port, without binding a proxy or changing network settings.
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    precondition(Darwin.bind(socket, $0, length) == 0)
                    precondition(getsockname(socket, $0, &length) == 0)
                }
            }
            let port = UInt16(bigEndian: address.sin_port)
            Darwin.close(socket)
            let settings = root.appendingPathComponent("settings.json")
            try JSONEncoder().encode(ProxySettings(port: port, lastEnabled: true)).write(to: settings)
            var running = false
            let fake = try FakeHelper { command, _, fd in
                if command == "start" { running = true }
                if command == "stop" { running = false }
                // A failed previous worker is a valid authenticated status, not a missing helper.
                FakeHelper.send(fd, running: running, ok: (command != "status" || running) && !(failStop && command == "stop"), port: Int(port))
                if failStop && command == "stop" { return false }
                return true
            }
            let service = ProxyService(settingsURL: settings, profile: { Data("{}".utf8) }, checkTunnel: {},
                clientFactory: { try HelperClient(path: fake.path, expectedUID: getuid()) })
            let started = await service.resume()
            precondition(started.running, "Recovery rejected a helper reporting the previous worker's failure")
            if !failStop {
                await service.networkDidWake()
                let recovered = await service.refresh()
                precondition(recovered.running)
                precondition(fake.commands.filter { $0 == "start" }.count == 2, "Wake did not restart a live-but-stale worker")
            }
            let stopped = await service.setEnabled(false)
            precondition(!stopped.enabled)
            if failStop { precondition(stopped.error != nil, "Stop failure was not surfaced") }
            let persisted = try JSONDecoder().decode(ProxySettings.self, from: Data(contentsOf: settings))
            precondition(!persisted.lastEnabled)
            let starts = fake.commands.filter { $0 == "start" }.count
            await service.networkDidWake()
            _ = await service.refresh()
            precondition(fake.commands.filter { $0 == "start" }.count == starts, "Disabled proxy restarted after wake")
            await service.shutdown()
            fake.finish()
        }
        print("PASS: failed-status reconnect, wake restart, persisted disable and no restart after disable")
    }
}
