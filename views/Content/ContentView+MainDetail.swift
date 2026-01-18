import SwiftUI
import GhosttyKit

extension ContentView {
    // Extracted to reduce ContentView.swift size
    var mainDetailContent: some View {
        Group {
            // Session-level Git Review is removed from Tasks mode. Show Terminal or Conversation only.
            // Non-review paths: either Terminal tab or Timeline
            if selectedDetailTab == .terminal {
                if let terminalKey = visibleTerminalKeyInDetail() {
                    if let summary = summaryLookup[terminalKey] {
                        EmbeddedTerminalView(
                            sessionID: terminalKey,
                            initialCommands: terminalHostInitialCommands(for: terminalKey),
                            worktreePath: workingDirectory(for: summary)
                        )
                        .id(terminalKey)  // Use session ID directly for stability
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                    } else if let anchorData = pendingEmbeddedRekeys.first(where: { $0.anchorId == terminalKey }) {
                        EmbeddedTerminalView(
                            sessionID: terminalKey,
                            initialCommands: terminalHostInitialCommands(for: terminalKey),
                            worktreePath: anchorData.expectedCwd
                        )
                        .id(terminalKey)  // Use anchor ID directly for stability
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                    } else {
                        VStack {
                            Text("No terminal session available")
                                .foregroundStyle(.secondary)
                            if let focused = focusedSummary {
                                Button("Start Terminal") {
                                    startEmbedded(for: focused)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let focused = focusedSummary {
                    // Terminal tab is selected but no terminal is available
                    VStack {
                        Text("No terminal session available")
                            .foregroundStyle(.secondary)
                        Button("Start Terminal") {
                            startEmbedded(for: focused)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // No focused session
                    VStack {
                        Text("No session selected")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let focused = focusedSummary {
                SessionDetailView(
                    summary: focused,
                    isProcessing: isPerformingAction,
                    onResume: {
                        guard let current = focusedSummary else { return }
                        #if APPSTORE
                        openPreferredExternal(for: current)
                        #else
                        if viewModel.preferences.defaultResumeUseEmbeddedTerminal {
                            startEmbedded(for: current)
                        } else {
                            openPreferredExternal(for: current)
                        }
                        #endif
                    },
                    onReveal: {
                        guard let current = focusedSummary else { return }
                        viewModel.reveal(session: current)
                    },
                    onDelete: presentDeleteConfirmation,
                    columnVisibility: $columnVisibility,
                    preferences: preferences
                )
                .environmentObject(viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                placeholder
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .codMateTerminalExited)) { note in
            guard let info = note.userInfo as? [String: Any],
                  let key = info["sessionID"] as? String,
                  !key.isEmpty else { return }
            let exitCode = info["exitCode"] as? Int32
            print("[EmbeddedTerminal] Process for \(key) terminated, exitCode=\(exitCode.map(String.init) ?? "nil")")
            if runningSessionIDs.contains(key) {
                stopEmbedded(forID: key)
            }
        }
    }
}
