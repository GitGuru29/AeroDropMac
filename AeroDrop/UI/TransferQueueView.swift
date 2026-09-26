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

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.spacingSM) {
            HStack(spacing: Theme.spacingSM) {
                Text(summaryTitle)
                    .font(.headline)
                Spacer()
                if model.isTransferring {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }

            ProgressView(value: model.overallProgress)
                .progressViewStyle(.linear)
                .accessibilityLabel("Overall progress")
                .accessibilityValue("\(Int(model.overallProgress * 100)) percent")

            if let active = model.activeItem {
                HStack(spacing: Theme.spacingXS) {
                    Text(active.isOutgoing ? "Sending \(active.filename)" : "Receiving \(active.filename)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let remaining = active.estimatedTimeRemaining {
                        Text(Format.duration(remaining))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.spacingMD)
        .padding(.vertical, Theme.spacingMD)
    }

    private var summaryTitle: String {
        let total = model.queue.count
        guard total > 0 else { return "Transfers" }
        if model.isTransferring { return "Transferring \(total) item\(total == 1 ? "" : "s")" }
        if model.hasFinishedItems { return "\(total) item\(total == 1 ? "" : "s")" }
        return "Queued — \(total) item\(total == 1 ? "" : "s")"
    }

    // ── List ────────────────────────────────────────────────────────────────

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.queue) { item in
                    TransferRow(item: item) { model.remove(item) }
                    if item.id != model.queue.last?.id {
                        Divider().padding(.leading, Theme.spacingMD)
                    }
                }
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

    var body: some View {
        HStack(spacing: Theme.spacingSM) {
            statusIcon
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: Theme.spacingXS) {
                    Text(directionLabel)
                    Text("·")
                    Text(Format.fileSize(item.totalBytes))
                    if case .running(let progress, let bps) = item.status {
                        Text("·")
                        Text(Format.throughput(bps))
                        if progress > 0 {
                            Text("·")
                            Text("\(Int(progress * 100))%")
                        }
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if item.status.isRunning {
                    ProgressView(value: item.status.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.filename)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var directionLabel: String {
        item.isOutgoing ? "To \(item.peerName)" : "From \(item.peerName)"
    }

    private var accessibilityValue: String {
        switch item.status {
        case .pending:
            return "Waiting in queue, \(directionLabel)"
        case .running(let progress, let bps):
            return "\(Int(progress * 100)) percent, \(Format.throughput(bps)), \(directionLabel)"
        case .completed:
            return "Completed, \(directionLabel)"
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }
}
