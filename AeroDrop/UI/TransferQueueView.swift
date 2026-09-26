import SwiftUI

struct TransferQueueView: View {
    @ObservedObject var model: TransferViewModel

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            list
            if model.hasFinishedItems {
                Divider()
                footer
            }
        }
        .background(Theme.surface)
    }

    // ── Summary ─────────────────────────────────────────────────────────────

    /// Mirrors the sending and receiving cases through one description so the
    /// two can never diverge: the same three lines, the same bar, the same
    /// fields, regardless of direction.
    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            HStack(spacing: Theme.spacingSM) {
                Text(summaryTitle)
                    .font(.headline)
                    .contentTransition(.opacity)

                Spacer()

                if let active = model.activeItem {
                    DirectionGlyph(item: active, size: 13, isProminent: true)
                        .transition(.scale.combined(with: .opacity))
                } else if model.isTransferring {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }

            TransferProgressBar(
                progress: model.overallProgress,
                isActive: model.isTransferring
            )
            .accessibilityElement()
            .accessibilityLabel("Overall progress")
            .accessibilityValue("\(Int(model.overallProgress * 100)) percent")

            if let active = model.activeItem {
                activeLine(active)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if model.queue.isEmpty {
                Text("Nothing in the queue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingMD)
        .animation(TransferStyle.structural, value: model.activeItem?.id)
    }

    private func activeLine(_ active: TransferItem) -> some View {
        HStack(spacing: Theme.spacingXS) {
            Text("\(TransferStyle.verb(for: active)) \(active.filename)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(Format.throughput(active.status.bytesPerSecond))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .layoutPriority(1)

            if let remaining = active.estimatedTimeRemaining {
                Text(Format.duration(remaining))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
            }
        }
    }

    private var summaryTitle: String {
        let total = model.queue.count
        guard total > 0 else { return "Transfers" }

        if let active = model.activeItem {
            return "\(TransferStyle.verb(for: active)) \(total) item\(total == 1 ? "" : "s")"
        }
        if model.hasFinishedItems { return "\(total) item\(total == 1 ? "" : "s")" }
        return "Queued — \(total) item\(total == 1 ? "" : "s")"
    }

    // ── List ────────────────────────────────────────────────────────────────

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.queue) { item in
                        TransferRow(item: item) { model.remove(item) }
                            .id(item.id)
                            // Rows animate in and out instead of popping. The
                            // view model owns the mutation timing, so the
                            // transition here is what sells it.
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.96))
                            ))
                        if item.id != model.queue.last?.id {
                            Divider().padding(.leading, Theme.spacingMD)
                        }
                    }
                }
            }
            // Keep whatever is moving on screen, whichever direction it is going.
            .onChange(of: model.activeItem?.id) { _, id in
                guard let id else { return }
                withAnimation(TransferStyle.structural) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Clear Finished") { model.clearFinished() }
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingSM)
    }
}

struct TransferRow: View {
    let item: TransferItem
    let onRemove: () -> Void

    @State private var isHoveringRemove = false
    @State private var isFlashing = false

    private var isTerminal: Bool { item.status.isTerminal }

    var body: some View {
        HStack(spacing: Theme.spacingSM) {
            statusIcon
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.spacingXS) {
                    // The direction cue lives on every row, so inbound and
                    // outbound are distinguishable without reading the label.
                    DirectionGlyph(item: item, size: 11)
                    Text(item.filename)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: Theme.spacingXS) {
                    Text(subtitle)
                    Text("·")
                    Text(Format.fileSize(item.totalBytes))
                    if item.status.isRunning && item.status.bytesPerSecond > 1 {
                        Text("·")
                        Text(Format.throughput(item.status.bytesPerSecond))
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if item.status.isRunning {
                    TransferProgressBar(progress: item.status.progress, isActive: true)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: Theme.spacingSM)

            if item.status == .pending {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isHoveringRemove ? 1 : 0.35)
                .onHover { isHoveringRemove = $0 }
                .help("Remove from queue")
                .accessibilityLabel("Remove \(item.filename) from queue")
            }
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingSM)
        .background {
            if isFlashing {
                CompletionFlash(isVisible: isFlashing)
            }
        }
        .animation(TransferStyle.structural, value: isTerminal)
        .onChange(of: isTerminal) { _, terminal in
            guard terminal, item.status == .completed else { return }
            isFlashing = true
        }
        .onChange(of: item.id) { _, _ in isFlashing = false }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.filename)
        .accessibilityValue(accessibilityValue)
    }

    /// Same three facts for both directions: verb, peer, live rate.
    private var subtitle: String {
        "\(TransferStyle.verb(for: item)) \(TransferStyle.preposition(for: item)) \(item.peerName)"
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .running:
            // Same bar language as the summary, so the icon is not a second,
            // unrelated spinner next to a linear bar.
            TransferProgressBar(progress: item.status.progress, isActive: true, height: 3)
                .frame(width: 18)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .scaleEffect(isFlashing ? 1.15 : 1)
                .animation(TransferStyle.celebrate, value: isFlashing)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var accessibilityValue: String {
        switch item.status {
        case .pending:
            return "Waiting in queue, \(subtitle)"
        case .running(let progress, _):
            return "\(Int(progress * 100)) percent, \(Format.throughput(item.status.bytesPerSecond)), \(subtitle)"
        case .completed:
            return "Completed, \(subtitle)"
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }
}
