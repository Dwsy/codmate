import SwiftUI
import AppKit

#if os(macOS)

/// Introspects the underlying NSTableView used by SwiftUI `Table`
/// and forces `intercellSpacing` to zero so vertically drawn
/// graph lanes can visually connect between rows.
struct TableSpacingRemover: NSViewRepresentable {
  let rowHeight: CGFloat?

  final class Coordinator {
    var applied: Bool = false
    weak var tableView: NSTableView?
  }

  init(rowHeight: CGFloat? = nil) {
    self.rowHeight = rowHeight
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      Self.applySpacingFix(
        from: view,
        rowHeight: rowHeight,
        coordinator: context.coordinator
      )
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    // Only attempt once per coordinator / table instance to avoid
    // repeatedly walking the NSView hierarchy during scroll.
    guard !context.coordinator.applied else { return }
    DispatchQueue.main.async {
      Self.applySpacingFix(
        from: nsView,
        rowHeight: rowHeight,
        coordinator: context.coordinator
      )
    }
  }

  private static func applySpacingFix(
    from view: NSView,
    rowHeight: CGFloat?,
    coordinator: Coordinator
  ) {
    if coordinator.applied,
      let tableView = coordinator.tableView,
      tableView.window != nil
    {
      return
    }

    guard let tableView = findTableView(from: view) else { return }
    coordinator.tableView = tableView

    // Force zero vertical intercell spacing to remove the visible gap
    // between rows for continuous graph lanes.
    let spacing = tableView.intercellSpacing
    if spacing.height != 0 {
      tableView.intercellSpacing = NSSize(width: spacing.width, height: 0)
    }

    // Optionally pin row height and disable automatic height so the
    // SwiftUI graph cell and the NSTableRowView share the same geometry.
    if let h = rowHeight {
      if tableView.rowHeight != h {
        tableView.rowHeight = h
      }
      if tableView.usesAutomaticRowHeights {
        tableView.usesAutomaticRowHeights = false
      }
    }

    coordinator.applied = true
  }

  /// Attempts to locate the NSTableView backing a SwiftUI `Table`
  /// near the given view by walking up to a root and then scanning
  /// descendants. This is more robust than relying on
  /// `enclosingScrollView` alone, since SwiftUI often arranges the
  /// hosting views as siblings.
  private static func findTableView(from view: NSView) -> NSTableView? {
    // First, try the straightforward enclosure path.
    if let scrollView = view.enclosingScrollView,
      let tableView = scrollView.documentView as? NSTableView
    {
      return tableView
    }

    // Otherwise, walk up to the top-most ancestor and search its subtree.
    var root: NSView = view
    while let parent = root.superview {
      root = parent
    }
    return findTableView(in: root)
  }

  private static func findTableView(in root: NSView) -> NSTableView? {
    if let tableView = root as? NSTableView {
      return tableView
    }
    for sub in root.subviews {
      if let tableView = findTableView(in: sub) {
        return tableView
      }
    }
    return nil
  }
}

extension View {
  /// Removes the default vertical `intercellSpacing` for the
  /// SwiftUI `Table` in which this view is hosted.
  func removeTableSpacing(rowHeight: CGFloat? = nil) -> some View {
    overlay(TableSpacingRemover(rowHeight: rowHeight).frame(width: 0, height: 0))
  }
}

#endif
