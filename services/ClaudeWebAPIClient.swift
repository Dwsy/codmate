import Foundation

/// Fetches Claude usage data directly from the claude.ai API using browser session cookies.
///
/// This approach automatically extracts the session key from Safari/Chrome cookies instead of
/// requiring OAuth token management, providing a more reliable fallback when OAuth tokens expire.
///
/// API endpoints used:
/// - `GET https://claude.ai/api/organizations` → get org UUID
/// - `GET https://claude.ai/api/organizations/{org_id}/usage` → usage percentages + reset times
enum ClaudeWebAPIClient {
  private static let baseURL = "https://claude.ai/api"

  enum FetchError: LocalizedError {
    case noSessionKeyFound
    case invalidSessionKey
    case networkError(Error)
    case invalidResponse
    case unauthorized
    case serverError(statusCode: Int)
    case noOrganization

    var errorDescription: String? {
      switch self {
      case .noSessionKeyFound:
        "No Claude session key found in browser cookies."
      case .invalidSessionKey:
        "Invalid Claude session key format."
      case let .networkError(error):
        "Network error: \(error.localizedDescription)"
      case .invalidResponse:
        "Invalid response from Claude API."
      case .unauthorized:
        "Unauthorized. Your Claude session may have expired."
      case let .serverError(code):
        "Claude API error: HTTP \(code)"
      case .noOrganization:
        "No Claude organization found for this account."
      }
    }
  }

  struct OrganizationInfo {
    let id: String
    let name: String?
  }

  struct WebUsageData {
    let sessionPercentUsed: Double
    let sessionResetsAt: Date?
    let weeklyPercentUsed: Double?
    let weeklyResetsAt: Date?
    let planType: String?  // Subscription type (Pro, Max, Team, etc.)
  }

  private struct AccountResponse: Decodable {
    let emailAddress: String?
    let memberships: [Membership]?

    enum CodingKeys: String, CodingKey {
      case emailAddress = "email_address"
      case memberships
    }

    struct Membership: Decodable {
      let organization: Organization

      struct Organization: Decodable {
        let uuid: String?
        let rateLimitTier: String?
        let billingType: String?

        enum CodingKeys: String, CodingKey {
          case uuid
          case rateLimitTier = "rate_limit_tier"
          case billingType = "billing_type"
        }
      }
    }
  }

  // MARK: - Public API

  /// Fetches Claude usage status using browser cookies
  /// - Parameter now: Current date for status construction
  /// - Returns: ClaudeUsageStatus compatible with existing system
  /// - Throws: FetchError if session key cannot be found or API call fails
  static func fetchUsageViaWebAPI(now: Date = Date()) async throws -> ClaudeUsageStatus {
    NSLog("[ClaudeWebAPI] Attempting to fetch usage via Web API")

    // Extract session key from browser cookies
    let sessionKey = try extractSessionKey()
    NSLog("[ClaudeWebAPI] Found sessionKey: \(sessionKey.prefix(20))...")

    // Fetch organization info
    let organization = try await fetchOrganizationInfo(sessionKey: sessionKey)
    NSLog("[ClaudeWebAPI] Organization ID: \(organization.id)")

    // Fetch usage data
    var usage = try await fetchUsageData(orgId: organization.id, sessionKey: sessionKey)
    NSLog("[ClaudeWebAPI] Usage fetched successfully")

    // Fetch account info for plan type (best effort)
    if let planType = await fetchAccountPlanType(
      sessionKey: sessionKey, orgId: organization.id)
    {
      usage = WebUsageData(
        sessionPercentUsed: usage.sessionPercentUsed,
        sessionResetsAt: usage.sessionResetsAt,
        weeklyPercentUsed: usage.weeklyPercentUsed,
        weeklyResetsAt: usage.weeklyResetsAt,
        planType: planType
      )
      NSLog("[ClaudeWebAPI] ✅ Detected plan type: \(planType)")
    } else {
      NSLog("[ClaudeWebAPI] ⚠️ Could not detect plan type")
    }

    // Convert to ClaudeUsageStatus
    return convertToUsageStatus(usage, now: now)
  }

  // MARK: - Session Key Extraction

