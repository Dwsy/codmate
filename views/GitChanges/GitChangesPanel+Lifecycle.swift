import SwiftUI

extension GitChangesPanel {
    // MARK: - Lifecycle Modifier
    struct LifecycleModifier: ViewModifier {
        @Binding var expandedDirsStaged: Set<String>
        @Binding var expandedDirsUnstaged: Set<String>
        @Binding var expandedDirsBrowser: Set<String>
        @Binding var savedState: ReviewPanelState
        @Binding var mode: ReviewPanelState.Mode
        let vm: GitChangesViewModel
        let treeQuery: String
        let onSearchQueryChanged: (String) -> Void
        let onRebuildNodes: () -> Void
        let onRebuildDisplayed: () -> Void
        let onEnsureExpandAll: () -> Void
        let onRebuildBrowserDisplayed: () -> Void
        let onRefreshBrowserTree: () -> Void

        func body(content: Content) -> some View {
            var view = AnyView(
                content.onAppear {
                    restoreState()
                    onRebuildNodes()
                    onRebuildDisplayed()
                    onRebuildBrowserDisplayed()
                    onEnsureExpandAll()
                    onSearchQueryChanged(treeQuery)
                    if mode == .browser { onRefreshBrowserTree() }
                }
            )

            view = AnyView(
                view.onChange(of: vm.treeSnapshot) { _ in
                    onRebuildNodes()
                    onEnsureExpandAll()
                    if mode == .browser { onRefreshBrowserTree() }
                }
            )

            view = AnyView(
                view.onChange(of: treeQuery) { newValue in
                    onSearchQueryChanged(newValue)
                    onRebuildDisplayed()
                    onRebuildBrowserDisplayed()
                }
            )

            view = AnyView(
                view.onChange(of: expandedDirsStaged) { newVal in
                    savedState.expandedDirsStaged = newVal
                }
            )

            view = AnyView(
                view.onChange(of: expandedDirsUnstaged) { newVal in
                    savedState.expandedDirsUnstaged = newVal
                }
            )

            view = AnyView(
                view.onChange(of: expandedDirsBrowser) { newVal in
                    savedState.expandedDirsBrowser = newVal
                    onRebuildBrowserDisplayed()
                }
            )

            view = AnyView(
                view.onChange(of: vm.selectedPath) { newVal in
                    savedState.selectedPath = newVal
                }
            )

            view = AnyView(
                view.onChange(of: vm.selectedSide) { newVal in
                    savedState.selectedSideStaged = (newVal == .staged)
                }
            )

            view = AnyView(
                view.onChange(of: vm.showPreviewInsteadOfDiff) { newVal in
                    savedState.showPreview = newVal
                }
            )

            view = AnyView(
                view.onChange(of: vm.commitMessage) { newVal in
                    savedState.commitMessage = newVal
                }
            )

            view = AnyView(
                view.onChange(of: mode) { newVal in
                    savedState.mode = newVal
                    if newVal == .browser {
                        onRebuildBrowserDisplayed()
                        onRefreshBrowserTree()
                    }
                }
            )

            // Persist Graph visibility flag when it changes
            view = AnyView(
                view.onChange(of: savedState.showGraph) { _ in
                    // No-op: wiring point retained for completeness
                }
            )

            return view
        }

        private func restoreState() {
            var initial = savedState
            // Migrate legacy browser mode to diff mode:
            // Since the default mode has changed from .browser to .diff,
            // automatically migrate any saved .browser state to .diff.
            // User can still manually switch to browser or graph if needed.
            if initial.mode == .browser {
                initial.mode = .diff
                savedState = initial
            }

            if !initial.expandedDirsStaged.isEmpty || !initial.expandedDirsUnstaged.isEmpty {
                expandedDirsStaged = initial.expandedDirsStaged
                expandedDirsUnstaged = initial.expandedDirsUnstaged
            } else if !initial.expandedDirs.isEmpty {
                expandedDirsStaged = initial.expandedDirs
                expandedDirsUnstaged = initial.expandedDirs
            }
            if !initial.expandedDirsBrowser.isEmpty {
                expandedDirsBrowser = initial.expandedDirsBrowser
            }
            mode = initial.mode
            vm.selectedPath = initial.selectedPath
            if let stagedSide = initial.selectedSideStaged {
                vm.selectedSide = stagedSide ? .staged : .unstaged
            }
            vm.showPreviewInsteadOfDiff = initial.showPreview
            let savedMessage = initial.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            let liveMessage = vm.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !liveMessage.isEmpty && liveMessage != savedMessage {
                savedState.commitMessage = vm.commitMessage
            } else {
                vm.commitMessage = initial.commitMessage
            }
        }
    }
}
