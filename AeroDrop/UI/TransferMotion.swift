import SwiftUI
import AppKit
import Combine

/// Event ripples, the wave-front progress bar, and the idle water surface.
///
/// Everything here is drawn with `Canvas` and driven by `TimelineView(.animation)`
/// so it stays on the GPU and costs nothing when nothing is moving. The whole
/// file is decoration: if the system asks for reduced motion, every view here
/// renders its settled state instead of animating.

// MARK: - Ripple events

/// A ripple is a set of concentric rings expanding from a point, like a stone
/// hitting water. Three concentric rings with staggered starts read as a single
/// splash; one ring reads as a loading spinner.
///
/// There is deliberately no per-direction case. Sending and receiving fire the
/// same event, so the only thing telling them apart is the arrow and the verb in
/// the row itself.
enum RippleStyle {
    case start
    case complete

    var duration: TimeInterval {
        switch self {
        case .start:    return 1.0
        case .complete: return 1.7
        }
    }

    /// Per-ring delay, so the rings chase each other outward.
    var delays: [TimeInterval] { [0, 0.16, 0.34] }

    var maxRadius: CGFloat {
        switch self {
        case .start:    return 120
        case .complete: return 300
        }
    }

    var opacity: Double {
        switch self {
        case .start:    return 0.4
        case .complete: return 0.75
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .start:    return 1.5
        case .complete: return 2.5
        }
    }

    var color: Color {
        switch self {
        case .start:           return TransferStyle.accent
        case .complete:        return .green
        }
    }
}

/// Owns live ripples and expires them. Shared by the panel so an event raised
/// anywhere in the UI ripples everywhere at once.
@MainActor
final class RippleCenter: ObservableObject {
    static let shared = RippleCenter()

    struct Ripple: Identifiable {
        let id = UUID()
        let origin: UnitPoint
        let born: Date
        let style: RippleStyle
    }

    @Published private(set) var ripples: [Ripple] = []

    func emit(at origin: UnitPoint, style: RippleStyle) {
        prune()
        // Two splashes landing on the same pixel should not double the opacity.
        guard !ripples.contains(where: {
            $0.origin == origin && $0.style == style && Date().timeIntervalSince($0.born) < 0.25
        }) else { return }
        ripples.append(Ripple(origin: origin, born: Date(), style: style))
    }

    private func prune() {
        ripples.removeAll { Date().timeIntervalSince($0.born) > 2.0 }
    }
}

/// Draws every live ripple. Place as a background/overlay that fills the area
/// you want the water to spread across.
struct RippleLayer: View {
    @ObservedObject var center: RippleCenter = .shared

    var body: some View {
        // A TimelineView(.animation) schedule redraws every frame forever, so it
        // is only mounted while a ripple is actually alive. Idle, this costs
        // nothing -- which matters for an app that sits in the menu bar.
        if center.ripples.isEmpty {
            Canvas { _, _ in }
        } else {
            timeline
        }
    }

    private var timeline: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let now = timeline.date
                for ripple in center.ripples {
                    drawRipple(ripple, at: now, in: &ctx, size: size)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawRipple(_ ripple: RippleCenter.Ripple, at now: Date, in ctx: inout GraphicsContext, size: CGSize) {
        let style = ripple.style
        let age = now.timeIntervalSince(ripple.born)
        guard age >= 0, age < style.duration else { return }

        let center = CGPoint(x: ripple.origin.x * size.width, y: ripple.origin.y * size.height)

        // The impact: a soft bloom at the point of contact, gone in a moment.
        let impactT = min(1, age / 0.45)
        if impactT < 1 {
            let radius = 26 + 46 * easeOut(impactT)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [style.color.opacity(0.5 * (1 - impactT)), .clear]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
        }

        for delay in style.delays {
            let rt = (age - delay) / (style.duration - delay)
            guard rt > 0, rt <= 1 else { continue }
            let radius = style.maxRadius * easeOut(rt)
            let alpha = pow(1 - rt, 1.7) * style.opacity
            guard alpha > 0.004, radius > 0.5 else { continue }
            let rect = CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2)
            ctx.stroke(
                Path(ellipseIn: rect),
                with: .color(style.color.opacity(alpha)),
                lineWidth: max(0.5, style.lineWidth * (1 - rt * 0.55))
            )
        }
    }

    private func easeOut(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }
}

// MARK: - Wave progress

