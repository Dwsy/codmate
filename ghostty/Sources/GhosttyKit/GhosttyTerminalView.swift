//
//  GhosttyTerminalView.swift
//  CodMate
//
//  NSView subclass that integrates Ghostty terminal rendering
//
//  This file is adapted from Aizen (https://github.com/vivy-company/aizen)
//  which provided the initial Ghostty embedding implementation.
//

import AppKit
import Metal
import OSLog
import SwiftUI
import CGhostty

/// NSView that embeds a Ghostty terminal surface with Metal rendering
///
/// This view handles:
/// - Metal layer setup for terminal rendering
/// - Input forwarding (keyboard, mouse, scroll)
/// - Focus management
/// - Surface lifecycle management
@MainActor
public class GhosttyTerminalView: NSView {
    // MARK: - Properties

    private var ghosttyApp: ghostty_app_t?
    private weak var ghosttyAppWrapper: Ghostty.App?
    internal var surface: Ghostty.Surface?
    private var surfaceReference: Ghostty.SurfaceReference?
    private var surfaceUserdata: Ghostty.SurfaceUserdata?
    private let worktreePath: String
    private let paneId: String?
    private let initialCommand: String?

    /// Callback invoked when the terminal process exits
    var onProcessExit: (() -> Void)?

    /// Callback invoked when the terminal title changes
    var onTitleChange: ((String) -> Void)?
    
    /// Callback when the surface has produced its first layout/draw (used to hide loading UI)
    public var onReady: (() -> Void)?
    
    /// Callback for OSC 9;4 progress reports
    var onProgressReport: ((GhosttyProgressState, Int?) -> Void)?
    private var didSignalReady = false

    /// Cell size in points for row-to-pixel conversion (used by scroll view)
    var cellSize: NSSize = .zero

    /// Current scrollbar state from Ghostty core (used by scroll view)
    var scrollbar: Ghostty.Action.Scrollbar?

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai.umate.codmate", category: "GhosttyTerminal")

    // MARK: - Handler Components

    private var imeHandler: GhosttyIMEHandler!
    private var inputHandler: GhosttyInputHandler!
    private let renderingSetup = GhosttyRenderingSetup()

    /// Observation for appearance changes
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Initialization

    /// Create a new Ghostty terminal view
    ///
    /// - Parameters:
    ///   - frame: The initial frame for the view
    ///   - worktreePath: Working directory for the terminal session
    ///   - ghosttyApp: The shared Ghostty app instance (C pointer)
    ///   - appWrapper: The Ghostty.App wrapper for surface tracking (optional)
    ///   - paneId: Unique identifier for this pane (used for tmux session persistence)
    ///   - command: Optional command to run instead of default shell
    public init(frame: NSRect, worktreePath: String, ghosttyApp: ghostty_app_t, appWrapper: Ghostty.App? = nil, paneId: String? = nil, command: String? = nil) {
        NSLog("[GhosttyTerminalView] init called with worktreePath: %@", worktreePath)
        self.worktreePath = worktreePath
        self.ghosttyApp = ghosttyApp
        self.ghosttyAppWrapper = appWrapper
        self.paneId = paneId
        self.initialCommand = command

        // Use a reasonable default size if frame is zero
        let initialFrame = frame.width > 0 && frame.height > 0 ? frame : NSRect(x: 0, y: 0, width: 800, height: 600)
        NSLog("[GhosttyTerminalView] super.init with frame: %@", NSStringFromRect(initialFrame))
        super.init(frame: initialFrame)

        registerForDraggedTypes([.fileURL, .tiff, .png])

        // Initialize handlers before setup
        NSLog("[GhosttyTerminalView] creating IME handler")
        self.imeHandler = GhosttyIMEHandler(view: self, surface: nil)
        NSLog("[GhosttyTerminalView] creating input handler")
        self.inputHandler = GhosttyInputHandler(view: self, surface: nil, imeHandler: self.imeHandler)

        NSLog("[GhosttyTerminalView] setupLayer")
        setupLayer()
        NSLog("[GhosttyTerminalView] setupSurface")
        setupSurface()
        NSLog("[GhosttyTerminalView] setupTrackingArea")
        setupTrackingArea()
        NSLog("[GhosttyTerminalView] setupAppearanceObservation")
        setupAppearanceObservation()
        NSLog("[GhosttyTerminalView] setupFrameObservation")
        setupFrameObservation()

        // Send initial command after shell startup delay
        // This avoids the double-echo issue caused by initial_input
        if let command = initialCommand, !command.isEmpty {
            scheduleInitialCommand(command)
        }

        NSLog("[GhosttyTerminalView] init complete")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        NSLog("[GhosttyTerminalView] deinit called - view being deallocated")
        // Surface cleanup happens via Surface's deinit
        // Note: Cannot access @MainActor properties in deinit
        // Tracking areas are automatically cleaned up by NSView
        // Appearance observation is automatically invalidated
        NotificationCenter.default.removeObserver(self)

        // Surface reference cleanup needs to happen on main actor
        // We capture the values before the Task to avoid capturing self
        let wrapper = self.ghosttyAppWrapper
        let ref = self.surfaceReference
        if let wrapper = wrapper, let ref = ref {
            Task { @MainActor in
                NSLog("[GhosttyTerminalView] deinit: unregistering surface")
                wrapper.unregisterSurface(ref)
            }
        }
    }

