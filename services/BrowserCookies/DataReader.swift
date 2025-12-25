import Foundation

/// Helper class for reading binary data with support for different endianness
final class DataReader {
  let data: Data
  private(set) var offset: Int

  init(_ data: Data, offset: Int = 0) {
    self.data = data
    self.offset = offset
  }

  /// Read count bytes as ASCII string
  func readASCII(count: Int) -> String? {
    let d = self.read(count)
    return String(data: d, encoding: .ascii)
  }

  /// Read count bytes and advance offset
  func read(_ count: Int) -> Data {
    let end = min(self.offset + count, self.data.count)
    let slice = self.data[self.offset..<end]
    self.offset = end
    return Data(slice)
  }

  /// Read UInt32 in Big-Endian format (used by Safari cookie file header)
  func readUInt32BE() -> UInt32 {
    let d = self.read(4)
    return d.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
  }

  /// Read UInt32 in Little-Endian format (used by Safari cookie pages/records)
  func readUInt32LE() -> UInt32 {
    let d = self.read(4)
    return d.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
  }

  /// Read Double in Little-Endian format (used for timestamp fields)
  func readDoubleLE() -> Double {
    let d = self.read(8)
    let raw = d.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
    return Double(bitPattern: raw)
  }
}
