import SwiftUI
import AppKit

struct ServerManager: View {
    @ObservedObject var model: ProxyModel
    @State private var editing: ProxyServer?
    @State private var formOpen = false
    @State private var deleting: ProxyServer?
    @State private var name = ""
    @State private var link = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if formOpen {
                Text(editing == nil ? "Добавить сервер" : "Изменить сервер").font(.headline)
                TextField("Название сервера", text: $name).textFieldStyle(.roundedBorder)
                if editing?.id != model.selectedServer?.id || !model.state.enabled || editing == nil {
                    HStack {
                        SecureField(editing == nil ? "Ссылка vless://" : "Новая ссылка vless://", text: $link)
                            .accessibilityLabel("Ссылка VLESS")
                        Button("Вставить") {
                            if let text = NSPasteboard.general.string(forType: .string) { link = text }
                        }
                    }
                    if editing != nil { Text("Оставьте ссылку пустой, чтобы изменить только название.").font(.caption) }
                }
                HStack {
                    Spacer()
                    Button("Отмена") { closeForm() }.keyboardShortcut(.cancelAction)
                    Button("Сохранить") {
                        perform {
                            try model.saveServer(id: editing?.id, name: name, link: link)
                            closeForm()
                        }
                    }.keyboardShortcut(.defaultAction).disabled(model.busy)
                }
                Spacer()
            } else {
                if model.servers.isEmpty {
                    ContentUnavailableView("Нет серверов", systemImage: "network")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.servers) { server in
                                let selected = server.id == model.selectedServer?.id
                                ManagementRow(name: server.name, selected: selected) {
                                    Button { edit(server) } label: { Image(systemName: "square.and.pencil").frame(width: 24, height: 24) }
                                        .buttonStyle(.borderless).help("Редактировать сервер")
                                        .accessibilityLabel("Редактировать сервер \(server.name)")
                                    Menu {
                                        Button("Использовать") { model.choose(server) }.disabled(selected)
                                        Button("Удалить…", role: .destructive) {
                                            if selected && model.state.enabled {
                                                message = "Сначала выберите другой сервер или выключите V2DPI"
                                            } else { deleting = server }
                                        }
                                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .accessibilityLabel("Действия с сервером \(server.name)")
                                }
                            }
                        }
                    }.disabled(model.busy)
                }
            }
            if let info = message ?? model.state.error ?? model.notice {
                Text(info).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ManagementToolbar(label: "Добавить сервер", isEnabled: !model.busy && !formOpen) { edit(nil) })
        .alert("Удалить сервер из V2DPI?", isPresented: Binding(get: { deleting != nil },
            set: { if !$0 { deleting = nil } }), presenting: deleting) { server in
            Button("Удалить", role: .destructive) { perform { try model.removeServer(server.id) } }
            Button("Отмена", role: .cancel) {}
        } message: { server in Text(server.name) }
    }

    private func edit(_ server: ProxyServer?) {
        editing = server
        name = server?.name ?? ""
        link = ""
        message = nil
        formOpen = true
    }

    private func closeForm() {
        editing = nil
        name = ""
        link = ""
        message = nil
        formOpen = false
    }

    private func perform(_ action: () throws -> Void) {
        message = nil
        do { try action() } catch { message = error.localizedDescription }
    }
}
