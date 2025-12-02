import Foundation
import Security

struct GeminiUsageAPIClient {
  enum ClientError: Error, LocalizedError {
    case credentialNotFound
    case keychainAccess(OSStatus)
    case malformedCredential
    case missingAccessToken
    case credentialExpired(Date)
    case projectNotFound
    case requestFailed(Int)
    case emptyResponse
    case decodingFailed

    var errorDescription: String? {
      switch self {
      case .credentialNotFound:
        return "Gemini credential not found."
      case .keychainAccess(let status):
        return SecCopyErrorMessageString(status, nil) as String?
      case .malformedCredential:
        return "Gemini credential is invalid."
      case .missingAccessToken:
        return "Gemini credential is missing an access token."
      case .credentialExpired(let date):
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Gemini credential expired on \(formatter.string(from: date))."
      case .projectNotFound:
        return "Gemini project ID not found. For personal Google accounts, try running gemini CLI to complete onboarding. For workspace accounts, set GOOGLE_CLOUD_PROJECT."
      case .requestFailed(let code):
        return "Gemini usage API returned status \(code)."
      case .emptyResponse:
        return "Gemini usage API returned no data."
      case .decodingFailed:
        return "Failed to decode Gemini usage response."
      }
    }
  }

  private struct CredentialEnvelope: Decodable {
    struct Token: Decodable {
      let accessToken: String
      let refreshToken: String?
      let expiresAt: TimeInterval?
      let tokenType: String?
    }

    let serverName: String?
    let token: Token
    let updatedAt: TimeInterval?
  }

  private struct LoadCodeAssistResponse: Decodable {
    struct Tier: Decodable {
      let id: String?
      let name: String?
      let isDefault: Bool?
    }

    struct Project: Decodable {
      let id: String?
      let name: String?
    }

    let currentTier: Tier?
    let allowedTiers: [Tier]?
    let cloudaicompanionProject: String?
    let cloudaicompanionProjectObject: Project?

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      currentTier = try? container.decodeIfPresent(Tier.self, forKey: .currentTier)
      allowedTiers = try? container.decodeIfPresent([Tier].self, forKey: .allowedTiers)

      // Handle cloudaicompanionProject as string or object
      if let rawString = try? container.decodeIfPresent(String.self, forKey: .cloudaicompanionProject) {
        self.cloudaicompanionProject = rawString
        self.cloudaicompanionProjectObject = nil
      } else if let obj = try? container.decodeIfPresent(Project.self, forKey: .cloudaicompanionProject) {
        self.cloudaicompanionProject = obj.id ?? obj.name
        self.cloudaicompanionProjectObject = obj
      } else {
        self.cloudaicompanionProject = nil
        self.cloudaicompanionProjectObject = nil
      }
    }

