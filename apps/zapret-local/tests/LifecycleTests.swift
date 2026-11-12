import Foundation
import Darwin

actor ProbeFixture {
    private(set) var calls = 0
    private(set) var retryOptions: [Bool] = []
    private var pending: [Int: CheckedContinuation<Int, Error>] = [:]

    func measure(_ server: ProxyServer, fastRetry: Bool) async throws -> Int {
        retryOptions.append(fastRetry)
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

    static func send(_ fd: Int32, running: Bool = false, ok: Bool = true, port: Int = 49946, policy: [String: Any]? = nil, networkKey: String? = nil) {
        var value: [String: Any] = ["ok": ok, "running": running, "port": port,
            "version": "0.1.0", "protocolVersion": 23, "error": ok ? NSNull() : "Network changed" as Any]
        if let policy { value["policy"] = policy }
        if let networkKey { value["networkKey"] = networkKey; value["networkInterface"] = "en0" }
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
        let probes = ServerProbes { try await fixture.measure($0, fastRetry: $1) }
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

        probes.setFastRetry(true)
        precondition(probes.results.isEmpty, "Changing the option must invalidate old measurements")
        probes.check(first)
        try await waitFor { await fixture.calls == 3 }
        let options = await fixture.retryOptions
        precondition(options == [false, false, true], "Checks must use the selected retry option")
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

    static func checkNetworkProfiles() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent("settings.json")
        // Existing settings migrate without creating a network-specific rule.
        try Data("{\"port\":49956,\"lastEnabled\":false}".utf8).write(to: settingsURL)
        let service = ProxyService(settingsURL: settingsURL, checkTunnel: {})
        let old = await service.state()
        precondition(old.selection.networkProfiles == nil)
        let profile = NetworkRuleProfile(key: String(repeating: "a", count: 64), name: "Office Wi-Fi",
            strategy: "general-exp", ipset: "cloudflare",
            rules: [NetworkDomainRule(domain: "githubassets.com", route: "vless")])
        let saved = await service.setNetworkProfiles([profile])
        precondition(saved.error == nil && !saved.enabled && !saved.running)
        let reloaded = ProxyService(settingsURL: settingsURL, checkTunnel: {})
        let state = await reloaded.state()
        precondition(state.selection.networkProfiles == [profile])
        var bad = profile; bad.rules[0].domain = "https://example.com/path"
        let rejected = await service.setNetworkProfiles([bad])
        precondition(rejected.error != nil && rejected.selection.networkProfiles == [profile])
        let persisted = try JSONDecoder().decode(ProxySettings.self, from: Data(contentsOf: settingsURL))
        precondition(persisted.selection?.networkProfiles == [profile])
        let removed = await service.setNetworkProfiles([])
        precondition(removed.selection.networkProfiles == [] && !removed.enabled)
        print("PASS: network profile migration, persistence, rejected edits and removal")
    }

    static func checkNetworkProfileRollback() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            precondition(Darwin.bind(fd, $0, length) == 0); precondition(getsockname(fd, $0, &length) == 0)
        } }
        let port = UInt16(bigEndian: address.sin_port); Darwin.close(fd)
        try JSONEncoder().encode(ProxySettings(port: port, lastEnabled: true)).write(to: settings)
        var running = false
        var rejectNext = false
        var starts: [[[String: Any]]] = []
        let fake = try FakeHelper { command, request, fd in
            if command == "start" {
                let profiles = (request["selection"] as? [String: Any])?["networkProfiles"] as? [[String: Any]] ?? []
                starts.append(profiles)
                if rejectNext {
                    rejectNext = false
                    FakeHelper.send(fd, running: false, ok: false, port: Int(port)); return true
                }
                running = true
            }
            if command == "stop" { running = false }
            FakeHelper.send(fd, running: running, port: Int(port)); return true
        }
        let service = ProxyService(settingsURL: settings, profile: { Data("{}".utf8) }, checkTunnel: {},
            clientFactory: { try HelperClient(path: fake.path, expectedUID: getuid()) })
        let started = await service.resume(); precondition(started.running)
        let office = NetworkRuleProfile(key: String(repeating: "a", count: 64), name: "Office",
            strategy: "general-exp", ipset: "cloudflare", rules: [NetworkDomainRule(domain: "githubassets.com", route: "vless")])
        let saved = await service.setNetworkProfiles([office]); precondition(saved.error == nil && saved.running)
        precondition(starts.last?.first?["key"] as? String == office.key, "Profiles were lost at the IPC boundary")
        var changed = office; changed.rules[0].route = "direct"; rejectNext = true
        let rolledBack = await service.setNetworkProfiles([changed])
        precondition(rolledBack.error != nil && rolledBack.running && rolledBack.enabled)
        precondition(rolledBack.selection.networkProfiles == [office])
        let disk = try JSONDecoder().decode(ProxySettings.self, from: Data(contentsOf: settings))
        precondition(disk.selection?.networkProfiles == [office] && disk.lastEnabled)
        precondition(starts.count == 4, "Failed profile must restart the previous configuration")
        await service.shutdown(); fake.finish()
        print("PASS: network profile IPC and rollback after failed activation")
    }

    static func checkCompleteConfigurationSwitching() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let keyA = String(repeating: "a", count: 64), keyB = String(repeating: "b", count: 64)
        let policy = PolicySnapshot(strategy: "general-exp", entries: [])
        var selection = StrategySelection()
        selection.custom = CustomPolicyConfiguration(routing: .object(["rules": .array([]), "final": .string("direct")]),
            dns: .object(["servers": .array([]), "rules": .array([])]), dpiArguments: [], lists: ["test.txt": "example.com\n"])
        let base = ProfileConfiguration(key: "default", name: "Default", fastRetry: false, selection: selection, policy: policy)
        let a = base.copied(to: keyA, name: "Office")
        var b = base.copied(to: keyB, name: "Other"); b.fastRetry = true
        var settings = ProxySettings(port: 49945, lastEnabled: true)
        settings.defaultConfiguration = base; settings.configurations = [a, b]
        try JSONEncoder().encode(settings).write(to: url)
        var current = keyA, running = false, drift = false, rejectStart = false, invalidConfig = false
        var starts: [[String: Any]] = []
        var globalServer = "shared", activePort = 49945
        let fake = try FakeHelper { command, request, fd in
            if command == "validate" {
                precondition(request["node"] == nil, "Profile validation must not depend on a VLESS server")
                if invalidConfig { FakeHelper.send(fd, running: running, ok: false, port: activePort); return true }
            }
            if command == "start" {
                precondition(request["networkKey"] == nil, "Manual profile must not be bound to Wi-Fi")
                precondition(((request["selection"] as? [String: Any])?["networkProfiles"] as? [Any])?.isEmpty != false)
                starts.append(request)
                if rejectStart { rejectStart = false; running = false; FakeHelper.send(fd, ok: false, port: activePort); return true }
                running = true; activePort = request["port"] as! Int
            }
            if command == "stop" { running = false }
            FakeHelper.send(fd, running: running, port: activePort,
                policy: command == "policy" ? ["strategy": drift ? "changed" : "general-exp", "entries": []] : nil,
                networkKey: command == "network" ? current : nil)
            return true
        }
        let service = ProxyService(settingsURL: url, profile: { try JSONSerialization.data(withJSONObject: ["marker": globalServer]) }, checkTunnel: {}, clientFactory: { try HelperClient(path: fake.path, expectedUID: getuid()) })
        let first = await service.resume(); precondition(first.running && first.activeConfiguration?.name == "Office")
        let idA = first.selectedProfileID!, idB = first.configurations.first { $0.name == "Other" }!.key
        precondition(idA != keyA && idB != keyB)
        let migrated = try JSONDecoder().decode(ProxySettings.self, from: Data(contentsOf: url))
        precondition(migrated.defaultConfiguration == nil && migrated.selectedProfileID == idA && migrated.configurations?.count == 3)
        precondition(first.configurations.allSatisfy { $0.selection.networkProfiles == nil })
        current = keyB
        await service.networkDidWake()
        let moved = await service.refresh()
        precondition(moved.running && moved.selectedProfileID == idA && !moved.fastRetry, "Network changes must retain the chosen profile")
        precondition(fake.commands.filter { $0 == "network" }.count == 1, "Only one-time migration may inspect the former Wi-Fi binding")
        globalServer = "new-shared"
        let second = await service.selectConfiguration(idB)
        precondition(second.running && second.selectedProfileID == idB && second.fastRetry)
        precondition((starts.last?["node"] as? [String: Any])?["marker"] as? String == "new-shared")
        let startsBeforeCopies = starts.count
        let copied = await service.createConfiguration(copying: idB)
        precondition(copied.error == nil && copied.selectedProfileID == idB && copied.configurations.contains { $0.name == "Other (2)" })
        let copiedAgain = await service.createConfiguration(copying: idB)
        precondition(copiedAgain.configurations.contains { $0.name == "Other (3)" } && starts.count == startsBeforeCopies)
        let copy = copiedAgain.configurations.first { $0.name == "Other (2)" }!
        var editedCopy = copy; editedCopy.selection.custom!.lists["test.txt"] = "changed.example.com\n"
        let edited = await service.saveConfiguration(editedCopy)
        precondition(edited.error == nil && edited.configurations.first { $0.key == idB }!.selection.custom!.lists["test.txt"] == "example.com\n")
        var renamed = edited.configurations.first { $0.key == idB }!; renamed.name = "Работа"
        let renamedState = await service.saveConfiguration(renamed)
        precondition(renamedState.error == nil && starts.count == startsBeforeCopies, "Renaming must not reconnect")
        var duplicateName = copy; duplicateName.name = "работа"
        let rejectedName = await service.saveConfiguration(duplicateName)
        precondition(rejectedName.error != nil && rejectedName.running)
        invalidConfig = true
        let beforeInvalid = fake.commands.count
        let invalid = await service.saveConfiguration(renamed)
        precondition(invalid.error != nil && invalid.running && !fake.commands.dropFirst(beforeInvalid).contains("stop"))
        invalidConfig = false
        rejectStart = true
        let rollback = await service.selectConfiguration(idA)
        precondition(rollback.running && rollback.selectedProfileID == idB && rollback.enabled && rollback.error != nil)
        let rejectedDelete = await service.removeConfiguration(idB); precondition(rejectedDelete.error != nil)
        let removedCopy = await service.removeConfiguration(copy.key); precondition(removedCopy.error == nil && !removedCopy.configurations.contains { $0.key == copy.key })
        let badPort = await service.setPort(80); precondition(badPort.running && badPort.port == 49945 && badPort.error != nil)
        _ = await service.setEnabled(false)
        let stoppedCount = starts.count
        let selectedWhileOff = await service.selectConfiguration(idA)
        precondition(!selectedWhileOff.running && selectedWhileOff.selectedProfileID == idA && starts.count == stoppedCount)
        let disk = try JSONDecoder().decode(ProxySettings.self, from: Data(contentsOf: url))
        precondition(disk.selectedProfileID == idA && disk.port == 49945)
        drift = true
        let changed = await service.setEnabled(true); precondition(!changed.running && changed.error != nil && starts.count == stoppedCount)
        await service.shutdown(); fake.finish()
        precondition(ProfileConfiguration.copyName("Work (2)", among: ["Work", "Work (2)", "work (3)"]) == "Work (4)")
        print("PASS: manual profiles, migration, selection persistence, copy isolation/names, rollback, global server/port and no Wi-Fi switching")
    }

    static func checkEditableConfiguration() throws {
        func entry(_ id: String, _ section: String, _ details: String, title: String = "Rule") -> PolicyEntry {
            PolicyEntry(id: id, section: section, title: title, outcome: "", source: "", summary: "", details: details)
        }
        let policy = PolicySnapshot(strategy: "general-exp", entries: [
            entry("route-0", "Маршрутизация", "{\"domain_suffix\":\"example.com\",\"outbound\":\"vless\"}"),
            entry("route-final", "Маршрутизация", "{\"outbound\":\"dpi\"}"),
            entry("dns-default", "DNS", "{\"servers\":[{\"type\":\"udp\",\"tag\":\"custom\",\"server\":\"192.0.2.53\",\"server_port\":5353}],\"final\":\"custom\"}"),
            entry("dns-0", "DNS", "{\"query_type\":\"AAAA\",\"action\":\"reject\"}"),
            entry("dpi-0", "DPI", "--filter-tcp=443\n--hostlist=[списки]/custom.txt\n--dpi-desync=multidisorder"),
            entry("dpi-1", "DPI", "--filter-udp=443\n--dpi-desync=fake"),
            entry("list", "Списки DPI", "example.com\n", title: "custom.txt")])
        let original = ProfileConfiguration(key: "default", name: "Default", fastRetry: true,
            selection: StrategySelection(), policy: policy)
        let document = try EditableProfileConfiguration(original)
        let originalText = try document.text()
        let fields = try JSONSerialization.jsonObject(with: Data(originalText.utf8)) as! [String: Any]
        precondition(fields["server"] == nil && fields["serverName"] == nil && fields["port"] == nil && fields["savedAt"] == nil)
        let restored = try EditableProfileConfiguration.parse(originalText).updating(original)
        precondition(restored.key == original.key && restored.fastRetry)
        precondition(restored.selection.custom!.dpiArguments == ["--filter-tcp=443", "--hostlist=[списки]/custom.txt", "--dpi-desync=multidisorder", "--new", "--filter-udp=443", "--dpi-desync=fake"])
        precondition(restored.selection.custom!.lists == ["custom.txt": "example.com\n"])
        guard case .object(let routing) = restored.selection.custom!.routing else { fatalError() }
        precondition(routing["final"] == .string("dpi"), "Default route must not be reset to direct")
        let again = try EditableProfileConfiguration(restored).text()
        precondition(again == originalText, "Editing a custom configuration must preserve every field")
        var invalid = try JSONSerialization.jsonObject(with: Data(originalText.utf8)) as! [String: Any]
        invalid["routeing"] = [:]
        do { _ = try EditableProfileConfiguration.parse(String(decoding: JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)); fatalError("Unknown field accepted") } catch {}
        print("PASS: editable configuration preserves routing, DNS, DPI, lists and rejects unknown fields")
    }

    static func main() async throws {
        try checkEditableConfiguration()
        try await checkCompleteConfigurationSwitching()
        // Policy lists exceed ordinary status replies. Reading them must retain
        // the selected profile, preserve Unicode, and leave the session usable.
        let policyText = String(repeating: "пример.example.com\n", count: 3000)
        let policyHelper = try FakeHelper { command, request, fd in
            if command == "policy" {
                precondition(request["networkKey"] as? String == String(repeating: "a", count: 64))
                FakeHelper.send(fd, policy: ["strategy": "local", "entries": [[
                    "id": "list-1", "section": "Списки DPI", "title": "Список", "outcome": "3000 записей",
                    "source": "Файл", "summary": "Домены", "details": policyText]]])
            } else { FakeHelper.send(fd) }
            return true
        }
        let policyClient = try HelperClient(path: policyHelper.path, expectedUID: getuid())
        let report = try policyClient.request("policy", networkKey: String(repeating: "a", count: 64)).policy!
        precondition(report.entries[0].details == policyText)
        precondition(report.entries[0].matches("ПРИМЕР.example"))
        precondition(!report.entries[0].matches("not-present.invalid"))
        _ = try policyClient.request("status")
        policyClient.disconnect(); policyHelper.finish()
        print("PASS: full policy IPC, large lists, Unicode search and session reuse")
        try await checkNetworkProfiles()
        try await checkNetworkProfileRollback()
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
            var retryStarts: [Bool] = []
            var rejectFastOnce = false
            let fake = try FakeHelper { command, request, fd in
                if command == "start" {
                    let retry = (request["node"] as? [String: Any])?["fastConnectRetry"] as? Bool ?? false
                    retryStarts.append(retry)
                    if retry && rejectFastOnce {
                        rejectFastOnce = false
                        running = false
                        FakeHelper.send(fd, running: false, ok: false, port: Int(port))
                        return true
                    }
                    running = true
                }
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
                precondition(!recovered.fastRetry, "Existing settings must default to off")
                let enabledRetry = await service.setFastRetry(true)
                precondition(enabledRetry.running && enabledRetry.fastRetry && retryStarts.last == true)
                let savedRetry = try JSONDecoder().decode(ProxySettings.self, from: Data(contentsOf: settings))
                precondition(savedRetry.fastRetry == true)
                let disabledRetry = await service.setFastRetry(false)
                precondition(disabledRetry.running && !disabledRetry.fastRetry && retryStarts.last == false)
                rejectFastOnce = true
                let rolledBack = await service.setFastRetry(true)
                precondition(rolledBack.running && !rolledBack.fastRetry && rolledBack.error != nil)
                precondition(Array(retryStarts.suffix(2)) == [true, false], "Failed option must restore prior connection")
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
            let offlineOption = await service.setFastRetry(true)
            precondition(offlineOption.fastRetry && !offlineOption.enabled)
            precondition(fake.commands.filter { $0 == "start" }.count == starts, "Changing an option while off must not start VPN")
            let reloaded = ProxyService(settingsURL: settings)
            let savedState = await reloaded.state()
            precondition(savedState.fastRetry && !savedState.enabled)
            await service.shutdown()
            fake.finish()
        }
        print("PASS: failed-status reconnect, wake restart, persisted disable and no restart after disable")
    }
}
