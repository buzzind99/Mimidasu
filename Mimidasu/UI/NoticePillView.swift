import SwiftUI

/// Transient notice pill (e.g. "Text copied"): minimal hug-content capsule,
/// solid fill with contrasting text per tone (teal confirm, amber warning),
/// no icon or dismiss button. Slides in from the top like the toast stack;
/// auto-dismisses via `NoticeCenter`.
///
/// Renders only while its window is key. The center is one slot on `AppModel`,
/// so a notice raised while a second window is frontmost would otherwise be
/// drawn twice — once in the window the user is looking at and once behind it.
/// The gate lives here rather than at each host so a third window cannot mount
/// the pill and get that wrong. The floating panels (HUD, translation overlay)
/// are non-activating and never take key, so a notice raised from one still
/// confirms in the window they float over.
struct NoticePillView: View {
    var center: NoticeCenter

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack {
            if controlActiveState == .key, let message = center.message {
                let tokens = Theme.noticeTokens(for: center.tone)
                Text(message)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(tokens.fill)
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: center.message)
        .padding(.top, 12)
        .allowsHitTesting(false)
    }
}