    private enum CodingKeys: String, CodingKey {
      case currentTier
      case allowedTiers
      case cloudaicompanionProject
    }
  }

  private struct OnboardUserRequest: Encodable {
    let tierId: String
    let cloudaicompanionProject: String?
    let metadata: [String: String]
  }

  private struct OnboardUserResponse: Decodable {
    struct Project: Decodable {
      let id: String?
      let name: String?
    }

    struct ResponseData: Decodable {
      let cloudaicompanionProject: Project?
    }

    let done: Bool?
    let response: ResponseData?
  }

  private struct QuotaResponse: Decodable {
    struct Bucket: Decodable {
      let remainingAmount: String?
      let remainingFraction: Double?
      let resetTime: String?
      let tokenType: String?
      let modelId: String?
    }

    let buckets: [Bucket]?
  }

  private struct OAuthFile: Decodable {
    let access_token: String?
    let expiry_date: TimeInterval?
  }

  func fetchUsageStatus(now: Date = Date()) async throws -> GeminiUsageStatus {
    let credential = try fetchCredential()
    if let expires = credential.token.expiresAt {
      let expiry = Date(timeIntervalSince1970: expires / 1000)
      if expiry.addingTimeInterval(-300) < now {
        throw ClientError.credentialExpired(expiry)
      }
    }

    guard !credential.token.accessToken.isEmpty else { throw ClientError.missingAccessToken }
    let token = credential.token.accessToken

    guard let projectId = try await resolveProjectId(token: token) else {
      throw ClientError.projectNotFound
    }
    let buckets = try await retrieveQuota(token: token, projectId: projectId)

    let status = GeminiUsageStatus(
      updatedAt: now,
      projectId: projectId,
      buckets: buckets
    )
    return status
  }

  // MARK: - Credential loading

  private func fetchCredential() throws -> CredentialEnvelope {
    if let keychain = try fetchCredentialFromKeychain() {
      return keychain
    }
    if let file = fetchCredentialFromPlaintextFile() {
      return file
    }
    throw ClientError.credentialNotFound
  }

  private func fetchCredentialFromKeychain() throws -> CredentialEnvelope? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "gemini-cli-oauth",
      kSecAttrAccount as String: "main-account",
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)

    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw ClientError.keychainAccess(status) }
    guard let data = item as? Data else { throw ClientError.malformedCredential }

    do {
      let envelope = try JSONDecoder().decode(CredentialEnvelope.self, from: data)
      return envelope
    } catch {
      throw ClientError.malformedCredential
    }
  }

  private func fetchCredentialFromPlaintextFile() -> CredentialEnvelope? {
    let fm = FileManager.default
    let home = SessionPreferencesStore.getRealUserHomeURL()
    let paths = [
      home.appendingPathComponent(".gemini/mcp-oauth-tokens-v2.json"),
      home.appendingPathComponent(".gemini/mcp-oauth-tokens.json"),
      home.appendingPathComponent(".gemini/oauth_creds.json")
    ]

    for url in paths {
      guard fm.fileExists(atPath: url.path) else { continue }
      if let data = try? Data(contentsOf: url) {
        // Try OAuthCredentials shape first
        if let envelope = try? JSONDecoder().decode(CredentialEnvelope.self, from: data) {
          return envelope
        }
        // Try legacy google creds
        if let legacy = try? JSONDecoder().decode(OAuthFile.self, from: data),
          let token = legacy.access_token
        {
          let expires = legacy.expiry_date
          let tokenObj = CredentialEnvelope.Token(
            accessToken: token,
            refreshToken: nil,
            expiresAt: expires,
            tokenType: "Bearer"
          )
          return CredentialEnvelope(serverName: "legacy", token: tokenObj, updatedAt: nil)
        }
      }
    }
    return nil
  }

  // MARK: - Network

  private func resolveProjectId(token: String) async throws -> String? {
    let envProject = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"]
      ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"]

    // Step 1: Call loadCodeAssist to check user status
    guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")
    else {
      return envProject
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 10

    var metadata: [String: String] = [
      "ideType": "IDE_UNSPECIFIED",
      "platform": "PLATFORM_UNSPECIFIED",
      "pluginType": "GEMINI"
    ]
    if let env = envProject, !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      metadata["duetProject"] = env
    }

    var body: [String: Any] = ["metadata": metadata]
    if let env = envProject, !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      body["cloudaicompanionProject"] = env
    }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { return envProject }
    guard (200..<300).contains(http.statusCode) else {
      throw ClientError.requestFailed(http.statusCode)
    }

    // Debug: Log raw response
    if let rawJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      NSLog("[GeminiUsage] loadCodeAssist response: \(rawJSON)")
    }

    guard let loadResult = try? JSONDecoder().decode(LoadCodeAssistResponse.self, from: data) else {
      NSLog("[GeminiUsage] Failed to decode loadCodeAssist response")
      return envProject
    }

    // Step 2: Check if user is already onboarded (has currentTier)
    if let currentTier = loadResult.currentTier {
      NSLog("[GeminiUsage] User already onboarded with tier: \(currentTier.id ?? "unknown")")
      // User is already onboarded
      if let project = loadResult.cloudaicompanionProject, !project.isEmpty {
        NSLog("[GeminiUsage] Found project from loadCodeAssist: \(project)")
        return project
      }
      // Has tier but no project - use env var or throw error
      if let env = envProject, !env.isEmpty {
        NSLog("[GeminiUsage] Using project from environment: \(env)")
        return env
      }
      // For some tiers (like free-tier), project might be assigned later
      // Continue to onboard flow
      NSLog("[GeminiUsage] No project found, will attempt onboarding")
    }

    // Step 3: New user needs to be onboarded
    guard let allowedTiers = loadResult.allowedTiers,
          !allowedTiers.isEmpty else {
      NSLog("[GeminiUsage] No allowed tiers found in response")
      // No tiers available - fallback to env or throw
      if let env = envProject, !env.isEmpty {
        return env
      }
      throw ClientError.projectNotFound
    }

    // Find default tier
    guard let defaultTier = allowedTiers.first(where: { $0.isDefault == true }) ?? allowedTiers.first,
          let tierId = defaultTier.id else {
      NSLog("[GeminiUsage] No default tier found")
      throw ClientError.projectNotFound
    }

    NSLog("[GeminiUsage] Starting onboarding for tier: \(tierId)")

    // Step 4: Call onboardUser
    let isFree = tierId == "free-tier"
    let projectId = try await onboardUser(
      token: token,
      tierId: tierId,
      cloudaicompanionProject: isFree ? nil : envProject
    )

    if let project = projectId, !project.isEmpty {
      return project
    }

    // Fallback to env var
    if let env = envProject, !env.isEmpty {
      return env
    }

    throw ClientError.projectNotFound
  }

  private func onboardUser(
    token: String,
    tierId: String,
    cloudaicompanionProject: String?
  ) async throws -> String? {
    guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:onboardUser")
    else {
      return nil
    }

    var metadata: [String: String] = [
      "ideType": "IDE_UNSPECIFIED",
      "platform": "PLATFORM_UNSPECIFIED",
      "pluginType": "GEMINI"
    ]
    if let project = cloudaicompanionProject, !project.isEmpty {
      metadata["duetProject"] = project
    }

    let requestBody = OnboardUserRequest(
      tierId: tierId,
      cloudaicompanionProject: cloudaicompanionProject,
      metadata: metadata
    )

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 30

    guard let bodyData = try? JSONEncoder().encode(requestBody) else {
      throw ClientError.requestFailed(-1)
    }
    request.httpBody = bodyData

    // Poll until the long-running operation is complete (max 12 attempts = 60 seconds)
    let maxAttempts = 12
    var attempts = 0

    while attempts < maxAttempts {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw ClientError.requestFailed(-1)
      }
      guard (200..<300).contains(http.statusCode) else {
        throw ClientError.requestFailed(http.statusCode)
      }

      guard let result = try? JSONDecoder().decode(OnboardUserResponse.self, from: data) else {
        throw ClientError.decodingFailed
      }

      // Check if operation is complete
      if result.done == true {
        let projectId = result.response?.cloudaicompanionProject?.id
          ?? result.response?.cloudaicompanionProject?.name
        NSLog("[GeminiUsage] Onboarding completed, project ID: \(projectId ?? "nil")")
        return projectId
      }

      // Not done yet, wait and retry
      attempts += 1
      NSLog("[GeminiUsage] Onboarding not complete, attempt \(attempts)/\(maxAttempts), retrying in 5s...")
      if attempts < maxAttempts {
        try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
      }
    }

    // Polling timeout
    NSLog("[GeminiUsage] Onboarding polling timeout after \(maxAttempts) attempts")
    throw ClientError.requestFailed(-2)
  }

  private func retrieveQuota(token: String, projectId: String?) async throws -> [GeminiUsageStatus.Bucket] {
    guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
      return []
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 10

    var body: [String: Any] = [:]
    if let projectId, !projectId.isEmpty {
      body["project"] = projectId
    }
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw ClientError.requestFailed(-1) }
    guard (200..<300).contains(http.statusCode) else { throw ClientError.requestFailed(http.statusCode) }

    // Debug: Log raw quota response
    if let rawJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      NSLog("[GeminiUsage] retrieveUserQuota response: \(rawJSON)")
    }

    guard let payload = try? JSONDecoder().decode(QuotaResponse.self, from: data) else {
      throw ClientError.decodingFailed
    }

    let buckets: [GeminiUsageStatus.Bucket] = (payload.buckets ?? []).map { bucket in
      let reset: Date? = bucket.resetTime.flatMap { resetTimeString in
        // Try parsing with fractional seconds first
        let formatterWithFractional = ISO8601DateFormatter()
        formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatterWithFractional.date(from: resetTimeString) {
          NSLog("[GeminiUsage] Parsed resetTime with fractional seconds: \(resetTimeString) -> \(date)")
          return date
        }

        // Fallback: try without fractional seconds
        let formatterWithoutFractional = ISO8601DateFormatter()
        formatterWithoutFractional.formatOptions = [.withInternetDateTime]
        if let date = formatterWithoutFractional.date(from: resetTimeString) {
          NSLog("[GeminiUsage] Parsed resetTime without fractional seconds: \(resetTimeString) -> \(date)")
          return date
        }

        NSLog("[GeminiUsage] Failed to parse resetTime: \(resetTimeString)")
        return nil
      }

      return GeminiUsageStatus.Bucket(
        modelId: bucket.modelId,
        tokenType: bucket.tokenType,
        remainingFraction: bucket.remainingFraction,
        remainingAmount: bucket.remainingAmount,
        resetTime: reset
      )
    }

    NSLog("[GeminiUsage] Retrieved \(buckets.count) buckets, \(buckets.filter { $0.resetTime != nil }.count) have resetTime")
    return buckets
  }

  private func userAgent() -> String {
    let version = Bundle.main.shortVersionString
    let platform = ProcessInfo.processInfo.operatingSystemVersionString
    return "CodMate/\(version) (\(platform))"
  }
}
