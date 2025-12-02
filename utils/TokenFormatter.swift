import Foundation

enum TokenFormatter {
  /// Compact readable string for tokens (uses K/M/B suffixes).
  static func short(_ value: Int) -> String {
    let absValue = Double(abs(value))
    let sign = value < 0 ? "-" : ""

    switch absValue {
    case 0..<1_000:
      return "\(value.formatted())"
    case 1_000..<1_000_000:
      return "\(sign)\(format(absValue / 1_000, digits: 1))K"
    case 1_000_000..<1_000_000_000:
      return "\(sign)\(format(absValue / 1_000_000, digits: 2))M"
    default:
      return "\(sign)\(format(absValue / 1_000_000_000, digits: 2))B"
    }
  }

  /// Decimal string with optional K/M suffix used by usage panes.
  static func string(from value: Int) -> String {
    let absValue = abs(value)
    switch absValue {
    case 1_000_000...:
      return format(Double(value) / 1_000_000, digits: 1) + "M"
    case 1_000...:
      return format(Double(value) / 1_000, digits: 1) + "K"
    default:
      return NumberFormatter.decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
  }

  private static func format(_ value: Double, digits: Int) -> String {
    let formatter = NumberFormatter()
    formatter.maximumFractionDigits = digits
    formatter.minimumFractionDigits = 0
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
  }
}
