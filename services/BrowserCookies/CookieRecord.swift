import Foundation

/// Represents a cookie record extracted from browser storage
struct CookieRecord: Sendable {
  let domain: String
  let name: String
  let path: String
  let value: String
  let expires: Date?
  let isSecure: Bool
  let isHTTPOnly: Bool
}
