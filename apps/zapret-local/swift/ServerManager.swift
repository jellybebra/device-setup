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
                TextField("Название сервера", text: $name)
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
                Button("Добавить…") { edit(nil) }.disabled(model.busy)
                if model.servers.isEmpty {
                    ContentUnavailableView("Нет серверов", systemImage: "network")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.servers) { server in
                                let selected = server.id == model.selectedServer?.id
                                HStack {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                                        .accessibilityLabel(selected ? "Выбран" : "Не выбран")
                                    Text(server.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Menu {
                                        Button("Использовать") { model.choose(server) }.disabled(selected)
                                        Button("Изменить…") { edit(server) }
                                        Button("Удалить…", role: .destructive) {
                                            if selected && model.state.enabled {
                                                message = "Сначала выберите другой сервер или выключите Zapret Local"
                                            } else { deleting = server }
                                        }
                                    } label: { Image(systemName: "ellipsis.circle") }
                                    .menuStyle(.borderlessButton).fixedSize()
                                    .accessibilityLabel("Действия с сервером \(server.name)")
                                }.padding(.vertical, 9)
                                Divider()
                            }
                        }
                    }.disabled(model.busy)
                }
            }
            if let info = message ?? model.state.error ?? model.notice {
                Text(info).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Удалить сервер из Zapret Local?", isPresented: Binding(get: { deleting != nil },
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
