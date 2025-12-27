import AppKit
import Darwin
import Foundation

#if canImport(SwiftTerm)
  import SwiftTerm

  private final class TerminalDelegateStub: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
      // No-op.
    }
  }

  private final class LocalProcessDelegateProxy: LocalProcessDelegate {
    weak var target: LocalProcessDelegate?

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
      target?.processTerminated(source, exitCode: exitCode)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
      target?.dataReceived(slice: slice)
    }

    func getWindowSize() -> winsize {
      target?.getWindowSize() ?? winsize(ws_row: 25, ws_col: 80, ws_xpixel: 16, ws_ypixel: 16)
    }
  }

  final class HeadlessTerminalSession: TerminalViewDelegate, LocalProcessDelegate, TerminalDelegate {
    let sessionKey: String
    let terminal: Terminal
    let process: LocalProcess
    let ioQueue: DispatchQueue
    private let processDelegateProxy = LocalProcessDelegateProxy()

    private(set) var isRunning: Bool = false
    private weak var attachedView: TerminalView?
    private var lastWindowSize = winsize(ws_row: 25, ws_col: 80, ws_xpixel: 16, ws_ypixel: 16)
    private var receivedWhileDetached: Bool = false

    var onDataReceived: (() -> Void)?
    var onProcessTerminated: ((Int32?) -> Void)?

    private var pendingChunks: [[UInt8]] = []
    private var pendingChunkIndex: Int = 0
    private var pendingFlushWork: DispatchWorkItem?
    private var drainScheduled: Bool = false
    private let flushInterval: TimeInterval = 0.004
    private let maxDrainBytes = 8 * 1024
    private let maxDrainChunks = 12
    private let fastDrainBytes = 64 * 1024
    private let fastDrainChunks = 48
    private let immediateFlushThresholdBytes = 96
    private let typingFlushWindow: TimeInterval = 0.08
    private let typingChunkSoftLimit = 512
    private var lastTypingAt: TimeInterval = 0

    init(sessionKey: String, options: TerminalOptions, ioQueue: DispatchQueue? = nil) {
      self.sessionKey = sessionKey
      self.ioQueue = ioQueue ?? DispatchQueue(
        label: "io.codmate.terminal.session.\(sessionKey)", qos: .userInitiated)
      terminal = Terminal(delegate: TerminalDelegateStub(), options: options)
      process = LocalProcess(delegate: processDelegateProxy, dispatchQueue: self.ioQueue)
      processDelegateProxy.target = self
      terminal.setDelegate(self)
    }

    func attach(view: TerminalView) {
      attachedView = view
      updateWindowSize(from: view, cols: terminal.cols, rows: terminal.rows)
    }

    func detachView() {
      attachedView = nil
      terminal.setDelegate(self)
      onDataReceived = nil
    }

    func consumeDetachedOutputFlag() -> Bool {
      return ioQueue.sync {
        let hadOutput = receivedWhileDetached
        receivedWhileDetached = false
        return hadOutput
      }
    }

    func startProcess(
      executable: String,
      args: [String],
      environment: [String]?,
      execName: String?,
      currentDirectory: String?
    ) {
      process.startProcess(
        executable: executable,
        args: args,
        environment: environment,
        execName: execName,
        currentDirectory: currentDirectory
      )
      isRunning = process.running
    }

    func send(data: ArraySlice<UInt8>) {
      process.send(data: data)
    }

    func terminate() {
      process.terminate()
      isRunning = process.running
    }

    func flushPendingData() {
      scheduleDrain()
    }

    // MARK: - TerminalViewDelegate
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
      updateWindowSize(from: source, cols: newCols, rows: newRows)
      guard process.running else { return }
      var size = lastWindowSize
      _ = PseudoTerminalHelpers.setWinSize(
        masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
      // No-op.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
      // No-op.
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
      markTypingEvent()
      process.send(data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
      // No-op.
    }

    func clipboardCopy(source: TerminalView, content: Data) {
      // No-op.
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
      // No-op.
    }

    // MARK: - TerminalDelegate (headless fallback)
    func send(source: Terminal, data: ArraySlice<UInt8>) {
      process.send(data: data)
    }

    // MARK: - LocalProcessDelegate
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
      isRunning = false
      NotificationCenter.default.post(
        name: .codMateTerminalExited,
        object: nil,
        userInfo: ["sessionID": sessionKey, "exitCode": exitCode as Any]
      )
      onProcessTerminated?(exitCode)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
      enqueueChunk(Array(slice))
    }

    func getWindowSize() -> winsize {
      if let view = attachedView {
        updateWindowSize(from: view, cols: terminal.cols, rows: terminal.rows)
      }
      return lastWindowSize
    }

    // MARK: - Internal
    private func markTypingEvent() {
      lastTypingAt = CFAbsoluteTimeGetCurrent()
    }

    private func updateWindowSize(from view: TerminalView, cols: Int, rows: Int) {
      let frame = view.frame
      lastWindowSize = winsize(
        ws_row: UInt16(max(rows, 1)),
        ws_col: UInt16(max(cols, 1)),
        ws_xpixel: UInt16(max(Int(frame.width), 1)),
        ws_ypixel: UInt16(max(Int(frame.height), 1))
      )
    }

    private func enqueueChunk(_ chunk: [UInt8]) {
      if shouldFlushImmediately(for: chunk) {
        pendingChunks.append(chunk)
        scheduleDrain()
        return
      }
      pendingChunks.append(chunk)
      scheduleFlush()
    }

    private func shouldFlushImmediately(for chunk: [UInt8]) -> Bool {
      if pendingChunks.isEmpty && chunk.count <= immediateFlushThresholdBytes {
        return true
      }
      if chunk.count <= typingChunkSoftLimit {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastTypingAt <= typingFlushWindow {
          return true
        }
      }
      return false
    }

    private func scheduleFlush() {
      guard pendingFlushWork == nil else { return }
      let work = DispatchWorkItem { [weak self] in
        self?.scheduleDrain()
      }
      pendingFlushWork = work
      ioQueue.asyncAfter(deadline: .now() + flushInterval, execute: work)
    }

    private func scheduleDrain() {
      ioQueue.async { [weak self] in
        self?.scheduleDrainOnQueue()
      }
    }

    private func scheduleDrainOnQueue() {
      guard !drainScheduled else { return }
      drainScheduled = true
      drainNextBatchOnQueue()
    }

    private func drainNextBatchOnQueue() {
      pendingFlushWork?.cancel()
      pendingFlushWork = nil
      let (batchBytes, batchChunks) = drainTuning()
      let batch = takeBatch(maxBytes: batchBytes, maxChunks: batchChunks)
      guard !batch.isEmpty else {
        drainScheduled = false
        notifyFlushComplete()
        return
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.feedToTerminal(slice: batch[...])
        self.ioQueue.async { [weak self] in
          self?.drainNextBatchOnQueue()
        }
      }
    }

    private func drainTuning() -> (Int, Int) {
      let remainingChunks = pendingChunks.count - pendingChunkIndex
      let backlog = max(remainingChunks, 0)
      if backlog > 96 {
        return (fastDrainBytes, fastDrainChunks)
      }
      return (maxDrainBytes, maxDrainChunks)
    }

    private func takeBatch(maxBytes: Int, maxChunks: Int) -> [UInt8] {
      guard pendingChunkIndex < pendingChunks.count else {
        pendingChunks.removeAll(keepingCapacity: true)
        pendingChunkIndex = 0
        return []
      }
      var merged: [UInt8] = []
      merged.reserveCapacity(maxBytes)
      var bytes = 0
      var chunksUsed = 0
      while pendingChunkIndex < pendingChunks.count && chunksUsed < maxChunks && bytes < maxBytes {
        let chunk = pendingChunks[pendingChunkIndex]
        pendingChunkIndex += 1
        if chunk.isEmpty { continue }
        let remaining = maxBytes - bytes
        if chunk.count <= remaining {
          merged.append(contentsOf: chunk)
          bytes += chunk.count
        } else {
          merged.append(contentsOf: chunk.prefix(remaining))
          let tail = Array(chunk.dropFirst(remaining))
          pendingChunkIndex -= 1
          pendingChunks[pendingChunkIndex] = tail
          bytes = maxBytes
        }
        chunksUsed += 1
      }
      if pendingChunkIndex > 64 && pendingChunkIndex * 2 > pendingChunks.count {
        pendingChunks.removeFirst(pendingChunkIndex)
        pendingChunkIndex = 0
      }
      return merged
    }

    private func notifyFlushComplete() {
      DispatchQueue.main.async { [weak self] in
        guard let self, let view = self.attachedView else { return }
        view.startDisplayUpdates()
        view.requestDisplayRefresh()
      }
    }

    private func feedToTerminal(slice: ArraySlice<UInt8>) {
      if let view = attachedView {
        view.feed(byteArray: slice)
      } else {
        ioQueue.async { [weak self] in
          self?.receivedWhileDetached = true
        }
        terminal.feed(buffer: slice)
      }
      if let onDataReceived {
        DispatchQueue.main.async {
          onDataReceived()
        }
      }
    }
  }
#endif
