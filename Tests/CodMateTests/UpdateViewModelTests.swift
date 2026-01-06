import Foundation
import XCTest
@testable import CodMate

final class UpdateViewModelTests: XCTestCase {
  @MainActor
  func testInstallInstructions() {
    let vm = UpdateViewModel(service: UpdateService())
    XCTAssertTrue(vm.installInstructions.contains("Applications"))
  }

  @MainActor
  func testSandboxDownloadUsesTemporaryDirectory() async throws {
    let originalSandbox = getenv("APP_SANDBOX_CONTAINER_ID").map { String(cString: $0) }
    defer {
      if let originalSandbox {
        setenv("APP_SANDBOX_CONTAINER_ID", originalSandbox, 1)
      } else {
        unsetenv("APP_SANDBOX_CONTAINER_ID")
      }
      MockURLProtocol.requestHandler = nil
    }

    let fileManager = FileManager.default
    let downloadsDir = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
    let sourceURL = fileManager.temporaryDirectory.appendingPathComponent("codmate-test-source.dmg")
    try Data("test".utf8).write(to: sourceURL)
    let assetName = UpdateAssetSelector.assetName(for: .current)
    let releaseJSON = """
    {
      "tag_name": "v999.0.0",
      "html_url": "https://example.com/release",
      "draft": false,
      "prerelease": false,
      "assets": [
        {
          "name": "\(assetName)",
          "browser_download_url": "\(sourceURL.absoluteString)"
        }
      ]
    }
    """
    let releaseData = Data(releaseJSON.utf8)

    MockURLProtocol.requestHandler = { request in
      let response = HTTPURLResponse(
        url: request.url ?? URL(string: "https://api.github.com/")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
      return (response, releaseData)
    }

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    let defaults = UserDefaults(suiteName: "UpdateViewModelTests")!
    defaults.removePersistentDomain(forName: "UpdateViewModelTests")
    let service = UpdateService(defaults: defaults, session: session, calendar: Calendar(identifier: .gregorian))
    let vm = UpdateViewModel(service: service)

    vm.checkNow()
    let didUpdate = await waitUntil({
      if case .updateAvailable = vm.state { return true }
      return false
    }, timeout: 2.0)
    XCTAssertTrue(didUpdate)

    setenv("APP_SANDBOX_CONTAINER_ID", "1", 1)
    let start = Date()
    vm.downloadIfNeeded()
    let didDownload = await waitUntil({
      vm.showInstallInstructions || (!vm.isDownloading && vm.lastError != nil)
    }, timeout: 5.0)
    XCTAssertTrue(didDownload)
    XCTAssertNil(vm.lastError)
    XCTAssertTrue(vm.showInstallInstructions)

    let tempHit = findDownloadedFile(in: fileManager.temporaryDirectory, baseName: assetName, since: start)
    let downloadsHit = findDownloadedFile(in: downloadsDir, baseName: assetName, since: start)
    XCTAssertNotNil(tempHit)
    XCTAssertNil(downloadsHit)

    if let tempHit { try? fileManager.removeItem(at: tempHit) }
    if let downloadsHit { try? fileManager.removeItem(at: downloadsHit) }
    try? fileManager.removeItem(at: sourceURL)
  }
}

private final class MockURLProtocol: URLProtocol {
  static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let handler = Self.requestHandler else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private func findDownloadedFile(in directory: URL, baseName: String, since: Date) -> URL? {
  let cutoff = since.addingTimeInterval(-2)
  guard let urls = try? FileManager.default.contentsOfDirectory(
    at: directory,
    includingPropertiesForKeys: [.contentModificationDateKey],
    options: [.skipsHiddenFiles]
  ) else { return nil }
  for url in urls {
    let name = url.lastPathComponent
    guard name == baseName || name.hasSuffix("-\(baseName)") else { continue }
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
    if let date = values?.contentModificationDate, date >= cutoff {
      return url
    }
  }
  return nil
}

private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return true }
    try? await Task.sleep(nanoseconds: 50_000_000)
  }
  return condition()
}
