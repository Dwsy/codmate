import Foundation

struct SessionsDiagnostics: Codable, Sendable {
    struct Probe: Codable, Sendable {
        var path: String
        var exists: Bool
        var isDirectory: Bool
        var enumeratedCount: Int
        var sampleFiles: [String]
        var enumeratorError: String?
    }

    var timestamp: Date
    // Sessions (.jsonl)
    var current: Probe
    var defaultRoot: Probe
    // Notes (.json)
    var notesCurrent: Probe
    var notesDefault: Probe
    // Projects (.json)
    var projectsCurrent: Probe
    var projectsDefault: Probe
    // Claude sessions (.jsonl)
    var claudeCurrent: Probe?
    var claudeDefault: Probe
    // Gemini sessions (.json)
    var geminiCurrent: Probe?
    var geminiDefault: Probe
    var suggestions: [String]
}

actor SessionsDiagnosticsService {
    private let fm: FileManager

    init(fileManager: FileManager = .default) {
        self.fm = fileManager
    }

    func run(
        currentRoot: URL,
        defaultRoot: URL,
        notesCurrentRoot: URL,
        notesDefaultRoot: URL,
        projectsCurrentRoot: URL,
        projectsDefaultRoot: URL,
        claudeCurrentRoot: URL?,
        claudeDefaultRoot: URL,
        geminiCurrentRoot: URL?,
        geminiDefaultRoot: URL
    ) async -> SessionsDiagnostics {
        let currentProbe = await probe(root: currentRoot, fileExtension: "jsonl")
        let defaultProbe = await probe(root: defaultRoot, fileExtension: "jsonl")
        let notesCurrent = await probe(root: notesCurrentRoot, fileExtension: "json")
        let notesDefault = await probe(root: notesDefaultRoot, fileExtension: "json")
        let projectsCurrent = await probe(root: projectsCurrentRoot, fileExtension: "json")
        let projectsDefault = await probe(root: projectsDefaultRoot, fileExtension: "json")
        let claudeCurrent = claudeCurrentRoot != nil ? await probe(root: claudeCurrentRoot!, fileExtension: "jsonl") : nil
        let claudeDefault = await probe(root: claudeDefaultRoot, fileExtension: "jsonl")
        let geminiCurrent = geminiCurrentRoot != nil ? await probe(root: geminiCurrentRoot!, fileExtension: "json") : nil
        let geminiDefault = await probe(root: geminiDefaultRoot, fileExtension: "json")

        var suggestions: [String] = []
        if currentProbe.enumeratedCount == 0, defaultProbe.enumeratedCount > 0,
            currentProbe.exists
        {
            suggestions.append("Switch sessions root to default path; it contains sessions.")
        }
        if !currentProbe.exists {
            suggestions.append("Current sessions root does not exist; create or select another directory.")
        }
        if currentProbe.exists, !currentProbe.isDirectory {
            suggestions.append("Current sessions root is not a directory; select a folder.")
        }
        if currentProbe.enumeratedCount == 0,
            currentProbe.enumeratorError == nil,
            defaultProbe.enumeratedCount == 0
        {
            suggestions.append("No .jsonl files found under both roots; ensure Codex CLI is writing sessions.")
        }

        // Notes suggestions
        if !notesCurrent.exists {
            suggestions.append("Notes directory does not exist; it will be created on demand under ~/.codmate/notes by default.")
        }
        if notesCurrent.exists, !notesCurrent.isDirectory {
            suggestions.append("Notes path is not a directory; select a folder.")
        }
        if notesCurrent.enumeratedCount == 0, notesDefault.enumeratedCount > 0 {
            suggestions.append("Notes directory is empty; consider switching to default ~/.codmate/notes or migrating.")
        }

        // Projects suggestions
        if !projectsCurrent.exists {
            suggestions.append("Projects directory does not exist; it will be created under ~/.codmate/projects.")
        }
        if projectsCurrent.exists, !projectsCurrent.isDirectory {
            suggestions.append("Projects path is not a directory; select a folder.")
        }

        // Claude suggestions (informational)
        if let cc = claudeCurrent {
            if !cc.exists {
                suggestions.append("Claude sessions directory not found; if you use Claude Code CLI, ensure it writes logs under ~/.claude/projects.")
            }
        } else if !claudeDefault.exists {
            suggestions.append("Claude default sessions directory (~/.claude/projects) not found.")
        }

        if let gc = geminiCurrent {
            if !gc.exists {
                suggestions.append("Gemini sessions directory not found; ensure Gemini CLI writes logs under ~/.gemini/tmp.")
            }
        } else if !geminiDefault.exists {
            suggestions.append("Gemini default sessions directory (~/.gemini/tmp) not found.")
        }

        return SessionsDiagnostics(
            timestamp: Date(),
            current: currentProbe,
            defaultRoot: defaultProbe,
            notesCurrent: notesCurrent,
            notesDefault: notesDefault,
            projectsCurrent: projectsCurrent,
            projectsDefault: projectsDefault,
            claudeCurrent: claudeCurrent,
            claudeDefault: claudeDefault,
            geminiCurrent: geminiCurrent,
            geminiDefault: geminiDefault,
            suggestions: suggestions
        )
    }

    // MARK: - Helpers
    func probe(root: URL, fileExtension: String) async -> SessionsDiagnostics.Probe {
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: root.path, isDirectory: &isDir)
        var count = 0
        var samples: [String] = []
        var enumError: String? = nil

        if exists, isDir.boolValue {
            if let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                // Collect URLs synchronously first to avoid Swift 6 async/iterator issues
                let urls = enumerator.compactMap { $0 as? URL }
                
                for url in urls {
                    if url.pathExtension.lowercased() == fileExtension.lowercased() {
                        count += 1
                        if samples.count < 10 { samples.append(url.path) }
                    }
                }
            } else {
                enumError = "Failed to open enumerator for \(root.path)"
            }
        }

        return .init(
            path: root.path,
            exists: exists,
            isDirectory: isDir.boolValue,
            enumeratedCount: count,
            sampleFiles: samples,
            enumeratorError: enumError
        )
    }
}