/// A progress bar whose leading edge is an animated water surface.
///
/// The metaphor is literal: the bar is a tube, the fill is water, and the top of
/// the water is a travelling sine wave. Chosen over a plain rectangle because a
/// transfer is the one thing in this UI worth watching.
struct WaveProgressBar: View {
    let progress: Double
    var isActive: Bool = false
    var height: CGFloat = 8
    var showsGlow: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { max(0, min(1, progress)) }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                render(&ctx, size: size, t: t)
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : TransferStyle.progress, value: clamped)
        .accessibilityHidden(true)
    }

    private func render(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let track = Path(roundedRect: CGRect(origin: .zero, size: size),
                         cornerRadius: size.height / 2)
        ctx.fill(track, with: .color(Theme.hairline))

        let surfaceY = size.height * CGFloat(1 - clamped)
        let motion = t > 0

        guard surfaceY < size.height - 0.5 else {
            // Still empty: a travelling highlight so an active transfer reads
            // as "working" rather than "stalled".
            if isActive && motion {
                let sweep = CGFloat(t.truncatingRemainder(dividingBy: 1.6) / 1.6)
                let w = size.width * 0.28
                let x = -w + sweep * (size.width + w)
                let r = Path(roundedRect: CGRect(x: x, y: 1, width: w, height: size.height - 2),
                             cornerRadius: (size.height - 2) / 2)
                ctx.fill(r, with: .color(TransferStyle.accent.opacity(0.35)))
            }
            return
        }

        let steps = max(2, Int(size.width / 2))

        // The water: filled from the bottom, its top edge a travelling wave that
        // is damped to nothing at both walls so it meets the tube cleanly.
        func waveY(at u: CGFloat) -> CGFloat {
            guard motion else { return surfaceY }
            let envelope = sin(u * .pi)
            return surfaceY + sin(u * .pi * 3.1 + t * 2.6) * 1.6 * envelope
        }

        var water = Path()
        water.move(to: CGPoint(x: 0, y: size.height))
        for step in 0...steps {
            let u = CGFloat(step) / CGFloat(steps)
            water.addLine(to: CGPoint(x: size.width * u, y: waveY(at: u)))
        }
        water.addLine(to: CGPoint(x: size.width, y: size.height))
        water.closeSubpath()

        if isActive && showsGlow {
            // A soft bloom sitting on the waterline. Drawn as a gradient band
            // rather than a blurred copy of the shape, so it needs no filter and
            // stays cheap enough to run every frame.
            let band = CGRect(x: 0, y: max(0, surfaceY - 6), width: size.width, height: 8)
            ctx.fill(
                Path(roundedRect: band, cornerRadius: 4),
                with: .linearGradient(
                    Gradient(colors: [.clear, TransferStyle.accent.opacity(0.32)]),
                    startPoint: CGPoint(x: 0, y: band.minY),
                    endPoint: CGPoint(x: 0, y: band.maxY)
                )
            )
        }

        ctx.fill(water, with: .linearGradient(
            Gradient(colors: [TransferStyle.accent.opacity(0.75), TransferStyle.accent]),
            startPoint: CGPoint(x: 0, y: surfaceY),
            endPoint: CGPoint(x: 0, y: size.height)
        ))

        guard motion else { return }
        var crest = Path()
        for step in 0...steps {
            let u = CGFloat(step) / CGFloat(steps)
            let y = waveY(at: u)
            if step == 0 { crest.move(to: CGPoint(x: size.width * u, y: y)) }
            else { crest.addLine(to: CGPoint(x: size.width * u, y: y)) }
        }
        ctx.stroke(crest, with: .color(.white.opacity(0.5)), lineWidth: 1)
    }
}

// MARK: - Ambient surface

/// Two slow, overlapping swells for the idle drop zone.
///
/// This is the resting state: nothing is happening, so the water is nearly
/// still. It exists so the empty panel doesn't feel like a dead form — the same
/// reason a still pool reads as water rather than a hole in the screen.
struct WaterSurface: View {
    /// Rises with activity so a busy app looks like a choppier sea.
    var intensity: Double = 0
    var tint: Color = TransferStyle.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let amp = 3.0 + 7.0 * max(0, min(1, intensity))

                for (index, phase) in [0.0, 1.7, 3.4].enumerated() {
                    var path = Path()
                    let steps = max(2, Int(size.width / 3))
                    let indexF = Double(index)
                    let baseY = size.height * CGFloat(0.30 + 0.16 * indexF)
                    let speed = 0.7 + 0.25 * indexF
                    for step in 0...steps {
                        let u = Double(step) / Double(steps)
                        let envelope = sin(u * .pi)
                        let swell = sin(u * .pi * 2 + t * speed + phase) * amp * envelope
                        let x = size.width * CGFloat(u)
                        let y = baseY + CGFloat(swell)
                        if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    ctx.stroke(path, with: .color(tint.opacity(0.20 - 0.05 * indexF)),
                               lineWidth: 1.2)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
