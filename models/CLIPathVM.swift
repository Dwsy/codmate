import Foundation

@MainActor
final class CLIPathVM: ObservableObject {
    struct CLIInfo: Equatable {
        var path: String?
        var version: String?
    }

    @Published var codex: CLIInfo = .init(path: nil, version: nil)
    @Published var claude: CLIInfo = .init(path: nil, version: nil)
    @Published var gemini: CLIInfo = .init(path: nil, version: nil)
    @Published var pathEnv: String = ""
    @Published var sandboxOn: Bool = false

    func refresh() {
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let fallbackPath = CLIEnvironment.buildBasePATH()
        self.pathEnv = fallbackPath
        self.sandboxOn = sandboxed
        if sandboxed {
            let brew = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
            let usrLocal = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
            _ = SecurityScopedBookmarks.shared.startAccessDynamic(for: brew)
            _ = SecurityScopedBookmarks.shared.startAccessDynamic(for: usrLocal)
        }
        Task(priority: .userInitiated) { @MainActor in
            let snapshot = await Task.detached {
                let path = CLIEnvironment.resolvedPATHForCLI(sandboxed: sandboxed)
                let codexPath = CLIEnvironment.resolveExecutablePath("codex", path: path)
                let claudePath = CLIEnvironment.resolveExecutablePath("claude", path: path)
                let geminiPath = CLIEnvironment.resolveExecutablePath("gemini", path: path)
                let codexVersion = codexPath.flatMap { CLIEnvironment.version(atExecutablePath: $0, path: path) }
                let claudeVersion = claudePath.flatMap { CLIEnvironment.version(atExecutablePath: $0, path: path) }
                let geminiVersion = geminiPath.flatMap { CLIEnvironment.version(atExecutablePath: $0, path: path) }
                return (
                    path: path,
                    sandboxOn: sandboxed,
                    codex: CLIInfo(path: codexPath, version: codexVersion),
                    claude: CLIInfo(path: claudePath, version: claudeVersion),
                    gemini: CLIInfo(path: geminiPath, version: geminiVersion)
                )
            }.value
            self.pathEnv = snapshot.path
            self.sandboxOn = snapshot.sandboxOn
            self.codex = snapshot.codex
            self.claude = snapshot.claude
            self.gemini = snapshot.gemini
        }
    }
}
