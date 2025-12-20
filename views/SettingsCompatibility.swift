import SwiftUI

extension View {
    @ViewBuilder
    func codmatePresentationSizingIfAvailable() -> some View {
        if #available(macOS 15.0, *) {
            self.presentationSizing(.automatic)
        } else {
            self
        }
    }

    @ViewBuilder
    func codmateNavigationSplitViewBalancedIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            self.navigationSplitViewStyle(.balanced)
        } else {
            self
        }
    }

    @ViewBuilder
    func codmateToolbarRemovingSidebarToggleIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            self.toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }

    @ViewBuilder
    func codmatePlainTextEditorStyleIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            self.textEditorStyle(.plain)
        } else {
            self
        }
    }
}

@available(macOS, introduced: 13.0, obsoleted: 14.0)
extension View {
    func onChange<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        _ action: @escaping (Value) -> Void
    ) -> some View {
        modifier(OnChangeCompatModifier(value: value, initial: initial, action: action))
    }

    func onChange<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        _ action: @escaping (Value, Value) -> Void
    ) -> some View {
        modifier(OnChangeCompatOldNewModifier(value: value, initial: initial, action: action))
    }
}

private struct OnChangeCompatModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: (Value) -> Void
    @State private var hasInitialized = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !hasInitialized else { return }
                hasInitialized = true
                if initial {
                    action(value)
                }
            }
            .onChange(of: value) { newValue in
                action(newValue)
            }
    }
}

private struct OnChangeCompatOldNewModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: (Value, Value) -> Void
    @State private var hasInitialized = false
    @State private var previousValue: Value?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !hasInitialized else { return }
                hasInitialized = true
                previousValue = value
                if initial {
                    action(value, value)
                }
            }
            .onChange(of: value) { newValue in
                let oldValue = previousValue ?? newValue
                previousValue = newValue
                action(oldValue, newValue)
            }
    }
}
