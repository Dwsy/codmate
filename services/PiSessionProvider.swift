import OSLog
import Foundation
#if canImport(Darwin)
import Darwin
#endif

actor PiSessionProvider {
    private let logger = Logger(subsystem: "io.umate.codmate", category: "PiSessionProvider")
    enum SessionProviderCacheError: Error {
        case cacheUnavailable
    }

    private let parser = PiSessionParser()
    private let fileManager: FileManager
    private let root: URL?
    private let cacheStore: SessionIndexSQLiteStore?
    private var canonicalURLById: [String: URL] = [:]
    private var summaryCache: [URL: CacheEntry] = [:]

    private struct CacheEntry {
        let modificationDate: Date?
        let fileSize: UInt64?
        let summary: SessionSummary
    }

    init(fileManager: FileManager = .default, cacheStore: SessionIndexSQLiteStore? = nil) {
        self.fileManager = fileManager
        self.cacheStore = cacheStore
        let home = Self.getRealUserHomeURL()
        let sessions = home.appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let sessionsPath = sessions.path
        let exists = fileManager.fileExists(atPath: sessionsPath)
        logger.info("PiSessionProvider init: path=\(sessionsPath, privacy: .public) exists=\(exists, privacy: .public)")
        root = exists ? sessions : nil
    }

    func load(context: SessionProviderContext) async throws -> SessionProviderResult {
        logger.info("PiSessionProvider load called")

        guard cacheStore != nil else {
            logger.warning("PiSessionProvider load failed: cacheStore is nil")
            throw SessionProviderCacheError.cacheUnavailable
        }

        guard let root else {
            logger.warning("PiSessionProvider load failed: root is nil")
            return SessionProviderResult(summaries: [], coverage: nil, cacheHit: false)
        }

        logger.info("PiSessionProvider: root=\(root.path, privacy: .public)")

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else {
            logger.warning("PiSessionProvider load failed: cannot create enumerator")
            return SessionProviderResult(summaries: [], coverage: nil, cacheHit: false)
        }

        var bestById: [String: SessionSummary] = [:]
        let urls = enumerator.compactMap { $0 as? URL }
        logger.info("PiSessionProvider: found \(urls.count, privacy: .public) files")

        for url in urls {
            guard url.pathExtension.lowercased() == "jsonl" else { continue }
            if shouldIgnorePath(url.path, ignoredPaths: context.ignoredPaths) { continue }

            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }

            let fileSize = resolveFileSize(for: url, resourceValues: values)
            let mtime = values?.contentModificationDate

            do {
                let summary = try await cachedSummary(for: url, modificationDate: mtime, fileSize: fileSize)
                    ?? parser.parse(at: url, fileSize: fileSize)?.summary
                guard let summary else { continue }

                if shouldIgnoreSummary(summary, ignoredPaths: context.ignoredPaths) { continue }
                guard matches(scope: context.scope, summary: summary) else { continue }

                cache(summary: summary, for: url, modificationDate: mtime, fileSize: fileSize)
                persist(summary: summary, modificationDate: mtime, fileSize: fileSize)

                if let existing = bestById[summary.id] {
                    bestById[summary.id] = prefer(lhs: existing, rhs: summary)
                } else {
                    bestById[summary.id] = summary
                }
            } catch {
                logger.error("PiSessionProvider: parse failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // Update canonical map for later fallbacks
        for (_, s) in bestById { canonicalURLById[s.id] = s.fileURL }

        logger.info("PiSessionProvider: returning \(bestById.count, privacy: .public) summaries")

        return SessionProviderResult(
            summaries: Array(bestById.values),
            coverage: nil,
            cacheHit: false
        )
    }

    // MARK: - Private Helpers

    private static func getRealUserHomeURL() -> URL {
        #if canImport(Darwin)
        if let homeDir = getpwuid(getuid())?.pointee.pw_dir {
            let path = String(cString: homeDir)
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func matches(scope: SessionLoadScope, summary: SessionSummary) -> Bool {
        let calendar = Calendar.current
        let referenceDates = [
            summary.startedAt,
            summary.lastUpdatedAt ?? summary.startedAt
        ]
        switch scope {
        case .all:
            return true
        case .today:
            return referenceDates.contains(where: { calendar.isDateInToday($0) })
        case .day(let day):
            return referenceDates.contains(where: { calendar.isDate($0, inSameDayAs: day) })
        case .month(let date):
            return referenceDates.contains {
                calendar.isDate($0, equalTo: date, toGranularity: .month)
            }
        }
    }

    private func prefer(lhs: SessionSummary, rhs: SessionSummary) -> SessionSummary {
        let lhsSize = lhs.fileSizeBytes ?? 0
        let rhsSize = rhs.fileSizeBytes ?? 0
        if rhsSize > lhsSize { return rhs }
        if rhsSize < lhsSize { return lhs }
        let lhsTime = lhs.lastUpdatedAt ?? lhs.startedAt
        let rhsTime = rhs.lastUpdatedAt ?? rhs.startedAt
        return rhsTime > lhsTime ? rhs : lhs
    }

    private func cache(summary: SessionSummary, for url: URL, modificationDate: Date?, fileSize: UInt64?) {
        summaryCache[url] = CacheEntry(
            modificationDate: modificationDate,
            fileSize: fileSize,
            summary: summary
        )
        canonicalURLById[summary.id] = url
    }

    private func cachedSummary(for url: URL, modificationDate: Date?, fileSize: UInt64?) async throws -> SessionSummary? {
        guard let entry = summaryCache[url] else { return nil }
        guard entry.modificationDate == modificationDate, entry.fileSize == fileSize else { return nil }
        return entry.summary
    }

    private func persist(summary: SessionSummary, modificationDate: Date?, fileSize: UInt64?) {
        guard let store = cacheStore else { return }
        Task.detached { [store] in
            try? await store.upsert(
                summary: summary,
                project: nil,
                fileModificationTime: modificationDate,
                fileSize: fileSize,
                tokenBreakdown: summary.tokenBreakdown,
                parseError: nil
            )
        }
    }

    private func resolveFileSize(for url: URL, resourceValues: URLResourceValues?) -> UInt64 {
        if let size = resourceValues?.fileSize { return UInt64(size) }
        do {
            let attrs = try fileManager.attributesOfItem(atPath: url.path)
            return attrs[.size] as? UInt64 ?? 0
        } catch {
            return 0
        }
    }

    private func shouldIgnorePath(_ path: String, ignoredPaths: [String]) -> Bool {
        ignoredPaths.contains { path.contains($0) }
    }

    private func shouldIgnoreSummary(_ summary: SessionSummary, ignoredPaths: [String]) -> Bool {
        ignoredPaths.contains { summary.cwd.contains($0) }
    }
}

// MARK: - SessionProvider

extension PiSessionProvider: SessionProvider {
    nonisolated var kind: SessionSource.Kind { .pi }
    nonisolated var identifier: String { "pi-local" }
    nonisolated var label: String { "Pi Local" }

    func timeline(for summary: SessionSummary) -> [ConversationTurn]? {
        guard summary.source.baseKind == .pi else { return nil }
        let url = canonicalURLById[summary.id] ?? summary.fileURL
        guard let parsed = parser.parse(at: url) else { return nil }
        let loader = SessionTimelineLoader()
        return loader.turns(from: parsed.rows)
    }
}