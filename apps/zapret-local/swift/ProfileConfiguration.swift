import Foundation

struct ProfileConfiguration: Codable, Identifiable, Sendable {
    var key: String
    var name: String
    var fastRetry: Bool
    var selection: StrategySelection
    // Exact generated routing, DNS, DPI arguments and list contents. Startup
    // verifies it against the installed engine; updates cannot silently change it.
    var policy: PolicySnapshot
    var id: String { key }

    func copied(to key: String, name: String) -> Self {
        var copy = self
        copy.key = key; copy.name = name
        copy.selection.networkProfiles = selection.networkProfiles?.map {
            var p = $0; p.key = key; p.name = name; return p
        }
        return copy
    }
    static func availableName(_ name: String, among names: [String]) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !names.contains(where: { $0.localizedCaseInsensitiveCompare(base) == .orderedSame }) { return base }
        return copyName(base, among: names)
    }
    static func copyName(_ name: String, among names: [String]) -> String {
        let base = name.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
        var number = 2
        while names.contains(where: { $0.localizedCaseInsensitiveCompare("\(base) (\(number))") == .orderedSame }) { number += 1 }
        return "\(base) (\(number))"
    }
    static func canonical(_ policy: PolicySnapshot) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(policy)
    }
}

indirect enum ConfigurationValue: Codable, Equatable, Sendable {
    case object([String: ConfigurationValue]), array([ConfigurationValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: ConfigurationValue].self) { self = .object(v) }
        else { self = .array(try c.decode([ConfigurationValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
struct CustomPolicyConfiguration: Codable, Equatable, Sendable {
    var routing: ConfigurationValue
    var dns: ConfigurationValue
    var dpiArguments: [String]
    var lists: [String: String]
}

struct EditableProfileConfiguration: Codable {
    var name: String
    var fastRetry: Bool
    var routing: ConfigurationValue
    var dns: ConfigurationValue
    var dpiArguments: [String]
    var lists: [String: String]

    init(_ saved: ProfileConfiguration) throws {
        name = saved.name; fastRetry = saved.fastRetry
        if let custom = saved.selection.custom {
            routing = custom.routing; dns = custom.dns; dpiArguments = custom.dpiArguments; lists = custom.lists
            return
        }
        func value(_ text: String) throws -> ConfigurationValue { try JSONDecoder().decode(ConfigurationValue.self, from: Data(text.utf8)) }
        let entries = saved.policy.entries
        let routeRules = try entries.filter { $0.section == "Маршрутизация" && $0.id != "route-final" }.map { try value($0.details) }
        guard let final = entries.first(where: { $0.id == "route-final" }), case .object(let finalFields) = try value(final.details), let outbound = finalFields["outbound"] else { throw ProxyError("Не найден маршрут по умолчанию") }
        routing = .object(["rules": .array(routeRules), "final": outbound, "default_domain_resolver": .string("direct-doh")])
        guard let defaults = entries.first(where: { $0.id == "dns-default" }), case .object(var dnsFields) = try value(defaults.details) else { throw ProxyError("Не найден снимок DNS") }
        dnsFields["rules"] = .array(try entries.filter { $0.section == "DNS" && $0.id != "dns-default" }.map { try value($0.details) })
        dns = .object(dnsFields)
        dpiArguments = []
        for entry in entries.filter({ $0.section == "DPI" }) {
            if !dpiArguments.isEmpty { dpiArguments.append("--new") }
            dpiArguments += entry.details.split(separator: "\n").map(String.init)
        }
        lists = Dictionary(uniqueKeysWithValues: entries.filter { $0.section == "Списки DPI" }.map { ($0.title, $0.details) })
    }
    func updating(_ saved: ProfileConfiguration) throws -> ProfileConfiguration {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProxyError("Укажите имя") }
        var result = saved
        result.name = name; result.fastRetry = fastRetry
        result.selection.custom = CustomPolicyConfiguration(routing: routing, dns: dns, dpiArguments: dpiArguments, lists: lists)
        result.selection.networkProfiles = nil
        return result
    }
    static func parse(_ text: String) throws -> Self {
        let data = Data(text.utf8)
        guard data.count <= 1_100_000, let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProxyError("Нужен JSON-объект до 1 МБ") }
        let known: Set<String> = ["name", "fastRetry", "routing", "dns", "dpiArguments", "lists"]
        let unknown = Set(fields.keys).subtracting(known)
        guard unknown.isEmpty else { throw ProxyError("Неизвестные поля: " + unknown.sorted().joined(separator: ", ")) }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func text() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
