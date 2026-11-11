import SwiftUI
import AppKit
import Combine

@main
struct ZapretLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private static let trayIcon: NSImage = {
        let image = Bundle.main.url(forResource: "tray@2x", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: "V2DPI")!
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
                .accessibilityLabel("V2DPI")
                .help("V2DPI")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuContent: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        Group {
            if let model = delegate.model {
                ProxyPanel(model: model, manageServers: delegate.showServers)
            } else {
                ProgressView().padding(12).frame(width: 300)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    @Published private(set) var model: ProxyModel?

    private var managerWindow: NSWindow?

    func showServers() {
        guard let model else { return }
        model.refreshServers()
        if managerWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "VLESS-серверы"
            window.contentView = NSHostingView(rootView: ServerManager(model: model))
            window.contentMinSize = NSSize(width: 440, height: 380)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            managerWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        managerWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        managerWindow = nil
    }

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
    @ObservedObject private var probes: ServerProbes
    var manageServers: () -> Void

    init(model: ProxyModel, manageServers: @escaping () -> Void) {
        self.model = model
        self.probes = model.probes
        self.manageServers = manageServers
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("V2DPI").font(.system(size: 14, weight: .semibold))
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                        .frame(width: 16, height: 16).accessibilityLabel("Изменение состояния")
                }
                Toggle("Включить", isOn: Binding(get: { model.state.enabled }, set: { _ in model.toggle() }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(model.busy)
                    .accessibilityLabel(model.state.enabled ? "Выключить прокси" : "Включить прокси")
            }
            VStack(alignment: .leading, spacing: 0) {
                if model.servers.isEmpty {
                    Text("Нет серверов").font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.servers) { server in
                                serverRow(server)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: CGFloat(min(model.servers.count, 8) * 28))
                    .padding(.horizontal, -6)
                }
            }
            if let message = model.state.error ?? model.notice {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Divider()
            VStack(spacing: 0) {
                Button { probes.checkAll(model.servers) } label: {
                    Text(probes.isChecking ? "Проверка…" : "Проверить все")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(probes.isChecking || model.servers.isEmpty)
                .help("Проверить HTTPS-соединение через каждый VLESS-сервер")
                Button(action: manageServers) {
                    Text("Управление серверами…").frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { NSApp.terminate(nil) } label: {
                    Text("Выйти").frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(MenuRowStyle())
            .padding(.horizontal, -6)
            .padding(.vertical, -4)
        }
        .padding(12).frame(width: 300)
        .onAppear { model.refreshServers() }
    }

    private func serverRow(_ server: ProxyServer) -> some View {
        let selected = server.id == model.selectedServer?.id
        let pending = server.id == model.pendingServerID
        let status = pending ? (model.state.enabled ? "Подключение…" : "Выбор…")
            : selected ? (model.state.running ? "Подключён" : "Выбран") : ""

        return HStack(spacing: 0) {
            Button { model.choose(server) } label: {
                Text(server.name)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 16)
            }
            .buttonStyle(MenuRowStyle())
            .disabled(model.busy)
            .accessibilityLabel(server.name)
            .accessibilityValue(status)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(status.isEmpty ? "Выбрать сервер \(server.name)" : "\(server.name) — \(status)")

            probeButton(server)
            ZStack {
                if pending {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                } else if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 16, height: 16).padding(.trailing, 6).accessibilityHidden(true)
        }
    }

    private func probeButton(_ server: ProxyServer) -> some View {
        let result = probes.results[server.id]
        let description: String
        switch result {
        case .checking: description = "Проверка соединения через VLESS…"
        case .success(let ms): description = "HTTPS через VLESS: \(ms) мс. Нажмите, чтобы проверить снова"
        case .failure(let error): description = "\(error). Нажмите, чтобы повторить проверку"
        case nil: description = "Проверить HTTPS-соединение через VLESS"
        }

        return Button { probes.check(server) } label: {
            Group {
                switch result {
                case .checking:
                    ProgressView().controlSize(.small).scaleEffect(0.65)
                case .success(let ms):
                    Text("\(ms) мс").monospacedDigit()
                case .failure:
                    Text("Ошибка")
                case nil:
                    Image(systemName: "arrow.clockwise")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(width: 60, height: 16)
        }
        .buttonStyle(MenuRowStyle())
        .disabled(result == .checking)
        .accessibilityLabel("Проверить сервер \(server.name)")
        .accessibilityValue(description)
        .help(description)
    }
}

private struct MenuRowStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 6).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(enabled ? (configuration.isPressed ? 0.14 : hovered ? 0.08 : 0) : 0))
            }
            .onHover { hovered = $0 }
    }
}
