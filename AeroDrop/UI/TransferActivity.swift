import SwiftUI
import Combine

/// Transfer state mirrored out to the menu bar.
///
/// The panel can be dismissed, so without this an in-flight transfer — in
/// either direction — would be invisible until the user happened to reopen it.
/// This is the only piece of transfer state the status item needs.
@MainActor
final class TransferActivity: ObservableObject {
    static let shared = TransferActivity()

    @Published private(set) var isTransferring = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var direction: TransferItem.Direction = .outgoing

    func update(isTransferring: Bool, progress: Double, direction: TransferItem.Direction) {
        self.isTransferring = isTransferring
        self.progress = progress
        self.direction = direction
    }
}
