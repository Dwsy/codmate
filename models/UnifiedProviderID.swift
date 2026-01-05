import Foundation

enum UnifiedProviderID {
  static let oauthPrefix = "oauth:"
  static let apiPrefix = "api:"
  static let legacyReroutePrefix = "local-reroute:"

  /// Special provider ID for "Auto (CLI Proxy API)" mode in simple picker
  static let autoProxyId = "__auto_cli_proxy__"

  enum Parsed: Equatable {
    case oauth(LocalAuthProvider, accountId: String?)
    case api(String)
    case legacyBuiltin(LocalServerBuiltInProvider)
    case legacyReroute(String)
    case autoProxy
    case unknown(String)
  }

  static func oauth(_ provider: LocalAuthProvider, accountId: String? = nil) -> String {
    if let accountId = accountId, !accountId.isEmpty {
      return "\(oauthPrefix)\(provider.rawValue):\(accountId)"
    }
    return "\(oauthPrefix)\(provider.rawValue)"
  }

  static func api(_ id: String) -> String {
    "\(apiPrefix)\(id)"
  }

  static func parse(_ raw: String) -> Parsed {
    // Check for special auto proxy ID first
    if raw == autoProxyId {
      return .autoProxy
    }
    if raw.hasPrefix(oauthPrefix) {
      let value = String(raw.dropFirst(oauthPrefix.count))
      // Check if it contains account ID (format: provider:accountId)
      if let colonIndex = value.firstIndex(of: ":") {
        let providerValue = String(value[..<colonIndex])
        let accountId = String(value[value.index(after: colonIndex)...])
        if let provider = LocalAuthProvider(rawValue: providerValue) {
          return .oauth(provider, accountId: accountId)
        }
      } else {
        // Legacy format without account ID
        if let provider = LocalAuthProvider(rawValue: value) {
          return .oauth(provider, accountId: nil)
        }
      }
      return .unknown(raw)
    }
    if raw.hasPrefix(apiPrefix) {
      let value = String(raw.dropFirst(apiPrefix.count))
      return .api(value)
    }
    if let builtin = LocalServerBuiltInProvider.from(providerId: raw) {
      return .legacyBuiltin(builtin)
    }
    if raw.hasPrefix(legacyReroutePrefix) {
      let value = String(raw.dropFirst(legacyReroutePrefix.count)).trimmingCharacters(
        in: .whitespacesAndNewlines)
      return .legacyReroute(value)
    }
    return .unknown(raw)
  }

  static func normalize(
    _ raw: String?,
    registryProviders: [ProvidersRegistryService.Provider]
  ) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    switch parse(raw) {
    case .autoProxy:
      return autoProxyId
    case .oauth:
      return raw
    case .api:
      return raw
    case .legacyBuiltin(let builtin):
      if let auth = authProvider(for: builtin) {
        return oauth(auth, accountId: nil)
      }
      return nil
    case .legacyReroute(let label):
      if let resolved = resolveAPIProviderId(
        byLabel: label,
        registryProviders: registryProviders
      ) {
        return api(resolved)
      }
      return nil
    case .unknown(let value):
      if let match = registryProviders.first(where: { $0.id == value }) {
        return api(match.id)
      }
      if let match = registryProviders.first(where: {
        providerDisplayName($0).localizedCaseInsensitiveCompare(value) == .orderedSame
      }) {
        return api(match.id)
      }
      return nil
    }
  }

  static func authProvider(for builtin: LocalServerBuiltInProvider) -> LocalAuthProvider? {
    switch builtin {
    case .openai:
      return .codex
    case .anthropic:
      return .claude
    case .gemini:
      return .gemini
    case .antigravity:
      return .antigravity
    case .qwen:
      return .qwen
    }
  }

  static func resolveAPIProviderId(
    byLabel label: String,
    registryProviders: [ProvidersRegistryService.Provider]
  ) -> String? {
    let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    if let match = registryProviders.first(where: {
      providerDisplayName($0).lowercased() == normalized
    }) {
      return match.id
    }
    if let match = registryProviders.first(where: { $0.id.lowercased() == normalized }) {
      return match.id
    }
    return nil
  }

  static func providerDisplayName(_ provider: ProvidersRegistryService.Provider) -> String {
    let name = provider.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? provider.id : name
  }
}
