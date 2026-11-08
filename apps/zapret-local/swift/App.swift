import SwiftUI
import AppKit
import Combine

@main
struct ZapretLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var model: ProxyModel?
    private var observation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        let model = ProxyModel()
        self.model = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            let icon = Bundle.main.url(forResource: "tray@2x", withExtension: "png")
                .flatMap { NSImage(contentsOf: $0) }
                ?? NSImage(systemSymbolName: "network", accessibilityDescription: "Zapret Local")!
            icon.size = NSSize(width: 18, height: 18)
            icon.isTemplate = true
            button.image = icon
            button.imagePosition = .imageOnly
            button.toolTip = "Zapret Local"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Zapret Local")
        }
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: ProxyPanel(model: model))
        observation = model.$state.sink { [weak self] state in
            self?.statusItem?.button?.toolTip = state.running
                ? "Zapret Local · 127.0.0.1:\(state.port)" : "Zapret Local · выключен"
        }
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = launchEvent?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == keyAELaunchedAsLogInItem
            || launchEvent?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
        if !loginLaunch && !ProcessInfo.processInfo.arguments.contains("--autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPopover() }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let open = NSMenuItem(title: "Открыть", action: #selector(openPopover), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else { showPopover() }
    }

    @objc private func openPopover() { showPopover() }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        model?.appeared()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPopover()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct ProxyPanel: View {
    @ObservedObject var model: ProxyModel
    @FocusState private var editingPort: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Zapret Local").font(.system(size: 17, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle().fill(model.state.running ? Color.primary : Color.secondary.opacity(0.35)).frame(width: 5, height: 5)
                        Text(model.busy ? "Подождите…" : model.state.running ? "Работает" : "Выключен")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("Включить", isOn: Binding(get: { model.state.running }, set: { _ in model.toggle() }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(model.busy)
                    .accessibilityLabel(model.state.running ? "Выключить прокси" : "Включить прокси")
            }
            Divider()
            HStack(spacing: 8) {
                Text("127.0.0.1").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                Text(":").foregroundStyle(.tertiary)
                TextField("Порт", text: $model.portText)
                    .font(.system(size: 13, design: .monospaced)).multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder).frame(width: 66).focused($editingPort)
                    .onSubmit { editingPort = false; model.applyPort() }.disabled(model.busy)
                    .accessibilityLabel("Порт прокси")
                if model.portText != String(model.state.port) {
                    Button { editingPort = false; model.applyPort() } label: { Image(systemName: "checkmark") }
                        .buttonStyle(.borderless).help("Сохранить порт").disabled(model.busy)
                } else {
                    Button { model.copyProxy() } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Скопировать ссылку для v2rayN")
                        .accessibilityLabel("Скопировать прокси")
                }
            }
            Toggle("Запускать при входе", isOn: Binding(get: { model.autostart }, set: { model.setAutostart($0) }))
                .font(.system(size: 13)).toggleStyle(.switch).controlSize(.mini).disabled(model.busy)
            if let message = model.notice ?? model.state.error {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(20).frame(width: 300)
    }
}
