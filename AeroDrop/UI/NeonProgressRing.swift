// NeonProgressRing.swift — AeroDrop  [Phase 3: UI Layer]
// Animatable neon progress ring with stacked glow layers.
// Uses AnimatableData so SwiftUI spring-interpolates the trim fraction.
// Colour shifts cyan → magenta as progress increases.

import SwiftUI

// ── Ring Shape ────────────────────────────────────────────────────────────────

struct ArcRing: Shape {
    var progress: Double // 0.0 – 1.0

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center:     CGPoint(x: rect.midX, y: rect.midY),
                 radius:     rect.width / 2,
                 startAngle: .degrees(-90),
                 endAngle:   .degrees(-90 + 360 * progress),
                 clockwise:  false)
        return p
    }
}

// ── Neon Progress Ring ────────────────────────────────────────────────────────

struct NeonProgressRing: View {
    var progress: Double   // 0.0 – 1.0
    var speedMbps: Double
    var size: CGFloat = 180

    @State private var pulseScale: CGFloat = 1.0

    // Colour cycles from cyan → magenta as the transfer progresses
    private var ringColor: Color {
        let r = progress
        let g = 1.0 - progress * 0.9
        let b = 1.0 - progress * 0.2
        return Color(red: r, green: g, blue: b)
    }

    var body: some View {
        ZStack {
            // ── Track ────────────────────────────────────────────────────
            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: 10)
                .frame(width: size, height: size)

            // ── Glow bloom (outermost) ───────────────────────────────────
            ArcRing(progress: progress)
                .stroke(ringColor.opacity(0.15), style: StrokeStyle(lineWidth: 24, lineCap: .round))
                .frame(width: size, height: size)
                .blur(radius: 10)

            // ── Mid glow ─────────────────────────────────────────────────
            ArcRing(progress: progress)
                .stroke(ringColor.opacity(0.4), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .frame(width: size, height: size)
                .blur(radius: 4)

            // ── Crisp inner ring ─────────────────────────────────────────
            ArcRing(progress: progress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: size, height: size)

            // ── Centre readout ───────────────────────────────────────────
            VStack(spacing: 4) {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: size * 0.18, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                if speedMbps > 0 {
                    Text(String(format: "%.1f MB/s", speedMbps))
                        .font(.system(size: size * 0.08, design: .monospaced))
                        .foregroundColor(ringColor.opacity(0.85))
                }
            }

            // ── Tip dot (leading edge of the arc) ────────────────────────
            if progress > 0.01 {
                Circle()
                    .fill(ringColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: ringColor, radius: 6)
                    .offset(y: -(size / 2))
                    .rotationEffect(.degrees(-90 + 360 * progress))
            }
        }
        // Pulse animation while active
        .scaleEffect(pulseScale)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulseScale = 1.03
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: progress)
    }
}

#Preview {
    ZStack {
        Color(red: 0.04, green: 0.04, blue: 0.10)
        NeonProgressRing(progress: 0.63, speedMbps: 42.7, size: 180)
    }
    .frame(width: 300, height: 300)
}
