import AppKit
import SwiftUI

@ViewBuilder
func openInEditorMenu(
  editors: [EditorApp],
  onOpen: @escaping (EditorApp) -> Void
) -> some View {
  if !editors.isEmpty {
    Menu {
      ForEach(editors) { editor in
        Button {
          onOpen(editor)
        } label: {
          Label {
            Text(editor.title)
          } icon: {
            if let icon = editor.menuIcon {
              Image(nsImage: icon)
                .frame(width: 14, height: 14)
            } else {
              Image(systemName: "chevron.left.forwardslash.chevron.right")
            }
          }
        }
      }
    } label: {
      Label("Open in", systemImage: "arrow.up.forward.app")
    }
  }
}