  private static func extractSessionKey() throws -> String {
    // Try Safari first (no Keychain prompt required)
    do {
      if let sessionKey = try SafariCookieImporter.extractClaudeSessionKey() {
        guard validateSessionKey(sessionKey) else {
          throw FetchError.invalidSessionKey
        }
        NSLog("[ClaudeWebAPI] Found sessionKey in Safari cookies")
        return sessionKey
      }
    } catch {
      NSLog("[ClaudeWebAPI] Safari cookie load failed: \(error.localizedDescription)")
    }

    // Chrome cookie import disabled to avoid Keychain prompts
    // Users can manually configure session key in Settings if needed

    throw FetchError.noSessionKeyFound
  }

  private static func validateSessionKey(_ key: String) -> Bool {
    // Claude session keys start with "sk-ant-"
    return key.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sk-ant-")
  }

  // MARK: - API Calls

  private static func fetchOrganizationInfo(sessionKey: String) async throws
    -> OrganizationInfo
  {
    let url = URL(string: "\(baseURL)/organizations")!
    var request = URLRequest(url: url)
    request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpMethod = "GET"
    request.timeoutInterval = 15

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw FetchError.invalidResponse
    }

    NSLog("[ClaudeWebAPI] Organizations API status: \(httpResponse.statusCode)")

