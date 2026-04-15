// PeerRowView.swift — AeroDrop
// Discovered peer list item with animated signal bars.
// TODO: Implementation
import SwiftUI

struct AeroPeerInfo: Identifiable, Equatable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
}

struct PeerRowView: View {
    let peer: AeroPeerInfo
    let onTap: () -> Void
    var body: some View { EmptyView() }
}
