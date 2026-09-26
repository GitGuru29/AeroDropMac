import SwiftUI
import AppKit

enum Theme {
    static let sidebarBackground = Color(nsColor: .underPageBackgroundColor)
    static let surface           = Color(nsColor: .controlBackgroundColor)
    static let surfaceHover      = Color(nsColor: .controlAccentColor).opacity(0.10)
    static let hairline          = Color(nsColor: .separatorColor)

    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 8
    static let spacingMD: CGFloat = 14
    static let spacingLG: CGFloat = 20

    static let panelRadius: CGFloat = 10
    static let cardRadius: CGFloat = 12
}

struct CardBackground: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    var padding: CGFloat = Theme.spacingMD

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func cardBackground(radius: CGFloat = Theme.cardRadius,
                        padding: CGFloat = Theme.spacingMD) -> some View {
        modifier(CardBackground(radius: radius, padding: padding))
    }

    @ViewBuilder
    func applyIf<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

enum Format {
    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    static func fileSize(_ count: UInt64) -> String {
        bytes.string(fromByteCount: Int64(min(count, UInt64(Int64.max))))
    }

    static func throughput(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 1 else { return "—" }
        return bytes.string(fromByteCount: Int64(min(bytesPerSecond, 1e12))) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 {
            return String(format: "%.0fs left", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return String(format: "%dm %02ds left", minutes, remainder)
    }

    static func groupedFingerprint(_ hex: String) -> String {
        let compact = hex
            .replacingOccurrences(of: ":", with: "")
            .filter { $0.isHexDigit }
            .uppercased()
        return stride(from: 0, to: compact.count, by: 2)
            .map { offset -> String in
                let start = compact.index(compact.startIndex, offsetBy: offset)
                let end = compact.index(start, offsetBy: min(2, compact.distance(from: start, to: compact.endIndex)))
                return String(compact[start..<end])
            }
            .joined(separator: ":")
    }
}
