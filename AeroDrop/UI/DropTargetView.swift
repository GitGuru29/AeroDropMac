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
