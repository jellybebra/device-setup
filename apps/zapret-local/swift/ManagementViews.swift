import SwiftUI
import AppKit

struct ManagementRow<Actions: View>: View {
    let name: String
    let selected: Bool
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(name).font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityValue(selected ? "Выбран" : "")
                HStack(spacing: 6) { actions() }
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .frame(minHeight: 44)
            Divider().padding(.leading, 34)
        }
    }
}

/// Installs a native toolbar in the AppKit window hosting a manager.
struct ManagementToolbar: NSViewRepresentable {
    let label: String
    let isEnabled: Bool
    var onAdd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.coordinator = context.coordinator
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: AttachmentView, context: Context) {
        context.coordinator.onAdd = onAdd
        context.coordinator.item.label = label
        context.coordinator.item.toolTip = label
        context.coordinator.item.isEnabled = isEnabled
    }

    final class AttachmentView: NSView {
        var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let coordinator else { return }
            window.toolbarStyle = .unifiedCompact
            window.toolbar = coordinator.toolbar
        }
    }

    final class Coordinator: NSObject, NSToolbarDelegate {
        var onAdd: () -> Void = {}
        let item = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("add"))
        lazy var toolbar: NSToolbar = {
            let toolbar = NSToolbar(identifier: "management")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            return toolbar
        }()

        override init() {
            super.init()
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(add)
            item.autovalidates = false
        }

        @objc private func add() { onAdd() }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [.flexibleSpace, item.itemIdentifier]
        }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [.flexibleSpace, item.itemIdentifier]
        }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            identifier == item.itemIdentifier ? item : nil
        }
    }
}
