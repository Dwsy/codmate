import Foundation

enum RefreshRequestKind: String {
  case context
  case global
}

enum RefreshRequest {
  static let userInfoKey = "refreshKind"

  static func userInfo(for kind: RefreshRequestKind) -> [AnyHashable: Any] {
    [userInfoKey: kind.rawValue]
  }

  static func kind(from userInfo: [AnyHashable: Any]?) -> RefreshRequestKind {
    guard
      let userInfo,
      let raw = userInfo[userInfoKey] as? String,
      let kind = RefreshRequestKind(rawValue: raw)
    else {
      return .context
    }
    return kind
  }
}
