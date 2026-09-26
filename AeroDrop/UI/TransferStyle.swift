import SwiftUI
import AppKit

/// The single source of truth for how a transfer is presented.
///
/// Sending and receiving deliberately share every decision in this file. The
/// only intended difference between the two directions is the arrow and the
/// verb — same tint, same progress bar, same animations, same row layout. If
/// you add a visual treatment for one direction it applies to both for free.
enum TransferStyle {

    // MARK: - Direction

    static func arrow(for item: TransferItem) -> String {
        item.isOutgoing ? "arrow.up.to.line" : "arrow.down.to.line"
    }

    static func verb(for item: TransferItem) -> String {
        item.isOutgoing ? "Sending" : "Receiving"
    }

    static func preposition(for item: TransferItem) -> String {
        item.isOutgoing ? "to" : "from"
    }

    /// One accent colour for both directions. Direction is carried by the arrow
    /// and the verb, never by hue, so the two never drift apart.
    static let accent = Color.accentColor

    // MARK: - Motion

    /// Structural changes: a row appearing, leaving, or changing state.
    static let structural = Animation.spring(duration: 0.35, bounce: 0.18)

    /// Progress ticks arrive every ~100 ms, so this is short and eased out —
    /// long enough to smooth the steps, short enough not to lag behind.
    static let progress = Animation.easeOut(duration: 0.22)

    /// The one-shot acknowledgement when a transfer lands.
    static let celebrate = Animation.spring(duration: 0.5, bounce: 0.35)
}

/// A progress bar that animates toward its value instead of snapping.
///
/// Used for both the per-file bar and the overall queue bar so a transfer looks
/// the same wherever it appears.
struct TransferProgressBar: View {
    let progress: Double
    /// An active transfer that has not reported a fraction yet gets a moving
    /// highlight rather than a bar stuck at zero, which reads as "broken".
    var isActive: Bool = false
    var height: CGFloat = 4

    private var clamped: Double { max(0, min(1, progress)) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.hairline)

                Capsule(style: .continuous)
                    .fill(TransferStyle.accent)
                    .frame(width: geo.size.width * clamped)
                    .opacity(isActive && clamped == 0 ? 0.35 : 1)

                if isActive && clamped == 0 {
                    Capsule(style: .continuous)
                        .fill(TransferStyle.accent)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: indeterminateOffset(in: geo.size.width))
                        .opacity(0.8)
                }
            }
        }
        .frame(height: height)
        .animation(TransferStyle.progress, value: clamped)
        .accessibilityHidden(true)
    }

    private func indeterminateOffset(in width: CGFloat) -> CGFloat {
        let span = width * 0.7
        return -span + (Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4) * (span * 2)
    }
}

/// The direction marker shown on every transfer row and in the summary.
struct DirectionGlyph: View {
    let item: TransferItem
    var size: CGFloat = 12
    var isProminent: Bool = false

    var body: some View {
        Image(systemName: TransferStyle.arrow(for: item))
            .font(.system(size: size, weight: isProminent ? .semibold : .medium))
            .foregroundStyle(isProminent ? AnyShapeStyle(TransferStyle.accent) : AnyShapeStyle(.secondary))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

/// A short, self-animating acknowledgement shown when a file finishes.
///
/// Deliberately restrained: a tint wash that fades out plus a single bounce on
/// the checkmark. Anything more fights the user when a queue of twenty items
/// completes in a row.
struct CompletionFlash: View {
    let isVisible: Bool

    @State private var opacity: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(Color.green.opacity(0.16))
            .opacity(opacity)
            .allowsHitTesting(false)
            .onChange(of: isVisible) { _, visible in
                if visible {
                    withAnimation(.easeOut(duration: 0.12)) { opacity = 1 }
                    withAnimation(.easeIn(duration: 0.5).delay(0.35)) { opacity = 0 }
                } else {
                    opacity = 0
                }
            }
    }
}
