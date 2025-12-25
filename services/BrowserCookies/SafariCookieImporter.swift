import Foundation

/// Reads cookies from Safari's `Cookies.binarycookies` file (macOS).
///
/// This is a best-effort parser for the documented `binarycookies` format:
/// file header is big-endian; cookie pages and records are little-endian.
enum SafariCookieImporter {
  enum ImportError: LocalizedError {
    case cookieFileNotFound
    case cookieFileNotReadable(path: String)
    case invalidFile

    var errorDescription: String? {
      switch self {
      case .cookieFileNotFound:
        "Safari cookie file not found."
      case let .cookieFileNotReadable(path):
        "Safari cookie file exists but is not readable (\(path)). CodMate needs Full Disk Access to read Safari cookies."
      case .invalidFile:
        "Safari cookie file is invalid."
      }
    }
  }

  /// Extracts Claude sessionKey from Safari cookies
  /// - Returns: sessionKey value if found, nil otherwise
  /// - Throws: ImportError if cookie file cannot be read
  static func extractClaudeSessionKey() throws -> String? {
    let cookies = try loadCookies(matchingDomains: ["claude.ai"])
    return cookies.first(where: { $0.name == "sessionKey" })?.value
  }

  /// Loads cookies from Safari matching the given domains
  static func loadCookies(
    matchingDomains domains: [String],
    logger: ((String) -> Void)? = nil
  ) throws -> [CookieRecord] {
    let candidates = candidateCookieFiles()
    var lastNoPermission: String?
    var lastReadError: String?

    for url in candidates {
      do {
        let size =
          (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
          .intValue
        logger?("[SafariCookie] Trying \(url.path) (\(size ?? -1) bytes)")
        let data = try Data(contentsOf: url)
        let records = try parseBinaryCookies(data: data)
        return records.filter { record in
          let d = record.domain.lowercased()
          return domains.contains { d.contains($0.lowercased()) }
        }
      } catch let error as CocoaError where error.code == .fileReadNoPermission {
        lastNoPermission = url.path
        logger?("[SafariCookie] Permission denied for \(url.path)")
        continue
      } catch {
        lastReadError = "\(url.path): \(error.localizedDescription)"
        logger?("[SafariCookie] Failed to read \(url.path): \(error.localizedDescription)")
        continue
      }
    }

    if let lastNoPermission {
      throw ImportError.cookieFileNotReadable(path: lastNoPermission)
    }
    if let lastReadError {
      logger?("[SafariCookie] Last error: \(lastReadError)")
    }
    throw ImportError.cookieFileNotFound
  }

  // MARK: - BinaryCookies parsing

  private static func parseBinaryCookies(data: Data) throws -> [CookieRecord] {
    let reader = DataReader(data)
    guard reader.readASCII(count: 4) == "cook" else { throw ImportError.invalidFile }
    let pageCount = Int(reader.readUInt32BE())
    guard pageCount >= 0 else { throw ImportError.invalidFile }

    var pageSizes: [Int] = []
    pageSizes.reserveCapacity(pageCount)
    for _ in 0..<pageCount {
      pageSizes.append(Int(reader.readUInt32BE()))
    }

    var records: [CookieRecord] = []
    var offset = reader.offset
    for size in pageSizes {
      guard offset + size <= data.count else { throw ImportError.invalidFile }
      let pageData = data.subdata(in: offset..<(offset + size))
      records.append(contentsOf: parsePage(data: pageData))
      offset += size
    }
    return records
  }

  private static func parsePage(data: Data) -> [CookieRecord] {
    let r = DataReader(data)
    _ = r.readUInt32LE()  // page header
    let cookieCount = Int(r.readUInt32LE())
    if cookieCount <= 0 { return [] }

    var cookieOffsets: [Int] = []
    cookieOffsets.reserveCapacity(cookieCount)
    for _ in 0..<cookieCount {
      cookieOffsets.append(Int(r.readUInt32LE()))
    }

    return cookieOffsets.compactMap { offset in
      guard offset >= 0, offset + 56 <= data.count else { return nil }
      return parseCookieRecord(data: data, offset: offset)
    }
  }

  private static func parseCookieRecord(data: Data, offset: Int) -> CookieRecord? {
    let r = DataReader(data, offset: offset)
    let size = Int(r.readUInt32LE())
    guard size > 0, offset + size <= data.count else { return nil }

    _ = r.readUInt32LE()  // unknown
    let flags = r.readUInt32LE()
    _ = r.readUInt32LE()  // unknown

    let urlOffset = Int(r.readUInt32LE())
    let nameOffset = Int(r.readUInt32LE())
    let pathOffset = Int(r.readUInt32LE())
    let valueOffset = Int(r.readUInt32LE())
    _ = r.readUInt32LE()  // commentOffset
    _ = r.readUInt32LE()  // commentURL

    let expiresRef = r.readDoubleLE()
    _ = r.readDoubleLE()  // creation

    let domain = readCString(data: data, base: offset, offset: urlOffset) ?? ""
    let name = readCString(data: data, base: offset, offset: nameOffset) ?? ""
    let path = readCString(data: data, base: offset, offset: pathOffset) ?? "/"
    let value = readCString(data: data, base: offset, offset: valueOffset) ?? ""

    if domain.isEmpty || name.isEmpty { return nil }

    let isSecure = (flags & 0x1) != 0
    let isHTTPOnly = (flags & 0x4) != 0
    let expires =
      expiresRef > 0 ? Date(timeIntervalSinceReferenceDate: expiresRef) : nil

    return CookieRecord(
      domain: normalizeDomain(domain),
      name: name,
      path: path,
      value: value,
      expires: expires,
      isSecure: isSecure,
      isHTTPOnly: isHTTPOnly
    )
  }

  private static func readCString(data: Data, base: Int, offset: Int) -> String? {
    let start = base + offset
    guard start >= 0, start < data.count else { return nil }
    let end = data[start...].firstIndex(of: 0) ?? data.count
    guard end > start else { return nil }
    return String(data: data.subdata(in: start..<end), encoding: .utf8)
  }

  private static func normalizeDomain(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix(".") { return String(trimmed.dropFirst()) }
    return trimmed
  }

  // MARK: - File paths

  private static func candidateCookieFiles() -> [URL] {
    let homes = candidateHomes()
    var urls: [URL] = []
    urls.reserveCapacity(homes.count * 2)
    for home in homes {
      urls.append(home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"))
      urls.append(
        home.appendingPathComponent(
          "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"))
    }
    // De-dup by path while keeping ordering (homeDirectoryForCurrentUser first)
    var seen = Set<String>()
    return urls.filter { url in
      let path = url.path
      guard !seen.contains(path) else { return false }
      seen.insert(path)
      return true
    }
  }

  private static func candidateHomes() -> [URL] {
    var homes: [URL] = []
    homes.append(FileManager.default.homeDirectoryForCurrentUser)
    if let userHome = NSHomeDirectoryForUser(NSUserName()) {
      homes.append(URL(fileURLWithPath: userHome))
    }
    if let envHome = ProcessInfo.processInfo.environment["HOME"], !envHome.isEmpty {
      homes.append(URL(fileURLWithPath: envHome))
    }
    // De-dup by path while keeping ordering
    var seen = Set<String>()
    return homes.filter { home in
      let path = home.path
      guard !seen.contains(path) else { return false }
      seen.insert(path)
      return true
    }
  }
}
