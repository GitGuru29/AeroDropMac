// DropZoneView.swift — AeroDrop  [Phase 3: UI Layer]
// Cyberpunk glassmorphic drop zone.
// Canvas GPU-animated grid background, neon progress ring, peer sidebar.

import SwiftUI
import Combine
import UniformTypeIdentifiers

// ── Transfer State ────────────────────────────────────────────────────────────

enum TransferState: Equatable {
    case idle
    case sending(filename: String, progress: Double, speedMbps: Double)
    case receiving(filename: String, progress: Double, speedMbps: Double)
    case success(filename: String)
    case failed(reason: String)

    var isActive: Bool {
        switch self {
        case .sending, .receiving: return true
        default:                   return false
        }
    }
}

// ── ViewModel ─────────────────────────────────────────────────────────────────

@MainActor
final class DropZoneViewModel: ObservableObject {
    @Published var peers: [AeroPeerInfo]         = []
    @Published var transferState: TransferState  = .idle
    @Published var selectedPeer: AeroPeerInfo?   = nil
    @Published var isDropTargeted                = false
    @Published var certFingerprint: String       = ""

    private let server  = BridgeServer.shared()
    private let bonjour = BonjourService.shared

    func onAppear() {
        certFingerprint = server.certFingerprint()

        server.incomingProgressHandler = { [weak self] p in
            guard let self else { return }
            self.transferState = .receiving(
                filename:  p.filename,
                progress:  p.fraction,
                speedMbps: p.speedMbps
            )
        }
        server.incomingCompletionHandler = { [weak self] success, err in
            guard let self else { return }
            if success, case .receiving(let fn, _, _) = self.transferState {
                self.transferState = .success(filename: fn)
            } else if !success {
                self.transferState = .failed(reason: err ?? "Unknown error")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.transferState = .idle
            }
        }

        _ = server.startServer()
        bonjour.startAdvertising()
        injectDemoPeers()
    }

    func onDisappear() {
        server.stopServer()
        bonjour.stopAdvertising()
    }

    func dropFiles(_ urls: [URL]) {
        guard let peer = selectedPeer, let first = urls.first else { return }
        let filename = first.lastPathComponent

        server.sendFile(
            atPath: first.path,
            toHost: peer.host,
            port:   Int32(peer.port),
            progress: { [weak self] p in
                guard let self else { return }
                self.transferState = .sending(
                    filename:  filename,
                    progress:  p.fraction,
                    speedMbps: p.speedMbps
                )
            },
            completion: { [weak self] success, err in
                guard let self else { return }
                self.transferState = success
                    ? .success(filename: filename)
                    : .failed(reason: err ?? "Unknown error")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.transferState = .idle
                }
            }
        )
    }

    // Placeholder peers for UI development (replaced by real NsdManager data)
    private func injectDemoPeers() {
        peers = [
            AeroPeerInfo(id: UUID(), name: "Pixel 9 Pro – siluna",
                         host: "192.168.1.42", port: 7770),
            AeroPeerInfo(id: UUID(), name: "Galaxy S25 Ultra",
                         host: "192.168.1.55", port: 7770),
        ]
        selectedPeer = peers.first
    }
}

// ── Animated Grid Background ──────────────────────────────────────────────────

struct CyberpunkGridBackground: View {
    let isActive: Bool

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t       = tl.date.timeIntervalSinceReferenceDate
                let spacing: CGFloat = 36
                let speed: CGFloat   = isActive ? 24 : 8
                let offset  = CGFloat(t) * speed

                let cyan    = Color(red: 0.0, green: 0.9, blue: 1.0).opacity(0.12)
                let magenta = Color(red: 1.0, green: 0.0, blue: 0.8).opacity(0.06)

                // Scrolling vertical lines
                var x = offset.truncatingRemainder(dividingBy: spacing * 2) - spacing * 2
                while x < size.width + spacing * 2 {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(path, with: .color(cyan), lineWidth: 0.5)
                    x += spacing
                }

                // Static horizontal lines
                var y: CGFloat = 0
                while y < size.height {
                    var path2 = Path()
                    path2.move(to: CGPoint(x: 0, y: y))
                    path2.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(path2, with: .color(magenta), lineWidth: 0.5)
                    y += spacing
                }

                // Corner bracket accents
                let accent: CGFloat = 20
                let accentColor = Color(red: 0.0, green: 1.0, blue: 0.8).opacity(0.5)
                let corners: [(CGPoint, CGPoint, CGPoint)] = [
                    (CGPoint(x: 0,          y: 0),           CGPoint(x: accent,              y: 0),           CGPoint(x: 0,          y: accent)),
                    (CGPoint(x: size.width, y: 0),           CGPoint(x: size.width - accent,  y: 0),           CGPoint(x: size.width, y: accent)),
                    (CGPoint(x: 0,          y: size.height), CGPoint(x: accent,              y: size.height),  CGPoint(x: 0,          y: size.height - accent)),
                    (CGPoint(x: size.width, y: size.height), CGPoint(x: size.width - accent,  y: size.height), CGPoint(x: size.width, y: size.height - accent)),
                ]
                for (origin, h, v) in corners {
                    var p = Path()
                    p.move(to: origin); p.addLine(to: h)
                    p.move(to: origin); p.addLine(to: v)
                    ctx.stroke(p, with: .color(accentColor), lineWidth: 1.5)
                }
            }
        }
    }
}

