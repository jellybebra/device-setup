import Foundation
import Combine

enum ServerProbeResult: Equatable {
    case checking
    case success(Int)
    case failure(String)
}

// Serial checks avoid flooding the network or measuring competing test requests.
// This actor is separate from the service that controls the active connection.
private actor ServerProbeRunner {
    static let shared = ServerProbeRunner()

    func measure(_ server: ProxyServer) async throws -> Int {
        try Task.checkCancellation()
        return try VLESSProfile.measure(server)
    }
}

@MainActor
final class ServerProbes: ObservableObject {
    @Published private(set) var results: [String: ServerProbeResult] = [:]
    var isChecking: Bool { results.values.contains(.checking) }

    private var jobs: [String: Task<Void, Never>] = [:]
    private var profiles: [String: Data] = [:]
    private let measure: @Sendable (ProxyServer) async throws -> Int

    init(measure: @escaping @Sendable (ProxyServer) async throws -> Int = {
        try await ServerProbeRunner.shared.measure($0)
    }) {
        self.measure = measure
    }

    func check(_ server: ProxyServer) {
        guard jobs[server.id] == nil else { return }
        profiles[server.id] = server.outbound
        results[server.id] = .checking
        jobs[server.id] = Task { [weak self, measure] in
            let result: ServerProbeResult
            do { result = .success(try await measure(server)) }
            catch { result = .failure(error.localizedDescription) }
            guard !Task.isCancelled, let self else { return }
            self.jobs[server.id] = nil
            self.results[server.id] = result
        }
    }

    func checkAll(_ servers: [ProxyServer]) {
        for server in servers { check(server) }
    }

    func reconcile(_ servers: [ProxyServer]) {
        let current = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0.outbound) })
        for id in Array(profiles.keys) where profiles[id] != current[id] {
            jobs.removeValue(forKey: id)?.cancel()
            results[id] = nil
            profiles[id] = nil
        }
    }

    func cancelAll() {
        for task in jobs.values { task.cancel() }
        jobs.removeAll()
        results = results.filter { $0.value != .checking }
    }

    func shutdown() async {
        let tasks = Array(jobs.values)
        cancelAll()
        for task in tasks { await task.value }
    }

    deinit { for task in jobs.values { task.cancel() } }
}
