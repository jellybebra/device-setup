import SwiftUI
import AppKit
import Combine
import ServiceManagement

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
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…", action: delegate.showSettings)
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        Group {
            if let model = delegate.model {
                ProxyPanel(model: model, manageServers: delegate.showServers, manageProfiles: delegate.showProfiles, manageSettings: delegate.showSettings)
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
    private var profilesWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func showProfiles() {
        guard let model else { return }
        if profilesWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Профили"
            window.contentView = NSHostingView(rootView: ProfileManager(model: model))
            window.contentMinSize = NSSize(width: 440, height: 240)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            profilesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        profilesWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        guard let model else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 180),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Настройки"
            window.contentView = NSHostingView(rootView: GeneralSettingsView(model: model))
            window.isReleasedWhenClosed = false; window.delegate = self; window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showServers() {
        guard let model else { return }
        model.refreshServers()
        if managerWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "VLESS-серверы"
            window.contentView = NSHostingView(rootView: ServerManager(model: model))
            window.contentMinSize = NSSize(width: 440, height: 240)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            managerWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        managerWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window === managerWindow { managerWindow = nil }
            if window === profilesWindow { profilesWindow = nil }
            if window === settingsWindow { settingsWindow = nil }
        }
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showProfiles()
        return true
    }
}

struct ProxyPanel: View {
    @ObservedObject var model: ProxyModel
    @ObservedObject private var probes: ServerProbes
    var manageServers: () -> Void
    var manageProfiles: () -> Void
    var manageSettings: () -> Void

    init(model: ProxyModel, manageServers: @escaping () -> Void, manageProfiles: @escaping () -> Void, manageSettings: @escaping () -> Void) {
        self.model = model
        self.probes = model.probes
        self.manageServers = manageServers
        self.manageProfiles = manageProfiles
        self.manageSettings = manageSettings
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
            if !model.state.configurations.isEmpty {
                HStack {
                    Text("Профиль").font(.system(size: 13))
                    Spacer()
                    Menu {
                        Picker("Профиль", selection: Binding(
                            get: { model.state.selectedProfileID },
                            set: { key in
                                guard let key, key != model.state.selectedProfileID else { return }
                                model.selectConfiguration(key)
                            }
                        )) {
                            if model.state.selectedProfileID == nil {
                                Text("Выберите профиль").tag(String?.none)
                            }
                            ForEach(model.state.configurations) { profile in
                                Text(profile.name).tag(Optional(profile.key))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 6) {
                            Text(selectedProfileName).lineLimit(1).truncationMode(.tail)
                            Image(systemName: "chevron.down").font(.system(size: 10)).accessibilityHidden(true)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .frame(maxWidth: 190, alignment: .trailing)
                    .disabled(model.busy)
                    .accessibilityLabel("Профиль")
                    .accessibilityValue(selectedProfileName)
                }
                Divider()
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
                    .frame(height: CGFloat(min(model.servers.count, 8) * 32))
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
                Button(action: manageProfiles) {
                    Text("Профили…").frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(action: manageSettings) {
                    Text("Настройки…").frame(maxWidth: .infinity, alignment: .leading)
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

    private var selectedProfileName: String {
        model.state.configurations.first { $0.key == model.state.selectedProfileID }?.name ?? "Выберите профиль"
    }

    private func serverRow(_ server: ProxyServer) -> some View {
        let selected = server.id == model.selectedServer?.id
        let pending = server.id == model.pendingServerID
        let status = pending ? (model.state.enabled ? "Подключение…" : "Выбор…")
            : selected ? (model.state.running ? "Подключён" : "Выбран") : ""

        let probeDescription: String
        switch probes.results[server.id] {
        case .checking: probeDescription = "Проверка соединения через VLESS…"
        case .success(let ms): probeDescription = "HTTPS через VLESS: \(ms) мс"
        case .failure(let error): probeDescription = error
        case nil: probeDescription = "Задержка ещё не проверена"
        }

        return Button { model.choose(server) } label: {
            HStack(spacing: 10) {
                ZStack {
                    if pending {
                        ProgressView().controlSize(.small).scaleEffect(0.75)
                    } else {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    }
                }
                .frame(width: 16, height: 16).accessibilityHidden(true)
                Text(server.name)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 16)
                probeStatus(server)
            }
            .frame(minHeight: 20)
        }
        .buttonStyle(MenuRowStyle())
        .disabled(model.busy)
        .accessibilityLabel(server.name)
        .accessibilityValue([status, probeDescription].filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help((status.isEmpty ? "Выбрать сервер \(server.name)" : "\(server.name) — \(status)") + "\n" + probeDescription)
    }

    private func probeStatus(_ server: ProxyServer) -> some View {
        Group {
            switch probes.results[server.id] {
            case .checking:
                ProgressView().controlSize(.small).scaleEffect(0.65)
            case .success(let ms):
                Text("\(ms) мс").monospacedDigit()
            case .failure:
                Text("Ошибка")
            case nil:
                Text("—")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .frame(width: 60, height: 16, alignment: .trailing)
        .accessibilityHidden(true)
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

@MainActor
private struct GeneralSettingsView: View {
    @ObservedObject var model: ProxyModel
    @State private var port = ""
    @State private var error: String?
    @State private var loginStatus: SMAppService.Status = .notRegistered

    private func setAutostart(_ enabled: Bool) {
        error = nil
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch { self.error = "Не удалось изменить автозапуск: " + error.localizedDescription }
        loginStatus = service.status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Автозапуск")
                Spacer()
                Toggle("Автозапуск", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { value in setAutostart(value) }
                )).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help("Запускать V2DPI автоматически при входе в macOS.")
            }
            if loginStatus == .requiresApproval {
                Button("Разрешить автозапуск в macOS…") { SMAppService.openSystemSettingsLoginItems() }
                    .font(.caption)
            }
            Divider()
            HStack {
                Text("Локальный порт")
                Spacer()
                TextField("1024–65535", text: $port).frame(width: 100)
                    .accessibilityLabel("Локальный порт")
            }
            if let error = error ?? model.state.error { Text(error).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Применить") {
                    guard let value = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)) else { error = "Введите номер порта"; return }
                    error = nil
                    Task { await model.setPort(value) }
                }.disabled(model.busy || port == String(model.state.port))
            }
        }.padding(20).frame(width: 340)
        .onAppear { port = String(model.state.port); loginStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }
}