// ── Drop Zone View ────────────────────────────────────────────────────────────

struct DropZoneView: View {
    @StateObject private var vm = DropZoneViewModel()

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.10).ignoresSafeArea()

            CyberpunkGridBackground(isActive: vm.transferState.isActive)
                .ignoresSafeArea()

            // Radial glow pulses while a transfer is active
            if vm.transferState.isActive {
                RadialGradient(
                    colors: [Color(red: 0, green: 0.9, blue: 1).opacity(0.15), .clear],
                    center: .center, startRadius: 0, endRadius: 300
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                           value: vm.transferState.isActive)
            }

            HStack(spacing: 16) {
                peerPanel
                mainDropZone
            }
            .padding(20)
        }
        .onAppear    { vm.onAppear()    }
        .onDisappear { vm.onDisappear() }
        .frame(width: 560, height: 380)
    }

    // ── Peer sidebar ──────────────────────────────────────────────────────────

    var peerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(Color(red: 0.0, green: 0.9, blue: 0.8))
                Text("NEARBY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 0.0, green: 0.9, blue: 0.8))
                Spacer()
                // Live registration indicator
                Circle()
                    .fill(BonjourService.shared.isAdvertising
                          ? Color(red: 0.0, green: 1.0, blue: 0.6)
                          : Color.gray)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 4)

            Divider().background(Color.white.opacity(0.1))

            if vm.peers.isEmpty {
                Text("Scanning local network…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.top, 8)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(vm.peers) { peer in
                            PeerRowView(peer: peer) { vm.selectedPeer = peer }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(
                                            vm.selectedPeer?.id == peer.id
                                                ? Color(red: 0.0, green: 0.9, blue: 0.8).opacity(0.7)
                                                : Color.clear,
                                            lineWidth: 1.5
                                        )
                                )
                        }
                    }
                }
            }

            Spacer()

            Text("🔑 \(vm.certFingerprint.prefix(23))…")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.25))
                .lineLimit(1)
        }
        .padding(14)
        .frame(width: 200)
        .background(.ultraThinMaterial.opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // ── Main drop zone card ───────────────────────────────────────────────────

    var mainDropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(
                            vm.isDropTargeted
                                ? Color(red: 0.0, green: 1.0, blue: 0.8).opacity(0.8)
                                : Color.white.opacity(0.12),
                            lineWidth: vm.isDropTargeted ? 2 : 1
                        )
                )

            // Swift does not allow associated-value bindings in OR'd case patterns
            switch vm.transferState {
            case .idle:
                idleContent
            case .sending(let fn, let p, let spd):
                activeTransferContent(filename: fn, progress: p,
                                      speed: spd, direction: "↑ SENDING")
            case .receiving(let fn, let p, let spd):
                activeTransferContent(filename: fn, progress: p,
                                      speed: spd, direction: "↓ RECEIVING")
            case .success(let fn):
                successContent(filename: fn)
            case .failed(let reason):
                failedContent(reason: reason)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(vm.isDropTargeted ? 0.98 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7),
                   value: vm.isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $vm.isDropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(
                        forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                        urls.append(url)
                    }
                }
                vm.dropFiles(urls)
            }
            return true
        }
    }

    // ── State content views ───────────────────────────────────────────────────

    var idleContent: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.0, green: 0.9, blue: 0.8).opacity(0.08))
                    .frame(width: 86, height: 86)
                Circle()
                    .stroke(Color(red: 0.0, green: 0.9, blue: 0.8).opacity(0.2), lineWidth: 1)
                    .frame(width: 86, height: 86)
                Image(systemName: "arrow.up.doc.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.0, green: 1.0, blue: 0.9),
                                     Color(red: 0.6, green: 0.0, blue: 1.0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }

            VStack(spacing: 6) {
                if let peer = vm.selectedPeer {
                    Text("Drop files to send to")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                    Text(peer.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text("Select a device →")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                    Text("No peer selected")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.3))
                }
            }

            Text("TLS 1.3  ·  AES-256-GCM  ·  No cloud")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(red: 0.0, green: 0.8, blue: 0.6).opacity(0.6))
        }
    }

    func activeTransferContent(filename: String, progress: Double,
                               speed: Double, direction: String) -> some View {
        VStack(spacing: 14) {
            Text(direction)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Color(red: 0.0, green: 1.0, blue: 0.8))
                .tracking(3)
            NeonProgressRing(progress: progress, speedMbps: speed, size: 160)
            Text(filename)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240)
        }
    }

    func successContent(filename: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(Color(red: 0.0, green: 1.0, blue: 0.7))
                .shadow(color: Color(red: 0.0, green: 1.0, blue: 0.7).opacity(0.7), radius: 12)
            Text("Transfer Complete")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            Text(filename)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    func failedContent(reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(Color(red: 1.0, green: 0.3, blue: 0.4))
                .shadow(color: Color(red: 1.0, green: 0.2, blue: 0.3).opacity(0.6), radius: 10)
            Text("Transfer Failed")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            Text(reason)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
    }
}

#Preview {
    DropZoneView()
}
