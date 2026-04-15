// PeerRowView.swift — AeroDrop  [Phase 3: UI Layer]
// A single discovered Android peer displayed in the sidebar list.
// Features: animated signal bars, hover glow, monospaced hostname display.

import SwiftUI

// ── Model ─────────────────────────────────────────────────────────────────────

struct AeroPeerInfo: Identifiable, Equatable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
}

// ── Signal Bars ───────────────────────────────────────────────────────────────

struct SignalBars: View {
    let strength: Int // 1–4  (derived from hash of host for demo)

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= strength
                          ? Color(red: 0.0, green: 1.0, blue: 0.7)
                          : Color.white.opacity(0.15))
                    .frame(width: 3, height: CGFloat(bar) * 3 + 2)
            }
        }
    }
}

// ── Peer Row ──────────────────────────────────────────────────────────────────

struct PeerRowView: View {
    let peer: AeroPeerInfo
    let onTap: () -> Void

    @State private var isHovered = false
    @State private var dotPhase: CGFloat = 0

    // Stable pseudo-signal-strength from the host string
    private var signalBars: Int {
        let h = peer.host.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return (h % 4) + 1
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // ── Device icon ──────────────────────────────────────────
                ZStack {
                    Circle()
                        .fill(Color(red: 0.0, green: 0.9, blue: 0.8).opacity(
                            isHovered ? 0.25 : 0.10))
                        .frame(width: 32, height: 32)
                    Image(systemName: "iphone")
                        .font(.system(size: 14))
                        .foregroundColor(Color(red: 0.0, green: 1.0, blue: 0.8))
                }

                // ── Name + host ──────────────────────────────────────────
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text("\(peer.host):\(peer.port, format: .number.grouping(.never))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                // ── Signal bars ──────────────────────────────────────────
                SignalBars(strength: signalBars)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered
                          ? Color(red: 0.0, green: 0.9, blue: 0.8).opacity(0.08)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

#Preview {
    ZStack {
        Color(red: 0.04, green: 0.04, blue: 0.10)
        VStack(spacing: 4) {
            PeerRowView(peer: AeroPeerInfo(
                id: UUID(), name: "Pixel 9 Pro – siluna",
                host: "192.168.1.42", port: 7770)) {}
            PeerRowView(peer: AeroPeerInfo(
                id: UUID(), name: "Galaxy S25 Ultra",
                host: "192.168.1.55", port: 7770)) {}
        }
        .padding()
    }
    .frame(width: 220, height: 140)
}