    // MARK: - Setup

    /// Configure the Metal-backed layer for terminal rendering
    private func setupLayer() {
        renderingSetup.setupLayer(for: self)
    }

    /// Create and configure the Ghostty surface
    private func setupSurface() {
        guard let app = ghosttyApp else {
            Self.logger.error("Cannot create surface: ghostty_app_t is nil")
            return
        }

        let surfaceUserdata = Ghostty.SurfaceUserdata(view: self)
        let surfaceUserdataPointer = Unmanaged.passRetained(surfaceUserdata).toOpaque()

        guard let cSurface = renderingSetup.setupSurface(
            view: self,
            ghosttyApp: app,
            worktreePath: worktreePath,
            initialBounds: bounds,
            window: window,
            paneId: paneId,
            command: initialCommand,
            userdata: surfaceUserdataPointer
        ) else {
            Unmanaged<Ghostty.SurfaceUserdata>.fromOpaque(surfaceUserdataPointer).release()
            return
        }

        // Wrap in Swift Surface class
        self.surface = Ghostty.Surface(cSurface: cSurface, userdataToRelease: surfaceUserdataPointer)
        self.surfaceUserdata = surfaceUserdata

        // Update handlers with surface
        imeHandler.updateSurface(self.surface)
        inputHandler.updateSurface(self.surface)

        // Register surface with app wrapper for config update tracking
        if let wrapper = ghosttyAppWrapper {
            self.surfaceReference = wrapper.registerSurface(cSurface)
        }
    }

