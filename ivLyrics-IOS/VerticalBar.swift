import SwiftUI

// iPhone Duo lays toolbar, navigation and tab bar items out in a vertical bar under the status
// bar and camera: on the outer display, and on the inner display in landscape. The system only
// moves the bars that navigation containers manage, and only for apps built with the iOS 27.1
// SDK (SwiftUI 8.0.85). A hand-drawn button stays wherever the layout puts it, which on the
// outer display is the clipped top edge beside that bar.
// https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo
// https://developer.apple.com/videos/play/tech-talks/111462/
//
// Older SDKs, the iOS 27.0 one included, compile the plain layout.

/// Hosts the root in a navigation container so the system can lay its bar out vertically.
/// The navigation bar is hidden wherever the system keeps horizontal bars (see
/// `verticalBarSettingsItem`), so those layouts stay as they were.
struct VerticalBarHost<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
#if canImport(SwiftUI, _version: 8.0.85)
        // Fixed for the lifetime of the process, so the root never changes identity.
        if #available(iOS 27.1, *) {
            NavigationStack {
                content
            }
        } else {
            content
        }
#else
        content
#endif
    }
}

extension View {
    /// Puts the settings button in the system vertical bar wherever the system lays bars out
    /// vertically, and reports through `placed` whether it does so the caller drops its own
    /// button. Apply it inside `VerticalBarHost`.
    ///
    /// - Parameters:
    ///   - allowed: false keeps the horizontal layout (and its own button) in this pose.
    ///   - hidden: hides the item while an overlay covers the page; it stays `placed`.
    func verticalBarSettingsItem(
        title: String,
        allowed: Bool,
        hidden: Bool,
        placed: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        modifier(VerticalBarSettingsItem(
            title: title,
            allowed: allowed,
            hidden: hidden,
            placed: placed,
            action: action
        ))
    }
}

private struct VerticalBarSettingsItem: ViewModifier {
    var title: String
    var allowed: Bool
    var hidden: Bool
    @Binding var placed: Bool
    var action: () -> Void

    func body(content: Content) -> some View {
#if canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            content.modifier(VerticalBarSettingsToolbar(
                title: title,
                allowed: allowed,
                hidden: hidden,
                placed: $placed,
                action: action
            ))
        } else {
            content
        }
#else
        content
#endif
    }
}

#if canImport(SwiftUI, _version: 8.0.85)
@available(iOS 27.1, *)
private struct VerticalBarSettingsToolbar: ViewModifier {
    /// nil on hardware, size classes and poses that never use a vertical bar.
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge
    var title: String
    var allowed: Bool
    var hidden: Bool
    @Binding var placed: Bool
    var action: () -> Void

    func body(content: Content) -> some View {
        let vertical = allowed && toolbarVerticalEdge != nil
        content
            .toolbar {
                if vertical && !hidden {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: action) {
                            // The title names the item in the overflow menu and for VoiceOver.
                            Label(title, systemImage: "ellipsis")
                        }
                        .accessibilityIdentifier("player.settings.verticalBar")
                    }
                }
            }
            .toolbar(vertical ? .visible : .hidden, for: .navigationBar)
            .onChange(of: vertical, initial: true) { _, value in
                placed = value
            }
    }
}
#endif
