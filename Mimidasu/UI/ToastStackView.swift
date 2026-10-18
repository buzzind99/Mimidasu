import SwiftUI

/// Toast stack overlay: cards stacked newest first,
/// `move` + `opacity` transitions, yellow/red/info treatments per class,
/// × while the card is closable, action link on persistent cards (300pt,
/// corner 14, themed background/border/icon tint).
struct ToastStackView: View {
    var center: ToastCenter

    var body: some View {
        VStack(spacing: 10) {
            ForEach(center.toasts) { toast in
                ToastCard(toast: toast) {
                    center.dismiss(key: toast.key)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: center.toasts)
    }
}

/// One toast card: severity icon, bold title, secondary body, optional
/// progress bar (the bulk job), optional fix action (persistent cards),
/// optional × while the card is closable.
private struct ToastCard: View {
    let toast: ToastCenter.Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(toast.body)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                if let progress = toast.progress {
                    ProgressView(
                        value: Double(progress.done),
                        total: Double(max(progress.total, 1))
                    )
                    .progressViewStyle(.linear)
                    .tint(Theme.accentPink)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
                if let action = toast.action {
                    Button(action.label) {
                        action.handler()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(actionIsCancel ? Theme.secondaryText : Theme.accentPink)
                    .buttonStyle(.plain)
                    // pointerStyle only applies on hover-tracking views; bare
                    // plain-style buttons need this no-op onHover to activate it.
                    .onHover { _ in }
                    .pointerStyle(.link)
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)

            if toast.isClosable {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.primaryText.opacity(0.45))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.tileFill))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 300)
        .cardSurface(
            fill: Theme.toastBackground, stroke: borderColor,
            shadow: .black.opacity(0.4), shadowRadius: 18, shadowY: 8
        )
    }

    /// The info class's icon follows its payload: a spinner while a run
    /// reports progress, the warning triangle on a finished failure summary
    /// (it carries the retry action), the success check on an all-success
    /// summary. The warning classes keep their severity glyphs.
    @ViewBuilder
    private var icon: some View {
        if toast.style == .info {
            if toast.progress != nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
            } else if toast.action != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.dotYellow)
                    .padding(.top, 2)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.dotGreen)
                    .padding(.top, 2)
            }
        } else {
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundStyle(iconTint)
                .padding(.top, 2)
        }
    }

    private var isRedClass: Bool {
        toast.style == .redPersistent
    }

    private var iconName: String {
        isRedClass ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
    }

    private var iconTint: Color {
        isRedClass ? Theme.toastRedIcon : Theme.dotYellow
    }

    /// A progress card's only action is its Cancel — the quiet exit reads
    /// secondary; every other action keeps the accent treatment.
    private var actionIsCancel: Bool {
        toast.style == .info && toast.progress != nil
    }

    private var borderColor: Color {
        switch toast.style {
        case .redPersistent: Theme.toastRedBorder
        case .info: Theme.cardStroke
        case .yellowAuto, .yellowPersistent: Theme.toastYellowBorder
        }
    }
}