    /// Setup mouse tracking area for the entire view
    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .inVisibleRect,
            .activeAlways  // Track even when not focused
        ]

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    /// Setup observation for system appearance changes (light/dark mode)
    private func setupAppearanceObservation() {
        appearanceObservation = renderingSetup.setupAppearanceObservation(for: self, surface: surface)
    }

    private func setupFrameObservation() {
        // We rely on layout() + updateLayout to resize the surface.
        self.postsFrameChangedNotifications = false
        
        // Listen for config reload notifications to trigger reflow on font size changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigReload),
            name: .ghosttyConfigDidReload,
            object: nil
        )
    }
    
    @objc private func handleConfigReload() {
        // Force layout update when font size or cursor style changes
        // This ensures the surface size is recalculated with new settings
        lastSurfaceSize = .zero
        needsLayout = true
        layout()
        
        // Also force a refresh to ensure the surface is redrawn
        forceRefresh()
    }

    // MARK: - Initial Command

    /// Flag to track if initial command has been sent (prevents duplicate sends)
    private var initialCommandSent = false

    /// Schedule the initial command to be sent after shell startup
    /// Uses a delay to ensure shell has time to initialize and display its prompt
    private func scheduleInitialCommand(_ command: String) {
        // Use a delay to wait for shell startup
        // 300ms is typically enough for shell to initialize and display prompt
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
            self?.sendInitialCommandIfNeeded(command)
        }
    }

    /// Send the initial command if not already sent
    private func sendInitialCommandIfNeeded(_ command: String) {
        guard !initialCommandSent else {
            NSLog("[GhosttyTerminalView] initial command already sent, skipping")
            return
        }
        guard let surface = surface else {
            NSLog("[GhosttyTerminalView] surface is nil, cannot send initial command")
            return
        }

        initialCommandSent = true

        // Normalize command: ensure it ends with exactly one newline
        var normalizedCommand = command
        while normalizedCommand.hasSuffix("\n") || normalizedCommand.hasSuffix("\r") {
            normalizedCommand.removeLast()
        }

        guard !normalizedCommand.isEmpty else {
            NSLog("[GhosttyTerminalView] normalized command is empty, skipping")
            return
        }

        NSLog("[GhosttyTerminalView] sending initial command: %@", normalizedCommand)
        surface.sendText(normalizedCommand + "\n")
    }

    // MARK: - NSView Overrides

    public override var acceptsFirstResponder: Bool {
        return true
    }

    public override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface = surface?.unsafeCValue {
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface = surface?.unsafeCValue {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Remove old tracking areas
        trackingAreas.forEach { removeTrackingArea($0) }

        // Recreate with current bounds
        setupTrackingArea()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderingSetup.updateBackingProperties(view: self, surface: surface?.unsafeCValue, window: window)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Single refresh when view moves to window
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                self?.forceRefresh()
            }
        }
    }

    // Track last size sent to Ghostty to avoid redundant updates
    private var lastSurfaceSize: CGSize = .zero

    // Override safe area insets to use full available space, including rounded corners
    // This matches Ghostty's SurfaceScrollView implementation
    public override var safeAreaInsets: NSEdgeInsets {
        return NSEdgeInsetsZero
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        // Force layout to be called to fix up subviews
        // This matches Ghostty's SurfaceScrollView.setFrameSize
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let didUpdate = renderingSetup.updateLayout(
            view: self,
            metalLayer: layer as? CAMetalLayer,
            surface: surface?.unsafeCValue,
            lastSize: &lastSurfaceSize
        )
        if didUpdate {
            NSLog("[GhosttyTerminalView] layout: size updated to %@", NSStringFromSize(bounds.size))
            if !didSignalReady {
                didSignalReady = true
                NSLog("[GhosttyTerminalView] layout: signaling onReady")
                onReady?()
            }
        }
    }

    // MARK: - Keyboard Input

    public override func keyDown(with event: NSEvent) {
        inputHandler.handleKeyDown(with: event) { [weak self] events in
            self?.interpretKeyEvents(events)
        }
    }

    public override func keyUp(with event: NSEvent) {
        inputHandler.handleKeyUp(with: event)
    }

    public override func flagsChanged(with event: NSEvent) {
        inputHandler.handleFlagsChanged(with: event)
    }

    public override func doCommand(by selector: Selector) {
        // Override to suppress NSBeep when interpretKeyEvents encounters unhandled commands
        // Without this, keys like delete at beginning of line, cmd+c with no selection, etc. cause beeps
        // Terminal handles all input via Ghostty, so we silently ignore unhandled commands
    }

    @objc func paste(_ sender: Any?) {
        if handlePasteboardAttachments(NSPasteboard.general, appendTrailingSpace: false) {
            return
        }
        if let surface = surface, surface.perform(action: "paste") {
            return
        }
        if let text = NSPasteboard.general.string(forType: .string),
           !text.isEmpty {
            surface?.sendText(text)
        }
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        if canHandlePasteboard(pasteboard) {
            return .copy
        }
        return []
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return handlePasteboardAttachments(sender.draggingPasteboard, appendTrailingSpace: true)
    }

    // MARK: - Mouse Input

    public override func mouseDown(with event: NSEvent) {
        inputHandler.handleMouseDown(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        inputHandler.handleMouseUp(with: event)
    }

    public override func rightMouseDown(with event: NSEvent) {
        inputHandler.handleRightMouseDown(with: event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        inputHandler.handleRightMouseUp(with: event)
    }

    public override func otherMouseDown(with event: NSEvent) {
        inputHandler.handleOtherMouseDown(with: event)
    }

    public override func otherMouseUp(with event: NSEvent) {
        inputHandler.handleOtherMouseUp(with: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        inputHandler.handleMouseMoved(with: event, viewFrame: frame) { [weak self] point, view in
            self?.convert(point, from: view) ?? .zero
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        inputHandler.handleMouseEntered(with: event, viewFrame: frame) { [weak self] point, view in
            self?.convert(point, from: view) ?? .zero
        }
    }

    public override func mouseExited(with event: NSEvent) {
        inputHandler.handleMouseExited(with: event)
    }

    public override func scrollWheel(with event: NSEvent) {
        inputHandler.handleScrollWheel(with: event)
    }

    // MARK: - Process Lifecycle

    /// Check if the terminal process has exited
    var processExited: Bool {
        guard let surface = surface?.unsafeCValue else { return true }
        return ghostty_surface_process_exited(surface)
    }

    /// Check if closing this terminal needs confirmation
    public var needsConfirmQuit: Bool {
        guard let surface = surface else { return false }
        return surface.needsConfirmQuit
    }

    /// Get current terminal grid size
    func terminalSize() -> Ghostty.Surface.TerminalSize? {
        guard let surface = surface else { return nil }
        return surface.terminalSize()
    }

    /// Send text to the terminal as if typed (used for initial command injection).
    @MainActor
    public func sendText(_ text: String) {
        surface?.sendText(text)
    }

    /// Force the terminal surface to refresh/redraw
    /// Useful after tmux reattaches or when view becomes visible
    func forceRefresh() {
        guard let surface = surface?.unsafeCValue else { return }

        // Force a size update to trigger tmux redraw
        let scaledSize = convertToBacking(bounds.size)
        ghostty_surface_set_size(
            surface,
            UInt32(scaledSize.width),
            UInt32(scaledSize.height)
        )

        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)

        // Trigger app tick to process any pending updates
        ghosttyAppWrapper?.appTick()

        // Force Metal layer to redraw
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.setNeedsDisplay()
        }
        layer?.setNeedsDisplay()
        needsDisplay = true
        needsLayout = true
        displayIfNeeded()
    }

    // MARK: - Paste / Drop Helpers

    @MainActor
    func handlePasteCommandIfNeeded(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "v" else {
            return false
        }
        paste(nil)
        return true
    }

    @MainActor
    func handlePasteboardAttachments(_ pasteboard: NSPasteboard, appendTrailingSpace: Bool) -> Bool {
        if let urls = extractFileURLs(from: pasteboard), !urls.isEmpty {
            pasteFileURLs(urls, appendTrailingSpace: appendTrailingSpace)
            return true
        }
        if let image = NSImage(pasteboard: pasteboard),
           let url = writeImageToTemp(image) {
            pasteFileURLs([url], appendTrailingSpace: appendTrailingSpace)
            return true
        }
        return false
    }

    @MainActor
    func canHandlePasteboard(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = extractFileURLs(from: pasteboard), !urls.isEmpty {
            return true
        }
        if NSImage(pasteboard: pasteboard) != nil {
            return true
        }
        return false
    }

    private func extractFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] else {
            return nil
        }
        return objects.filter { $0.isFileURL }
    }

    @MainActor
    private func pasteFileURLs(_ urls: [URL], appendTrailingSpace: Bool) {
        let escaped = urls.map { shellEscapeForPaste($0.path) }
        guard !escaped.isEmpty else { return }
        var text = escaped.joined(separator: " ")
        if appendTrailingSpace {
            text += " "
        }
        surface?.sendText(text)
    }

    private func shellEscapeForPaste(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'" + escaped + "'"
    }

    private func writeImageToTemp(_ image: NSImage) -> URL? {
        guard let data = image.pngData() else { return nil }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codmate-ghostty", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let name = "paste-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).png"
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - NSTextInputClient Implementation

/// NSTextInputClient protocol conformance for IME (Input Method Editor) support
/// Use @preconcurrency to suppress Swift 6 actor isolation warnings since NSTextInputClient
/// is an Objective-C protocol that predates Swift concurrency
extension GhosttyTerminalView: @preconcurrency NSTextInputClient {
    public func insertText(_ string: Any, replacementRange: NSRange) {
        imeHandler.insertText(string, replacementRange: replacementRange)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        imeHandler.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    public func unmarkText() {
        imeHandler.unmarkText()
    }

    public func selectedRange() -> NSRange {
        return imeHandler.selectedRange()
    }

    public func markedRange() -> NSRange {
        return imeHandler.markedRange()
    }

    public func hasMarkedText() -> Bool {
        return imeHandler.hasMarkedText
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return imeHandler.attributedSubstring(forProposedRange: range, actualRange: actualRange)
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return imeHandler.validAttributesForMarkedText()
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        return imeHandler.firstRect(
            forCharacterRange: range,
            actualRange: actualRange,
            viewFrame: frame,
            window: window,
            surface: surface?.unsafeCValue
        )
    }

    public func characterIndex(for point: NSPoint) -> Int {
        return imeHandler.characterIndex(for: point)
    }
}
