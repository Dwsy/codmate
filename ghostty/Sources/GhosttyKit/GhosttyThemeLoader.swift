import Foundation
import os.log

/// Utility for loading and managing Ghostty terminal themes
@MainActor
public struct GhosttyThemeLoader {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai.umate.codmate", category: "GhosttyThemeLoader")
    
    /// Curated list of popular/well-known themes to show in the picker
    /// Users can still use any theme by typing its name, but this list provides quick access
    public static let curatedThemeNames: [String] = [
        // Default/System themes
        "Xcode Dark",
        "Xcode Light",
        "Dark",
        "Light",
        
        // Popular color schemes
        "Atom One Dark",
        "Atom One Light",
        "Nord",
        "Nord Light",
        "Dracula",
        "Monokai Pro",
        "Monokai Pro Light",
        "Solarized Dark Higher Contrast",
        "Solarized Light",
        "Gruvbox Dark",
        "Gruvbox Light",
        "One Dark",
        "One Light",
    ]
    
    /// Load all available theme names from the Package resources
    public static func loadAvailableThemes() -> [String] {
        guard let themesURL = Bundle.module.url(forResource: "themes", withExtension: nil, subdirectory: nil) else {
            logger.warning("Ghostty themes resource not found")
            return curatedThemeNames
        }
        
        let themesPath = themesURL.path
        let fm = FileManager.default
        
        guard let themeFiles = try? fm.contentsOfDirectory(atPath: themesPath) else {
            logger.warning("Unable to read themes from \(themesPath)")
            return curatedThemeNames
        }
        
        // Filter out directories and hidden files, sort alphabetically
        let availableThemes = themeFiles.filter { file in
            let path = (themesPath as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return false }
            return !isDir.boolValue && !file.hasPrefix(".")
        }.sorted()
        
        // Return curated themes that exist, plus any additional themes
        // Prioritize curated themes at the top
        var result: [String] = []
        var seen = Set<String>()
        
        // Add curated themes first (if they exist)
        for theme in curatedThemeNames {
            if availableThemes.contains(theme) {
                result.append(theme)
                seen.insert(theme)
            }
        }
        
        // Add a separator if we have both curated and other themes
        if !result.isEmpty && result.count < availableThemes.count {
            // Add other popular themes that aren't in curated list
            let additionalPopular = availableThemes.filter { theme in
                !seen.contains(theme) && (
                    theme.contains("Dark") || theme.contains("Light") ||
                    theme.contains("Nord") || theme.contains("Dracula") ||
                    theme.contains("Monokai") || theme.contains("Solarized") ||
                    theme.contains("Gruvbox") || theme.contains("Atom")
                )
            }
            if !additionalPopular.isEmpty {
                result.append(contentsOf: additionalPopular.sorted())
                additionalPopular.forEach { seen.insert($0) }
            }
        }
        
        logger.info("Loaded \(result.count) themes (curated: \(curatedThemeNames.count), total available: \(availableThemes.count))")
        return result
    }
    
    /// Check if a theme exists
    public static func themeExists(_ themeName: String) -> Bool {
        guard let themesURL = Bundle.module.url(forResource: "themes", withExtension: nil, subdirectory: nil) else {
            return false
        }
        
        let themePath = (themesURL.path as NSString).appendingPathComponent(themeName)
        return FileManager.default.fileExists(atPath: themePath)
    }
}