    switch httpResponse.statusCode {
    case 200:
      return try parseOrganizationResponse(data)
    case 401, 403:
      throw FetchError.unauthorized
    default:
      throw FetchError.serverError(statusCode: httpResponse.statusCode)
    }
  }

  private static func fetchUsageData(orgId: String, sessionKey: String) async throws
    -> WebUsageData
  {
    let url = URL(string: "\(baseURL)/organizations/\(orgId)/usage")!
    var request = URLRequest(url: url)
    request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpMethod = "GET"
    request.timeoutInterval = 15

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw FetchError.invalidResponse
    }

    NSLog("[ClaudeWebAPI] Usage API status: \(httpResponse.statusCode)")

    switch httpResponse.statusCode {
    case 200:
      return try parseUsageResponse(data)
    case 401, 403:
      throw FetchError.unauthorized
    default:
      throw FetchError.serverError(statusCode: httpResponse.statusCode)
    }
  }

  // MARK: - Response Parsing

  private static func parseOrganizationResponse(_ data: Data) throws -> OrganizationInfo {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
      let first = json.first,
      let id = first["uuid"] as? String
    else {
      throw FetchError.noOrganization
    }

    let name = first["name"] as? String
    return OrganizationInfo(id: id, name: name)
  }

  private static func parseUsageResponse(_ data: Data) throws -> WebUsageData {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw FetchError.invalidResponse
    }

    // Parse five_hour (session) usage
    var sessionPercent: Double?
    var sessionResets: Date?
    if let fiveHour = json["five_hour"] as? [String: Any] {
      if let utilization = fiveHour["utilization"] as? Int {
        sessionPercent = Double(utilization)
      }
      if let resetsAt = fiveHour["resets_at"] as? String {
        sessionResets = parseISO8601Date(resetsAt)
      }
    }

    guard let sessionPercent else {
      // If we can't parse session utilization, treat this as a failure
      throw FetchError.invalidResponse
    }

    // Parse seven_day (weekly) usage
    var weeklyPercent: Double?
    var weeklyResets: Date?
    if let sevenDay = json["seven_day"] as? [String: Any] {
      if let utilization = sevenDay["utilization"] as? Int {
        weeklyPercent = Double(utilization)
      }
      if let resetsAt = sevenDay["resets_at"] as? String {
        weeklyResets = parseISO8601Date(resetsAt)
      }
    }

    return WebUsageData(
      sessionPercentUsed: sessionPercent,
      sessionResetsAt: sessionResets,
      weeklyPercentUsed: weeklyPercent,
      weeklyResetsAt: weeklyResets,
      planType: nil  // Will be populated by fetchAccountPlanType
    )
  }

  private static func fetchAccountPlanType(sessionKey: String, orgId: String) async -> String? {
    let url = URL(string: "\(baseURL)/account")!
    var request = URLRequest(url: url)
    request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpMethod = "GET"
    request.timeoutInterval = 15

    NSLog("[ClaudeWebAPI] Fetching account info for orgId: \(orgId)")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)

      if let httpResponse = response as? HTTPURLResponse {
        NSLog("[ClaudeWebAPI] Account API status: \(httpResponse.statusCode)")

        if httpResponse.statusCode != 200 {
          NSLog("[ClaudeWebAPI] Account API failed with status \(httpResponse.statusCode)")
          return nil
        }
      }

      let planType = parseAccountPlanType(data, orgId: orgId)
      NSLog("[ClaudeWebAPI] Parsed plan type: \(planType ?? "nil")")
      return planType
    } catch {
      NSLog("[ClaudeWebAPI] Account API error: \(error.localizedDescription)")
      return nil
    }
  }

  private static func parseAccountPlanType(_ data: Data, orgId: String) -> String? {
    guard let response = try? JSONDecoder().decode(AccountResponse.self, from: data) else {
      NSLog("[ClaudeWebAPI] Failed to decode AccountResponse")
      return nil
    }

    NSLog("[ClaudeWebAPI] Account has \(response.memberships?.count ?? 0) memberships")

    // Find matching membership or use first
    let membership = selectMembership(response.memberships, orgId: orgId)

    if let membership = membership {
      NSLog("[ClaudeWebAPI] Selected membership - rateLimitTier: \(membership.organization.rateLimitTier ?? "nil"), billingType: \(membership.organization.billingType ?? "nil")")
    } else {
      NSLog("[ClaudeWebAPI] No membership found")
    }

    return inferPlan(
      rateLimitTier: membership?.organization.rateLimitTier,
      billingType: membership?.organization.billingType
    )
  }

  private static func selectMembership(
    _ memberships: [AccountResponse.Membership]?,
    orgId: String
  ) -> AccountResponse.Membership? {
    guard let memberships, !memberships.isEmpty else { return nil }
    if let match = memberships.first(where: { $0.organization.uuid == orgId }) {
      return match
    }
    return memberships.first
  }

  private static func inferPlan(rateLimitTier: String?, billingType: String?) -> String? {
    let tier = rateLimitTier?.lowercased() ?? ""
    let billing = billingType?.lowercased() ?? ""

    NSLog("[ClaudeWebAPI] inferPlan - tier: '\(tier)', billing: '\(billing)'")

    if tier.contains("max") {
      NSLog("[ClaudeWebAPI] Matched: Max")
      return "Max"
    }
    if tier.contains("pro") {
      NSLog("[ClaudeWebAPI] Matched: Pro")
      return "Pro"
    }
    if tier.contains("team") {
      NSLog("[ClaudeWebAPI] Matched: Team")
      return "Team"
    }
    if tier.contains("enterprise") {
      NSLog("[ClaudeWebAPI] Matched: Enterprise")
      return "Enterprise"
    }
    if billing.contains("stripe"), tier.contains("claude") {
      NSLog("[ClaudeWebAPI] Matched: Pro (via stripe+claude)")
      return "Pro"
    }
    if billing.contains("apple") {
      NSLog("[ClaudeWebAPI] Matched: Pro (via apple)")
      return "Pro"
    }

    NSLog("[ClaudeWebAPI] No plan matched")
    return nil
  }

  private static func parseISO8601Date(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) {
      return date
    }
    // Try without fractional seconds
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }

  // MARK: - Conversion to ClaudeUsageStatus

  private static func convertToUsageStatus(_ usage: WebUsageData, now: Date)
    -> ClaudeUsageStatus
  {
    let fiveHourWindowMinutes = 5.0 * 60.0
    let weeklyWindowMinutes = 7.0 * 24.0 * 60.0

    // Convert percentage to minutes used
    let fiveHourUsedMinutes = (usage.sessionPercentUsed / 100.0) * fiveHourWindowMinutes
    let weeklyUsedMinutes =
      usage.weeklyPercentUsed.map { ($0 / 100.0) * weeklyWindowMinutes }

    return ClaudeUsageStatus(
      updatedAt: now,
      modelName: nil,
      contextUsedTokens: nil,
      contextLimitTokens: nil,
      fiveHourUsedMinutes: fiveHourUsedMinutes,
      fiveHourWindowMinutes: fiveHourWindowMinutes,
      fiveHourResetAt: usage.sessionResetsAt,
      weeklyUsedMinutes: weeklyUsedMinutes,
      weeklyWindowMinutes: weeklyWindowMinutes,
      weeklyResetAt: usage.weeklyResetsAt,
      sessionExpiresAt: nil,  // Web API doesn't have session expiry
      planType: usage.planType
    )
  }
}
