import CommonCrypto
import Foundation
import Security
import SQLite3

/// Reads cookies from Chromium-based browsers' SQLite databases (Chrome, Brave, Edge, etc.)
///
/// Chrome stores cookie values in an SQLite DB, and most values are encrypted (`encrypted_value` starts
/// with `v10` on macOS). Decryption uses the "Chrome Safe Storage" password from the macOS Keychain and
/// AES-CBC + PBKDF2.
enum ChromeCookieImporter {
  private static let chromeSafeStorageKeyLock = NSLock()
  private nonisolated(unsafe) static var cachedChromeSafeStorageKey: Data?

  enum ImportError: LocalizedError {
    case cookieDBNotFound(path: String)
    case keychainDenied
    case sqliteFailed(message: String)

    var errorDescription: String? {
      switch self {
      case let .cookieDBNotFound(path): "Chrome Cookies DB not found at \(path)."
      case .keychainDenied: "macOS Keychain denied access to Chrome Safe Storage."
      case let .sqliteFailed(message): "Failed to read Chrome cookies: \(message)"
      }
    }
  }

  /// Extracts Claude sessionKey from Chrome cookies
  /// - Returns: sessionKey value if found, nil otherwise
  /// - Throws: ImportError if cookie database cannot be read
  static func extractClaudeSessionKey() throws -> String? {
    let roots = candidateHomes().map { home in
      home.appendingPathComponent("Library/Application Support/Google/Chrome")
    }

    var candidates: [URL] = []
    for root in roots {
      candidates.append(contentsOf: chromeProfileCookieDBs(root: root).map(\.cookiesDB))
    }

    if candidates.isEmpty {
      let display = roots.map(\.path).joined(separator: " • ")
      throw ImportError.cookieDBNotFound(path: display)
    }

    let chromeKey = try chromeSafeStorageKey()
    for dbURL in candidates {
      guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
      let cookies = try readCookiesFromLockedChromeDB(
        sourceDB: dbURL,
        key: chromeKey,
        matchingDomains: ["claude.ai"]
      )
      if let sessionKey = cookies.first(where: { $0.name == "sessionKey" })?.value {
        return sessionKey
      }
    }

    return nil
  }

  // MARK: - DB copy helper

  private static func readCookiesFromLockedChromeDB(
    sourceDB: URL,
    key: Data,
    matchingDomains: [String]
  ) throws -> [CookieRecord] {
    // Chrome keeps the DB locked; copy the DB (and wal/shm when present) to a temp folder before reading
    let tempDir =
      FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "codmate-chrome-cookies-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let copiedDB = tempDir.appendingPathComponent("Cookies")
    try FileManager.default.copyItem(at: sourceDB, to: copiedDB)

    for suffix in ["-wal", "-shm"] {
      let src = URL(fileURLWithPath: sourceDB.path + suffix)
      if FileManager.default.fileExists(atPath: src.path) {
        let dst = URL(fileURLWithPath: copiedDB.path + suffix)
        try? FileManager.default.copyItem(at: src, to: dst)
      }
    }

    defer { try? FileManager.default.removeItem(at: tempDir) }

    return try readCookies(fromDB: copiedDB.path, key: key, matchingDomains: matchingDomains)
  }

  // MARK: - SQLite read

