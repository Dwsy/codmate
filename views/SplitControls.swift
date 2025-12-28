import AppKit
import SwiftUI
import CoreImage

private let menuIconSize = NSSize(width: 14, height: 14)

func menuAssetNSImage(named name: String, invertForDarkMode: Bool = false) -> NSImage? {
  guard let image = NSImage(named: name) else { return nil }
  let resized = resizedMenuImage(image)
  if invertForDarkMode {
    return invertedMenuImage(resized) ?? resized
  }
  return resized
}

func menuSystemNSImage(named name: String) -> NSImage? {
  guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
  let resized = resizedMenuImage(image)
  resized.isTemplate = true
  return resized
}

private func resizedMenuImage(_ image: NSImage) -> NSImage {
  let newImage = NSImage(size: menuIconSize)
  newImage.lockFocus()
  image.draw(
    in: NSRect(origin: .zero, size: menuIconSize),
    from: NSRect(origin: .zero, size: image.size),
    operation: .copy,
    fraction: 1.0
  )
  newImage.unlockFocus()
  return newImage
}

func invertedMenuImage(_ image: NSImage) -> NSImage? {
  guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    return nil
  }
  let ciImage = CIImage(cgImage: cgImage)
  guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
  filter.setValue(ciImage, forKey: kCIInputImageKey)
  guard let outputImage = filter.outputImage else { return nil }
  let rep = NSCIImageRep(ciImage: outputImage)
  let newImage = NSImage(size: image.size)
  newImage.addRepresentation(rep)
  return newImage
}

// Shared split primary button used across detail toolbar and list empty state
struct SplitPrimaryMenuButton: View {
  let title: String
  let systemImage: String
  let primary: () -> Void
  let items: [SplitMenuItem]

  var body: some View {
    let h: CGFloat = 24
    HStack(spacing: 0) {
      Button(action: primary) {
        Label(title, systemImage: systemImage)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.primary)
          .padding(.horizontal, 12)
          .frame(height: h)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Rectangle()
        .fill(Color.secondary.opacity(0.25))
        .frame(width: 1, height: h - 8)
        .padding(.vertical, 4)

      ChevronMenuButton(items: items)
        .frame(width: h, height: h)
    }
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
    )
  }
}

struct SplitMenuItem: Identifiable {
  enum Kind {
    case action(title: String, systemImage: String? = nil, assetImage: String? = nil, disabled: Bool = false, run: () -> Void)
    case separator
    case submenu(title: String, systemImage: String? = nil, assetImage: String? = nil, items: [SplitMenuItem])
  }
  let id: String
  let kind: Kind

  init(id: String = UUID().uuidString, kind: Kind) {
    self.id = id
    self.kind = kind
  }
}

struct SplitMenuItemsView: View {
  let items: [SplitMenuItem]
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ForEach(items) { item in
      switch item.kind {
      case .separator:
        Divider()
      case .action(let title, let systemImage, let assetImage, let disabled, let run):
        Button(action: run) {
          if let asset = assetImage,
             let icon = menuAssetNSImage(
              named: asset,
              invertForDarkMode: asset == "ChatGPTIcon" && colorScheme == .dark
             )
          {
            Label {
              Text(title)
            } icon: {
              Image(nsImage: icon)
                .frame(width: 14, height: 14)
            }
          } else if let systemImage {
            Label(title, systemImage: systemImage)
          } else {
            Text(title)
          }
        }
        .disabled(disabled)
      case .submenu(let title, let systemImage, let assetImage, let children):
        Menu {
          SplitMenuItemsView(items: children)
        } label: {
          if let asset = assetImage,
             let icon = menuAssetNSImage(
              named: asset,
              invertForDarkMode: asset == "ChatGPTIcon" && colorScheme == .dark
             )
          {
            Label {
              Text(title)
            } icon: {
              Image(nsImage: icon)
                .frame(width: 14, height: 14)
            }
          } else if let systemImage {
            Label(title, systemImage: systemImage)
          } else {
            Text(title)
          }
        }
      }
    }
  }
}

struct ChevronMenuButton: NSViewRepresentable {
  let items: [SplitMenuItem]

  func makeCoordinator() -> Coordinator { Coordinator(items: items) }

  func makeNSView(context: Context) -> NSButton {
    let btn = NSButton(
      title: "", target: context.coordinator, action: #selector(Coordinator.openMenu(_:)))
    btn.isBordered = false
    btn.bezelStyle = .regularSquare
    if let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
      btn.image = img
    }
    btn.translatesAutoresizingMaskIntoConstraints = false
    return btn
  }

  func updateNSView(_ nsView: NSButton, context: Context) {
    context.coordinator.items = items
  }

  final class Coordinator: NSObject {
    var items: [SplitMenuItem]
    private var runs: [() -> Void] = []
    init(items: [SplitMenuItem]) { self.items = items }

    @objc func openMenu(_ sender: NSButton) {
      let menu = NSMenu()
      runs.removeAll(keepingCapacity: true)
      func build(_ items: [SplitMenuItem], into menu: NSMenu) {
        for item in items {
          switch item.kind {
          case .separator:
            menu.addItem(.separator())
          case .action(let title, let systemImage, let assetImage, let disabled, let run):
            let mi = NSMenuItem(
              title: title, action: #selector(Coordinator.fire(_:)), keyEquivalent: "")
            if let asset = assetImage,
               let img = menuAssetNSImage(
                named: asset,
                invertForDarkMode: asset == "ChatGPTIcon" && isDarkMode()
               )
            {
              mi.image = img
            } else if let systemImage, let img = menuSystemNSImage(named: systemImage) {
              mi.image = img
            }
            mi.tag = runs.count
            mi.target = self
            mi.isEnabled = !disabled
            menu.addItem(mi)
            runs.append(run)
          case .submenu(let title, let systemImage, let assetImage, let children):
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let asset = assetImage,
               let img = menuAssetNSImage(
                named: asset,
                invertForDarkMode: asset == "ChatGPTIcon" && isDarkMode()
               )
            {
              mi.image = img
            } else if let systemImage, let img = menuSystemNSImage(named: systemImage) {
              mi.image = img
            }
            let sub = NSMenu(title: title)
            build(children, into: sub)
            mi.submenu = sub
            menu.addItem(mi)
          }
        }
      }
      build(items, into: menu)
      let location = NSPoint(x: sender.bounds.midX, y: sender.bounds.maxY - 3)
      menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc func fire(_ sender: NSMenuItem) {
      let idx = sender.tag
      guard idx >= 0 && idx < runs.count else { return }
      runs[idx]()
    }

    private func isDarkMode() -> Bool {
      if let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
        return appearance == .darkAqua
      }
      return false
    }

  }
}
