import Foundation

struct ProxyServer: Identifiable, Codable, Sendable {
    let id: String
    var name: String
    let outbound: Data

    func matches(_ data: Data) -> Bool {
        func fields(_ data: Data) -> [String]? {
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let settings = o["settings"] as? [String: Any] else { return nil }
            let host = (settings["vnext"] as? [[String: Any]])?.first ?? settings
            let user = (host["users"] as? [[String: Any]])?.first ?? host
            let stream = o["streamSettings"] as? [String: Any]
            let tls = (stream?["tlsSettings"] ?? stream?["realitySettings"]) as? [String: Any]
            let address = (host["address"] as? String ?? "").lowercased()
            let serverName = (tls?["serverName"] as? String ?? "").lowercased()
            var result = [address, (host["port"] as? NSNumber)?.stringValue ?? "",
                          user["id"] as? String ?? "", user["encryption"] as? String ?? "none",
                          user["flow"] as? String ?? "", stream?["security"] as? String ?? "",
                          serverName.isEmpty ? address : serverName]
            result.append(contentsOf: ["fingerprint", "shortId", "spiderX", "mldsa65Verify", "echConfigList"].map { tls?[$0] as? String ?? "" })
            result.append(tls?["publicKey"] as? String ?? tls?["password"] as? String ?? "")
            result.append((tls?["alpn"] as? [String] ?? []).joined(separator: ","))
            return result
        }
        guard let lhs = fields(outbound), let rhs = fields(data) else { return false }
        return lhs == rhs
    }
}

extension ProxyServer {
    static func fromLink(_ text: String, name: String = "", id: String = UUID().uuidString) throws -> ProxyServer {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard link.utf8.count <= 16_384, let url = URLComponents(string: link),
              url.scheme?.lowercased() == "vless", let user = url.user, !user.isEmpty,
              user.utf8.count <= 128, url.password == nil, let host = url.host,
              !host.isEmpty, host.utf8.count <= 253, host.utf8.allSatisfy({ (65...90).contains($0) ||
                  (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              let port = url.port, (1...65535).contains(port), ["", "/"].contains(url.path)
        else { throw ProxyError("Нужна ссылка vless:// с ID, именем узла или IPv4-адресом и портом") }

        let supported: Set<String> = ["security","type","sni","fp","alpn","pbk","sid","spx","pqv",
                                      "flow","encryption","ech","headerType","allowInsecure"]
        var q: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard supported.contains(item.name), q[item.name] == nil else {
                throw ProxyError("В ссылке есть неизвестный или повторяющийся параметр")
            }
            q[item.name] = item.value ?? ""
        }
        guard ["tcp","raw"].contains(q["type"] ?? "tcp"),
              ["", "none"].contains(q["headerType"] ?? ""),
              ["0", "false", ""].contains(q["allowInsecure"] ?? ""),
              let security = q["security"], ["tls","reality"].contains(security) else {
            throw ProxyError("Поддерживается VLESS поверх TCP с TLS или REALITY и проверкой сертификата")
        }
        if security == "reality" {
            let key = (q["pbk"] ?? "").replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let padding = String(repeating: "=", count: (4 - key.count % 4) % 4)
            guard Data(base64Encoded: key + padding)?.count == 32 else { throw ProxyError("Некорректный публичный ключ REALITY") }
            let sid = q["sid"] ?? ""
            guard sid.count <= 16, sid.count.isMultiple(of: 2), sid.allSatisfy(\.isHexDigit) else {
                throw ProxyError("Некорректный short ID REALITY")
            }
            guard q["ech"] == nil, (q["alpn"] ?? "").isEmpty else { throw ProxyError("Эти параметры TLS не поддерживаются для REALITY") }
        } else if ["pbk","spx","sid","pqv"].contains(where: { !(q[$0] ?? "").isEmpty }) {
            throw ProxyError("Параметры REALITY требуют security=reality")
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.isEmpty ? (url.fragment ?? "") : title
        let flow = q["flow"] ?? ""
        guard ["", "xtls-rprx-vision", "xtls-rprx-vision-udp443"].contains(flow) else {
            throw ProxyError("Неизвестный VLESS flow")
        }
        var tls: [String: Any] = ["serverName": q["sni"] ?? "", "fingerprint": q["fp"] ?? ""]
        if security == "reality" {
            tls["publicKey"] = q["pbk"]
            tls["shortId"] = q["sid"] ?? ""
            tls["spiderX"] = q["spx"] ?? ""
            tls["mldsa65Verify"] = q["pqv"] ?? ""
        } else {
            tls["alpn"] = (q["alpn"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if let ech = q["ech"], !ech.isEmpty {
                guard ech.utf8.count <= 4096, Data(base64Encoded: ech) != nil else {
                    throw ProxyError("Нужна встроенная конфигурация ECH в base64")
                }
                tls["echConfigList"] = ech
            }
        }
        let outbound: [String: Any] = ["protocol": "vless",
            "settings": ["address": host, "port": port, "id": user, "flow": flow,
                         "encryption": q["encryption"] ?? "none"],
            "streamSettings": ["network": "raw", "security": security, security + "Settings": tls]]
        return ProxyServer(id: id, name: label.isEmpty ? host : label,
                           outbound: try JSONSerialization.data(withJSONObject: outbound))
    }
}
