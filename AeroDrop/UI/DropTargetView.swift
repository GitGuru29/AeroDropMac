import SwiftUI
import UniformTypeIdentifiers

struct DropTargetView: View {
    @ObservedObject var model: TransferViewModel

    var body: some View {
        VStack(spacing: Theme.spacingMD) {
            Spacer(minLength: 0)

            Image(systemName: model.isDropTargeted ? "tray.and.arrow.down.fill" : "square.and.arrow.down")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(model.isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))

            VStack(spacing: Theme.spacingXS) {
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(subheadline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            Button(action: { model.openFilePicker() }) {
                Label("Choose Files…", systemImage: "folder")
            }
            .controlSize(.large)
            .disabled(!model.canEnqueue)
            .keyboardShortcut("o", modifiers: .command)
            .help(model.selectedPeer == nil
                  ? "Select a device first"
                  : "Choose files to send to \(model.selectedPeer!.name)")

            Spacer(minLength: 0)

            // Sending has a device; receiving does not, because the wire format
            // does not tell us who connected. Stating that readiness explicitly
            // keeps the two directions symmetrical instead of sending-only.
            receiveReadiness
                .padding(.top, Theme.spacingXS)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.spacingLG)
        .background(dropBackdrop)
        .overlay(border)
        .animation(.easeOut(duration: 0.15), value: model.isDropTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop zone")
        .accessibilityHint("Drop one or more files here to send them to the selected device")
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
            Task { await model.handleDrop(providers) }
            return true
        }
    }

    private var receiveReadiness: some View {
        HStack(spacing: Theme.spacingXS) {
            Image(systemName: receiveSymbol)
                .font(.caption)
                .foregroundStyle(receiveTint)
                .contentTransition(.symbolEffect(.replace))

            Text(receiveText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, Theme.spacingSM)
        .padding(.vertical, Theme.spacingXS)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.surfaceHover)
        )
        .animation(.easeOut(duration: 0.2), value: model.serverState)
        .accessibilityElement(children: .combine)
    }

    private var isListening: Bool {
        if case .running = model.serverState { return true }
        return false
    }

    private var receiveSymbol: String {
        isListening ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
    }

    private var receiveTint: Color {
        isListening ? Color.green : Color.secondary
    }

    private var receiveText: String {
        isListening
            ? "Ready to receive — files arrive in this panel"
            : "Not listening — port 7770 unavailable"
    }

    private var dropBackdrop: some View {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(model.isDropTargeted ? Theme.surfaceHover : Color.clear)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(
                model.isDropTargeted ? Color.accentColor : Theme.hairline,
                style: StrokeStyle(lineWidth: model.isDropTargeted ? 2 : 1, dash: [7, 5])
            )
            .padding(1)
    }

    private var headline: String {
        if model.isDropTargeted { return "Release to send" }
        if model.selectedPeer == nil { return "Choose a device" }
        return "Drop files to send"
    }

    private var subheadline: String {
        if model.isDropTargeted {
            return "Files go straight to \(model.selectedPeer?.name ?? "the selected device") over an encrypted connection."
        }
        if let peer = model.selectedPeer {
            return "\(peer.name) is ready. Drop one or more files here, or use Choose Files."
        }
        return "Pick a device on the left to start sending."
    }
}
