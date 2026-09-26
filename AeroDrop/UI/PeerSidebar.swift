import SwiftUI

struct PeerSidebar: View {
    @ObservedObject var model: TransferViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            peerList
            Divider()
            footer
        }
        .frame(width: 224)
        .background(Theme.sidebarBackground)
    }

    private var header: some View {
        HStack(spacing: Theme.spacingSM) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
            Text("Devices")
                .font(.headline)
            Spacer()
            Text("\(model.peers.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Theme.hairline))
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingSM)
    }

    @ViewBuilder
    private var peerList: some View {
        if model.peers.isEmpty {
            emptyState
        } else {
            List(selection: selectionBinding) {
                ForEach(model.peers) { peer in
                    PeerRow(peer: peer)
                        .tag(peer)
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 34)
        }
    }

    private var selectionBinding: Binding<AeroPeerInfo?> {
        Binding(
            get: { model.selectedPeer },
            set: { model.selectedPeer = $0 }
        )
    }

    private var emptyState: some View {
        VStack(spacing: Theme.spacingSM) {
            Spacer()
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("Looking for devices")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Open AeroDrop on the other device, on the same Wi‑Fi network.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacingSM)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No devices found. Looking for devices on this network.")
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: Theme.spacingXS) {
            ServerStatusDot(state: model.serverState)
            Text(serverStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingSM)
    }

    private var serverStatusText: String {
        switch model.serverState {
        case .idle:                return "Idle"
        case .starting:            return "Starting…"
        case .running:             return "Receiving"
        case .failed(let message): return message
        }
    }
}

struct ServerStatusDot: View {
    let state: TransferViewModel.ServerState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 3)
                    .opacity(isBusy ? 1 : 0)
            )
            .animation(
                isBusy ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                value: isBusy
            )
            .accessibilityHidden(true)
    }

    private var isBusy: Bool { state == .starting }

    private var color: Color {
        switch state {
        case .running: return .green
        case .starting: return .yellow
        case .idle:    return .secondary
        case .failed:  return .red
        }
    }
}

struct PeerRow: View {
    let peer: AeroPeerInfo

    var body: some View {
        HStack(spacing: Theme.spacingSM) {
            Image(systemName: "iphone")
                .font(.system(size: 13))
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.surfaceHover))

            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(peer.endpoint)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(peer.name)
        .accessibilityValue(peer.isLinkLocalIPv6
                            ? "Connected over IPv6 at \(peer.host)"
                            : "Connected at \(peer.endpoint)")
        .accessibilityAddTraits(.isButton)
    }
}