  private static func readCookies(
    fromDB path: String,
    key: Data,
    matchingDomains: [String]
  ) throws -> [CookieRecord] {
    var db: OpaquePointer?
    if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
      throw ImportError.sqliteFailed(message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_close(db) }

    // Build WHERE clause dynamically for the given domains
    let conditions = matchingDomains.map { "host_key LIKE '%\($0)%'" }.joined(separator: " OR ")
    let sql = """
      SELECT host_key, name, path, expires_utc, is_secure, is_httponly, value, encrypted_value
      FROM cookies
      WHERE \(conditions)
      """

    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
      throw ImportError.sqliteFailed(message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }

    var out: [CookieRecord] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let domain = String(cString: sqlite3_column_text(stmt, 0))
      let name = String(cString: sqlite3_column_text(stmt, 1))
      let path = String(cString: sqlite3_column_text(stmt, 2))
      let expires = sqlite3_column_int64(stmt, 3)
      let isSecure = sqlite3_column_int(stmt, 4) != 0
      let isHTTPOnly = sqlite3_column_int(stmt, 5) != 0

      let plain = readTextColumn(stmt, index: 6)
      let enc = readBlobColumn(stmt, index: 7)

      let value: String
      if let plain, !plain.isEmpty {
        value = plain
      } else if let enc, !enc.isEmpty, let decrypted = decryptChromiumValue(enc, key: key) {
        value = decrypted
      } else {
        continue
      }

      let normalizedDomain =
        domain.hasPrefix(".") ? String(domain.dropFirst()) : domain

      out.append(
        CookieRecord(
          domain: normalizedDomain,
          name: name,
          path: path,
          value: value,
          expires: Date(timeIntervalSince1970: TimeInterval(expires)),
          isSecure: isSecure,
          isHTTPOnly: isHTTPOnly
        ))
    }
    return out
  }

  private static func readTextColumn(_ stmt: OpaquePointer?, index: Int32) -> String? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
    guard let c = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: c)
  }

  private static func readBlobColumn(_ stmt: OpaquePointer?, index: Int32) -> Data? {
    guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
    guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
    let count = Int(sqlite3_column_bytes(stmt, index))
    return Data(bytes: bytes, count: count)
  }

  // MARK: - Keychain + PBKDF2

  private static func chromeSafeStorageKey() throws -> Data {
    chromeSafeStorageKeyLock.lock()
    if let cached = cachedChromeSafeStorageKey {
      chromeSafeStorageKeyLock.unlock()
      return cached
    }
    chromeSafeStorageKeyLock.unlock()

    // Prefer the main Chrome label; fall back to common Chromium forks
    let labels: [(service: String, account: String)] = [
      ("Chrome Safe Storage", "Chrome"),
      ("Chromium Safe Storage", "Chromium"),
      ("Brave Safe Storage", "Brave"),
      ("Microsoft Edge Safe Storage", "Microsoft Edge"),
      ("Vivaldi Safe Storage", "Vivaldi"),
    ]

    var password: String?
    for label in labels {
      if let p = findGenericPassword(service: label.service, account: label.account) {
        password = p
        break
      }
    }
    guard let password else { throw ImportError.keychainDenied }

    // Chromium macOS key derivation: PBKDF2-HMAC-SHA1 with salt "saltysalt", 1003 iterations, key length 16
    let salt = Data("saltysalt".utf8)
    var key = Data(count: kCCKeySizeAES128)
    let keyLength = key.count
    let result = key.withUnsafeMutableBytes { keyBytes in
      password.utf8CString.withUnsafeBytes { passBytes in
        salt.withUnsafeBytes { saltBytes in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passBytes.bindMemory(to: Int8.self).baseAddress,
            passBytes.count - 1,
            saltBytes.bindMemory(to: UInt8.self).baseAddress,
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003,
            keyBytes.bindMemory(to: UInt8.self).baseAddress,
            keyLength
          )
        }
      }
    }
    guard result == kCCSuccess else {
      throw ImportError.keychainDenied
    }

    chromeSafeStorageKeyLock.lock()
    cachedChromeSafeStorageKey = key
    chromeSafeStorageKeyLock.unlock()
    return key
  }

  // Exposed for tests
  static func decryptChromiumValue(_ encryptedValue: Data, key: Data) -> String? {
    // macOS Chrome cookies typically have `v10` prefix and AES-CBC payload
    guard encryptedValue.count > 3 else { return nil }
    let prefix = encryptedValue.prefix(3)
    let prefixString = String(data: prefix, encoding: .utf8)
    let payload = encryptedValue.dropFirst(3)

    guard prefixString == "v10" else {
      return nil
    }

    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)  // 16 spaces
    var out = Data(count: payload.count + kCCBlockSizeAES128)
    var outLength: size_t = 0
    let outCapacity = out.count

    let status = out.withUnsafeMutableBytes { outBytes in
      payload.withUnsafeBytes { inBytes in
        key.withUnsafeBytes { keyBytes in
          iv.withUnsafeBytes { ivBytes in
            CCCrypt(
              CCOperation(kCCDecrypt),
              CCAlgorithm(kCCAlgorithmAES),
              CCOptions(kCCOptionPKCS7Padding),
              keyBytes.baseAddress,
              key.count,
              ivBytes.baseAddress,
              inBytes.baseAddress,
              payload.count,
              outBytes.baseAddress,
              outCapacity,
              &outLength
            )
          }
        }
      }
    }
    guard status == kCCSuccess else { return nil }
    out.count = outLength

    // Chromium's macOS cookie encryption prefixes 32 bytes of non-UTF8 data before the actual cookie value
    let candidate = out.count > 32 ? out.dropFirst(32) : out[...]
    if let decoded = String(data: Data(candidate), encoding: .utf8) {
      return cleanValue(decoded)
    }
    if let decoded = String(data: out, encoding: .utf8) {
      return cleanValue(decoded)
    }
    return nil
  }

  private static func cleanValue(_ value: String) -> String {
    // Strip leading control chars
    var i = value.startIndex
    while i < value.endIndex, value[i].unicodeScalars.allSatisfy({ $0.value < 0x20 }) {
      i = value.index(after: i)
    }
    return String(value[i...])
  }

  private static func findGenericPassword(service: String, account: String) -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecReturnData: true,
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return nil }
    guard let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  // MARK: - File paths

  private struct ChromeProfileCandidate {
    let label: String
    let cookiesDB: URL
  }

  private static func chromeProfileCookieDBs(root: URL) -> [ChromeProfileCandidate] {
    var out: [ChromeProfileCandidate] = []

    // Default profile
    let defaultDB = root.appendingPathComponent("Default/Cookies")
    if FileManager.default.fileExists(atPath: defaultDB.path) {
      out.append(ChromeProfileCandidate(label: "Default", cookiesDB: defaultDB))
    }

    // Numbered profiles: Profile 1, Profile 2, etc.
    for i in 1...10 {
      let profileDB = root.appendingPathComponent("Profile \(i)/Cookies")
      if FileManager.default.fileExists(atPath: profileDB.path) {
        out.append(ChromeProfileCandidate(label: "Profile \(i)", cookiesDB: profileDB))
      }
    }

    return out
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
