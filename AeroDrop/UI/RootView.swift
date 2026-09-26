import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @StateObject private var model = TransferViewModel()

    var body: some View {
        VStack(spacing: 0) {
            banner
            HStack(spacing: 0) {
                PeerSidebar(model: model)
                Divider()
                content
            }
            Divider()
            securityFooter
        }
        .frame(minWidth: 460, minHeight: 340)
        .onAppear { model.start() }
    }

    // ── Main content ────────────────────────────────────────────────────────

    @ViewBuilder
    private var content: some View {
        if let error = model.advertisementError {
            MessagePane(
                symbol: "exclamationmark.triangle",
                title: "Not discoverable",
                detail: "\(error). Other devices won’t be able to find this Mac.",
                tint: .orange
            )
        } else if case .failed(let reason) = model.serverState {
            MessagePane(
                symbol: "xmark.octagon",
                title: "Server unavailable",
                detail: reason,
                tint: .red
            )
        } else {
            ZStack(alignment: .top) {
                if model.queue.isEmpty {
                    DropTargetView(model: model)
                } else {
                    TransferQueueView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
                Task { await model.handleDrop(providers) }
                return true
            }
        }
    }

    // ── Notice banner ───────────────────────────────────────────────────────

    @ViewBuilder
    private var banner: some View {
        if let notice = model.notice {
            HStack(spacing: Theme.spacingSM) {
                Image(systemName: "info.circle.fill")
                Text(notice)
                    .font(.callout)
                Spacer()
                Button {
                    model.dismissNotice()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss message")
            }
            .padding(.horizontal, Theme.spacingMD)
            .padding(.vertical, Theme.spacingSM)
            .frame(maxWidth: .infinity)
            .background(.yellow.opacity(0.16))
            .overlay(alignment: .bottom) { Divider() }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // ── Footer ──────────────────────────────────────────────────────────────

    private var securityFooter: some View {
        HStack(spacing: Theme.spacingSM) {
            Image(systemName: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("End-to-end encrypted")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if !model.certFingerprint.isEmpty {
                Button {
                    copyFingerprint()
                } label: {
                    HStack(spacing: Theme.spacingXS) {
                        Text("Copy ID")
                            .font(.caption)
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy this device’s security fingerprint to verify a peer")
                .accessibilityLabel("Copy device security fingerprint")
            }
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingSM)
        .background(Theme.sidebarBackground)
    }

    private func copyFingerprint() {
        let formatted = Format.groupedFingerprint(model.certFingerprint)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(formatted, forType: .string)
    }
}

struct MessagePane: View {
    let symbol: String
    let title: String
    let detail: String
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: Theme.spacingSM) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.spacingLG)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}
