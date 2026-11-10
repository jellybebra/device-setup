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
                ProgressView().padding(20).frame(width: 370)
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
    var manageServers: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            HStack {
                Text("Сервер").foregroundStyle(.secondary)
                Spacer()
                Menu(model.selectedServer?.name ?? "Текущий профиль") {
                    ForEach(model.servers) { server in
                        Button { model.choose(server) } label: {
                            if server.id == model.selectedServer?.id {
                                Label(server.name, systemImage: "checkmark")
                            } else { Text(server.name) }
                        }
                    }
                }.disabled(model.busy || model.servers.isEmpty)
            }
            Button("Управление серверами…", action: manageServers)
            if let message = model.state.error ?? model.notice {
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
        .onAppear { model.refreshServers() }
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
