import SwiftUI
import AppKit
import Combine

@main
struct ZapretLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private static let trayIcon: NSImage = {
        let image = Bundle.main.url(forResource: "tray@2x", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: "Zapret Local")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        // Let SwiftUI own the status-item tracking session: pressed appearance,
        // placement, keyboard focus, outside-click dismissal and animation.
        MenuBarExtra {
            MenuContent(delegate: delegate)
        } label: {
            Image(nsImage: Self.trayIcon)
                .accessibilityLabel("Zapret Local")
                .help("Zapret Local")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuContent: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        Group {
            if let model = delegate.model {
                ProxyPanel(model: model).onAppear { model.appeared() }
            } else {
                ProgressView().padding(20).frame(width: 370)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var model: ProxyModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        // Start the saved proxy session on launch, even before opening the menu.
        model = ProxyModel()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct ProxyPanel: View {
    @ObservedObject var model: ProxyModel
    @FocusState private var editingPort: String?
    private let labelWidth: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Zapret Local").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                        .frame(width: 16, height: 16).accessibilityLabel("Изменение состояния")
                }
                Toggle("Включить", isOn: Binding(get: { model.state.running }, set: { _ in model.toggle() }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(model.busy)
                    .accessibilityLabel(model.state.running ? "Выключить прокси" : "Включить прокси")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                portRow("Zapret", text: $model.portText, port: model.state.port,
                        save: model.applyPort, copy: model.copyProxy, telegram: false)
                portRow("Telegram", text: $model.telegramPortText, port: model.state.telegram.port,
                        save: model.applyTelegramPort, copy: model.copyTelegram, telegram: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Стратегия").frame(width: labelWidth, alignment: .leading)
                    NativePicker(selection: Binding(get: { model.state.selection.strategy }, set: { model.selectStrategy($0) }),
                                 options: StrategyPreset.all.map { ($0.id, $0.title) }, label: "Стратегия обхода")
                        .frame(maxWidth: .infinity).disabled(model.busy)
                }
                HStack(spacing: 10) {
                    Text("IP-сети").frame(width: labelWidth, alignment: .leading)
                    NativePicker(selection: Binding(get: { model.state.selection.ipset }, set: { model.selectIPSet($0) }),
                                 options: [("cloudflare", "Cloudflare"), ("loaded", "Список Flowseal"),
                                           ("any", "Все IPv4"), ("none", "Только домены")], label: "Режим IP-сетей")
                        .frame(maxWidth: .infinity).disabled(model.busy || model.state.selection.strategy == "local")
                }
                Button("Переподключить") { model.reconnect() }.disabled(model.busy)
            }.font(.system(size: 13))
            Divider()
            Toggle("Запускать при входе", isOn: Binding(get: { model.autostart }, set: { model.setAutostart($0) }))
                .font(.system(size: 13)).toggleStyle(.switch).controlSize(.mini).disabled(model.busy)
            if let message = model.notice ?? model.state.error ?? model.state.telegram.error {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Divider()
            Button { NSApp.terminate(nil) } label: {
                Text("Выйти").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(MenuRowStyle()).padding(.horizontal, -10)
                .padding(.top, -8).padding(.bottom, -10)
        }
        .padding(20).frame(width: 370)
    }

    private func portRow(_ title: String, text: Binding<String>, port: UInt16,
                         save: @escaping () -> Void, copy: @escaping () -> Void, telegram: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13)).frame(width: labelWidth, alignment: .leading)
            HStack(spacing: 5) {
                Text("127.0.0.1:").foregroundStyle(.secondary)
                TextField("Порт", text: text)
                    .multilineTextAlignment(.center).textFieldStyle(.roundedBorder).frame(width: 62)
                    .focused($editingPort, equals: title)
                    .onSubmit { editingPort = nil; save() }
                    .disabled(model.busy).accessibilityLabel(telegram ? "Порт Telegram" : "Порт прокси")
            }.font(.system(size: 12, design: .monospaced))
            Spacer(minLength: 0)
            Button {
                if text.wrappedValue != String(port) { editingPort = nil; save() } else { copy() }
            } label: {
                Image(systemName: text.wrappedValue != String(port) ? "checkmark" : "doc.on.doc")
                    .frame(width: 18, height: 20)
            }.buttonStyle(.borderless).disabled(model.busy)
                .help(text.wrappedValue != String(port) ? "Сохранить порт" : "Скопировать ссылку")
                .accessibilityLabel(text.wrappedValue != String(port) ? "Сохранить порт \(title)" : "Скопировать \(title)")
            if telegram {
                Button { model.connectTelegram() } label: {
                    Image(systemName: "arrow.up.right").frame(width: 18, height: 20)
                }.buttonStyle(.borderless)
                    .disabled(model.busy || !model.state.telegram.running || text.wrappedValue != String(port))
                    .help("Подключить Telegram").accessibilityLabel("Подключить Telegram")
            } else {
                Color.clear.frame(width: 18, height: 20)
            }
        }
    }
}

// NSPopUpButton fills its allocated width; SwiftUI's menu picker otherwise
// sizes its bezel to the selected title even inside an equal-width frame.
struct NativePicker: NSViewRepresentable {
    @Binding var selection: String
    let options: [(id: String, title: String)]
    let label: String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.font = .systemFont(ofSize: 13)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selected(_:))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.itemArray.map({ $0.representedObject as? String }) != options.map({ Optional($0.id) }) {
            button.removeAllItems()
            for option in options {
                button.addItem(withTitle: option.title)
                button.lastItem?.representedObject = option.id
            }
        }
        if let index = options.firstIndex(where: { $0.id == selection }) { button.selectItem(at: index) }
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject {
        var parent: NativePicker
        init(_ parent: NativePicker) { self.parent = parent }
        @objc func selected(_ sender: NSPopUpButton) {
            if let id = sender.selectedItem?.representedObject as? String { parent.selection = id }
        }
    }
}

private struct MenuRowStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovered ? 0.08 : 0))
            }
            .onHover { hovered = $0 }
    }
}
