import AppKit
import SwiftUI

#if canImport(SwiftTerm)
    import SwiftTerm

    @MainActor
    struct TerminalHostView: NSViewRepresentable {
        // A unique key for a single embedded terminal instance.
        // Do not reuse across different panes (e.g. Resume vs New).
        let terminalKey: String
        let initialCommands: String
        struct ConsoleSpec { let executable: String; let args: [String]; let cwd: String; let env: [String:String] }
        var consoleSpec: ConsoleSpec? = nil
        let font: NSFont
        let cursorStyleOption: TerminalCursorStyleOption
        let isDark: Bool

        func makeCoordinator() -> Coordinator {
            let coordinator = Coordinator()
            coordinator.configureCursorStyles(
                preferred: cursorStyleOption.cursorStyleValue,
                inactive: cursorStyleOption.steadyCursorStyleValue)
            return coordinator
        }

        func makeNSView(context: Context) -> NSView {
            let container = NSView(frame: .zero)
            container.translatesAutoresizingMaskIntoConstraints = false
            attachTerminalIfNeeded(in: container, coordinator: context.coordinator)
            return container
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            attachTerminalIfNeeded(in: nsView, coordinator: context.coordinator)
        }

        static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
            if let key = coordinator.currentSessionKey {
                TerminalSessionManager.shared.detachView(for: key)
            }
            TerminalSessionManager.shared.registerActiveView(nil, sessionKey: nil)
        }

        private func applyTheme(_ v: CodMateTerminalView) {
            // Transparent background for visual integration with surrounding surface.
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.clear.cgColor
            if isDark {
                v.caretColor = NSColor.white
                v.nativeForegroundColor = NSColor(white: 0.9, alpha: 1.0)
                v.nativeBackgroundColor = .clear
                v.selectedTextBackgroundColor = NSColor(white: 0.3, alpha: 0.6)
            } else {
                v.caretColor = NSColor.black
                v.nativeForegroundColor = NSColor(white: 0.10, alpha: 1.0)
                v.nativeBackgroundColor = .clear
                v.selectedTextBackgroundColor = NSColor(white: 0.7, alpha: 0.4)
            }
        }

        private func applyCursorStyle(_ v: CodMateTerminalView) {
            v.getTerminal().setCursorStyle(cursorStyleOption.cursorStyleValue)
        }

        @MainActor
        final class Coordinator: NSObject {
            weak var terminalView: CodMateTerminalView?
            var currentSessionKey: String?
            weak var container: NSView?
            var preferredCursorStyle: CursorStyle = .blinkBlock
            var inactiveCursorStyle: CursorStyle = .steadyBlock
            private var isActiveTerminal = false

            func attach(to view: CodMateTerminalView) {
                terminalView = view
                view.menu = makeMenu()
            }

            private func makeMenu() -> NSMenu {
                let m = NSMenu()
                let copy = NSMenuItem(
                    title: "Copy", action: #selector(copyAction(_:)), keyEquivalent: "")
                copy.target = self
                let paste = NSMenuItem(
                    title: "Paste", action: #selector(pasteAction(_:)), keyEquivalent: "")
                paste.target = self
                let selectAll = NSMenuItem(
                    title: "Select All", action: #selector(selectAllAction(_:)), keyEquivalent: "")
                selectAll.target = self
                m.items = [copy, paste, NSMenuItem.separator(), selectAll]
                return m
            }

            @objc func copyAction(_ sender: Any?) {
                guard let term = terminalView else { return }
                // Delegate copy to the view; our subclass sanitizes the pasteboard.
                if NSApp.sendAction(#selector(NSText.copy(_:)), to: term, from: sender) { return }
                NSSound.beep()
            }

            @objc func pasteAction(_ sender: Any?) {
                guard let term = terminalView else { return }
                let pb = NSPasteboard.general
                if let s = pb.string(forType: .string), !s.isEmpty {
                    term.send(txt: s)
                }
            }

            @objc func selectAllAction(_ sender: Any?) {
                guard let term = terminalView else { return }
                _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: term, from: sender)
            }
            // Immediate relayout to keep session switching responsive.
            func relayoutNow(_ view: CodMateTerminalView) {
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                view.needsDisplay = true
            }

            func configureCursorStyles(preferred: CursorStyle, inactive: CursorStyle) {
                preferredCursorStyle = preferred
                inactiveCursorStyle = inactive
            }

            func handleFocusChange(isActive: Bool) {
                isActiveTerminal = isActive
                guard let terminal = terminalView else { return }
                let targetStyle = isActive ? preferredCursorStyle : inactiveCursorStyle
                terminal.getTerminal().setCursorStyle(targetStyle)
                terminal.setOverlaySuppressed(!isActive)
                // Update cursor style tracking for TUI apps that override cursor settings
                terminal.preferredCursorStyle = targetStyle
                terminal.isActiveTerminal = isActive
            }
        }

        private func attachTerminalIfNeeded(in container: NSView, coordinator: Coordinator) {
            coordinator.container = container
            coordinator.configureCursorStyles(
                preferred: cursorStyleOption.cursorStyleValue,
                inactive: cursorStyleOption.steadyCursorStyleValue)

            let terminalView = ensureTerminalView(in: container, coordinator: coordinator)
            let session = TerminalSessionManager.shared.session(
                for: terminalKey,
                initialCommands: initialCommands,
                consoleSpec: consoleSpec.map { spec in
                    TerminalSessionManager.ConsoleSpec(
                        executable: spec.executable, args: spec.args, cwd: spec.cwd, env: spec.env)
                }
            )

            if coordinator.currentSessionKey != terminalKey
                || !terminalView.isAttached(to: session.terminal) {
                if let oldKey = coordinator.currentSessionKey {
                    TerminalSessionManager.shared.detachView(for: oldKey)
                }
                terminalView.sessionID = terminalKey
                terminalView.attach(
                    to: session,
                    fullRedraw: coordinator.currentSessionKey == nil
                )
                coordinator.currentSessionKey = terminalKey
                TerminalSessionManager.shared.registerActiveView(terminalView, sessionKey: terminalKey)
                DispatchQueue.main.async {
                    container.window?.makeFirstResponder(terminalView)
                }
                if consoleSpec == nil,
                   !initialCommands.isEmpty,
                   TerminalSessionManager.shared.shouldBootstrap(key: terminalKey)
                {
                    TerminalSessionManager.shared.injectInitialCommandsOnce(
                        key: terminalKey,
                        view: terminalView,
                        payload: initialCommands
                    )
                }
            }

            if terminalView.font != font {
                terminalView.font = font
                coordinator.relayoutNow(terminalView)
            }

            applyTheme(terminalView)
            applyCursorStyle(terminalView)
            
            // Re-enable built-in scroller for reliable interaction
            terminalView.enableBuiltInScroller()
            
            // Freeze grid reflow during live-resize; reflow once at the end to avoid duplicate/garbled text
            terminalView.deferReflowDuringLiveResize = true
            
            terminalView.onScrollActivity = { _ in
                TerminalSessionManager.shared.recordScrollActivity(for: terminalKey)
            }
            terminalView.onFocusChanged = { [weak coordinator] isActive in
                coordinator?.handleFocusChange(isActive: isActive)
            }
            let isActive = container.window?.firstResponder === terminalView
            coordinator.handleFocusChange(isActive: isActive)
            coordinator.relayoutNow(terminalView)
            TerminalSessionManager.shared.registerActiveView(terminalView, sessionKey: terminalKey)
        }

        private func ensureTerminalView(
            in container: NSView,
            coordinator: Coordinator
        ) -> CodMateTerminalView {
            if let existing = coordinator.terminalView {
                return existing
            }
            let view = CodMateTerminalView(frame: .zero)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.font = font
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            coordinator.attach(to: view)
            return view
        }
    }

#else
    struct TerminalHostView: View {
        let terminalKey: String
        let initialCommands: String
        let font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
        var body: some View { Text("SwiftTerm not available") }
    }
#endif
