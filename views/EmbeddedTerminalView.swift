import SwiftUI
import GhosttyKit
import CGhostty

/// Embedded Ghostty terminal view
/// Directly uses TerminalScrollView provided by GhosttyKit
struct EmbeddedTerminalView: View {
    let sessionID: String
    let initialCommands: String
    let worktreePath: String

    @EnvironmentObject private var ghosttyApp: Ghostty.App

    var body: some View {
        Group {
            if let ghosttyApp = ghosttyApp.app {
                GhosttyTerminalViewRepresentable(
                    sessionID: sessionID,
                    worktreePath: worktreePath,
                    initialCommands: initialCommands,
                    ghosttyApp: ghosttyApp,
                    appWrapper: self.ghosttyApp
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    NSLog("[EmbeddedTerminalView] ghosttyApp is available")
                }
            } else {
                VStack {
                    Text("Terminal Initializing...")
                        .foregroundStyle(.secondary)
                    ProgressView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    NSLog("[EmbeddedTerminalView] ghosttyApp is nil, showing loading state")
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// NSViewRepresentable wrapper for Ghostty Terminal
private struct GhosttyTerminalViewRepresentable: NSViewRepresentable {
    let sessionID: String
    let worktreePath: String
    let initialCommands: String
    let ghosttyApp: ghostty_app_t
    let appWrapper: Ghostty.App

    func makeNSView(context: Context) -> TerminalScrollView {
        if let cached = GhosttySessionManager.shared.getScrollView(for: sessionID) {
            NSLog("[GhosttyTerminalViewRepresentable] reusing cached TerminalScrollView for %@", sessionID)
            return cached
        }

        NSLog("[GhosttyTerminalViewRepresentable] makeNSView called")
        NSLog("[GhosttyTerminalViewRepresentable]   worktreePath: %@", worktreePath)
        NSLog("[GhosttyTerminalViewRepresentable]   initialCommands: %@", initialCommands)

        // Use a stable paneId based on worktreePath to ensure the same terminal session
        // is reused when the view is recreated with the same worktreePath
        let paneId = "embedded:\(sessionID)"

        let terminalView = GhosttyTerminalView(
            frame: .zero,
            worktreePath: worktreePath,
            ghosttyApp: ghosttyApp,
            appWrapper: appWrapper,
            paneId: paneId,
            command: nil
        )
        NSLog("[GhosttyTerminalViewRepresentable] GhosttyTerminalView created with paneId: %@", paneId)

        let scrollView = TerminalScrollView(
            contentSize: CGSize(width: 800, height: 600),
            surfaceView: terminalView
        )
        NSLog("[GhosttyTerminalViewRepresentable] TerminalScrollView created")
        GhosttySessionManager.shared.setScrollView(scrollView, for: sessionID)

        // Store the initial commands in the coordinator to track changes
        context.coordinator.pendingCommands = initialCommands.isEmpty ? nil : initialCommands
        context.coordinator.worktreePath = worktreePath
        context.coordinator.didInjectInitialCommands = false

        terminalView.onReady = { [weak terminalView, weak coordinator = context.coordinator] in
            guard let terminalView, let coordinator else { return }
            guard !coordinator.didInjectInitialCommands else { return }
            guard let commands = coordinator.pendingCommands, !commands.isEmpty else { return }
            let trimmed = commands.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            coordinator.didInjectInitialCommands = true
            let payload = commands.hasSuffix("\n") || commands.hasSuffix("\r")
                ? commands
                : commands + "\n"
            terminalView.sendText(payload)
        }

        // Ensure the view is properly retained by setting a non-zero frame
        // This helps SwiftUI recognize the view as valid
        scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        NSLog("[GhosttyTerminalViewRepresentable] View setup complete, frame=%@", NSStringFromRect(scrollView.frame))

        return scrollView
    }

    func updateNSView(_ nsView: TerminalScrollView, context: Context) {
        // Track if this is the first update after view creation
        let isFirstUpdate = context.coordinator.pendingCommands == nil && context.coordinator.worktreePath.isEmpty

        // Only log if something actually changed to reduce noise
        let commandsChanged = context.coordinator.pendingCommands != initialCommands
        let pathChanged = context.coordinator.worktreePath != worktreePath

        if isFirstUpdate {
            NSLog("[GhosttyTerminalViewRepresentable] updateNSView: first update, window=%@",
                  nsView.window != nil ? "YES" : "NO")
        } else if commandsChanged || pathChanged {
            NSLog("[GhosttyTerminalViewRepresentable] updateNSView: commandsChanged=%@, pathChanged=%@",
                  commandsChanged ? "YES" : "NO", pathChanged ? "YES" : "NO")
        }

        // Update coordinator state
        if commandsChanged {
            if !context.coordinator.didInjectInitialCommands {
                context.coordinator.pendingCommands = initialCommands.isEmpty ? nil : initialCommands
            }
        }
        if pathChanged {
            context.coordinator.worktreePath = worktreePath
        }

        // Note: We don't recreate the terminal view here because initialCommands and worktreePath
        // should only be set once when the view is first created. The view will be recreated
        // by SwiftUI if the id() changes or if makeNSView is called again.

        // Theme updates are managed by Ghostty.App, no manual updates needed
        // View size updates are handled by TerminalScrollView's layout() method
        // We should not skip updates even if the window is not ready yet, as the view may be in the process of being added to the view hierarchy
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var pendingCommands: String? = nil
        var worktreePath: String = ""
        var didInjectInitialCommands: Bool = false
    }
}
