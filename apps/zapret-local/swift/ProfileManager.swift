import Foundation
import AppKit
import SwiftUI

struct NetworkDomainRule: Codable, Equatable, Sendable {
    var domain: String
    var route: String
}

struct NetworkRuleProfile: Codable, Equatable, Identifiable, Sendable {
    var key: String
    var name: String
    var strategy: String
    var ipset: String
    var rules: [NetworkDomainRule]
    var id: String { key }

    static func validate(_ selection: StrategySelection) throws {
        let profiles = selection.networkProfiles ?? []
        guard profiles.count <= 16, Set(profiles.map(\.key)).count == profiles.count,
              try JSONEncoder().encode(selection).count <= 1_100_000 else {
            throw ProxyError("Слишком много профилей или правил")
        }
        for profile in profiles {
            guard profile.key.count == 64, profile.key.allSatisfy({ $0.isHexDigit }),
                  !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  profile.name.utf8.count <= 160, profile.rules.count <= 32,
                  NetworkStrategy.options.contains(where: { $0.id == profile.strategy }),
                  ["none", "cloudflare", "loaded", "any"].contains(profile.ipset) else {
                throw ProxyError("Проверьте имя и настройки профиля")
            }
            guard Set(profile.rules.map(\.domain)).count == profile.rules.count else {
                throw ProxyError("Один домен указан несколько раз")
            }
            for rule in profile.rules {
                let domain = rule.domain
                let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
                guard domain.utf8.count <= 253, labels.count >= 2,
                      labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 } }),
                      !domain.allSatisfy({ $0.isNumber || $0 == "." }),
                      ["direct", "dpi", "vless"].contains(rule.route) else {
                    throw ProxyError("Укажите домен без https://, пути и звёздочки, например example.com")
                }
            }
        }
    }
}

struct NetworkStrategy: Decodable, Identifiable {
    let id: String
    let title: String
    static var options: [NetworkStrategy] {
        let local = NetworkStrategy(id: "local", title: "Локальная")
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("engine/strategies.json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([NetworkStrategy].self, from: data) else {
            return [local, NetworkStrategy(id: "general-exp", title: "general (EXP)")]
        }
        return [local] + entries
    }
}

struct PolicySnapshot: Codable, Sendable {
    let strategy: String
    let entries: [PolicyEntry]
}
struct PolicyEntry: Codable, Identifiable, Sendable {
    let id: String
    let section: String
    let title: String
    let outcome: String
    let source: String
    let summary: String
    let details: String
    func matches(_ query: String) -> Bool {
        query.isEmpty || [title, outcome, source, summary, details].contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct ProfileManager: View {
    @ObservedObject var model: ProxyModel
    @State private var editing: ProfileConfiguration?
    @State private var deleting: ProfileConfiguration?
    @State private var renaming: ProfileConfiguration?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.state.configurations.isEmpty {
                ContentUnavailableView("Нет профилей", systemImage: "slider.horizontal.3")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.state.configurations) { config in
                            let selected = config.key == model.state.selectedProfileID
                            ManagementRow(name: config.name, selected: selected) {
                                Button { Task { _ = await model.createConfiguration(copying: config.key) } } label: {
                                    Image(systemName: "square.on.square").frame(width: 24, height: 24)
                                }.buttonStyle(.borderless).help("Создать копию")
                                    .accessibilityLabel("Создать копию профиля \(config.name)")
                                Button { editing = config } label: { Image(systemName: "square.and.pencil").frame(width: 24, height: 24) }
                                    .buttonStyle(.borderless).help("Редактировать профиль")
                                    .accessibilityLabel("Редактировать профиль \(config.name)")
                                Menu {
                                    Button("Переименовать…") { name = config.name; renaming = config }
                                    Button("Удалить…", role: .destructive) { deleting = config }.disabled(selected)
                                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .accessibilityLabel("Действия с профилем \(config.name)")
                            }
                        }
                    }
                }.disabled(model.busy)
            }
            if let error = model.state.error { Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ManagementToolbar(label: "Добавить профиль", isEnabled: !model.busy) {
            Task { editing = await model.newConfiguration() }
        })
        .sheet(item: $editing) { ConfigurationEditor(model: model, configuration: $0) }
        .alert("Название профиля", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { original in
            TextField("Название", text: $name)
            Button("Сохранить") {
                var config = original; config.name = name; Task { await model.saveConfiguration(config) }
            }
            Button("Отмена", role: .cancel) {}
        } message: { _ in }
        .alert("Удалить профиль?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { config in
            Button("Удалить", role: .destructive) { Task { await model.removeConfiguration(config.key) } }
            Button("Отмена", role: .cancel) {}
        } message: { config in Text(config.name) }
    }
}

private struct ConfigurationEditor: View {
    @ObservedObject var model: ProxyModel
    @Environment(\.dismiss) private var dismiss
    let configuration: ProfileConfiguration
    @State private var text = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Профиль: \(configuration.name)").font(.title2.weight(.semibold))
            Text("Пути к спискам: [списки]/имя.txt.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced))
                .disableAutocorrection(true).border(Color.secondary.opacity(0.3))
                .accessibilityLabel("JSON конфигурации")
            if let message = error ?? model.state.error { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Открыть файл…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        do { text = try String(contentsOf: url, encoding: .utf8); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Button("Сохранить в файл…") {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "v2dpi-configuration.json"
                    if panel.runModal() == .OK, let url = panel.url {
                        do { try Data(text.utf8).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Проверить и применить") {
                    Task {
                        do {
                            let document = try EditableProfileConfiguration.parse(text)
                            let updated = try document.updating(configuration)
                            error = nil
                            await model.saveConfiguration(updated)
                            if model.state.error == nil { dismiss() }
                        } catch { self.error = "Конфигурация не применена: " + error.localizedDescription }
                    }
                }.disabled(model.busy)
            }
        }.padding(20).frame(width: 720, height: 500)
        .task {
            do { text = try EditableProfileConfiguration(configuration).text() }
            catch { self.error = error.localizedDescription }
        }
    }
}
