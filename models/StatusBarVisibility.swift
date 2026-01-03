import Foundation

enum StatusBarVisibility: String, CaseIterable, Identifiable, Codable {
  case auto
  case always
  case hidden

  var id: String { rawValue }
}
