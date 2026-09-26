import AppIntents
import WidgetKit
import SwiftUI

enum AeroWidgetVariant: String, AppEnum {
    case drop
    case status
    case recents

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "AeroDrop Widget Mode"
    static var caseDisplayRepresentations: [AeroWidgetVariant: DisplayRepresentation] = [
        .drop: "Drop to Send",
        .status: "Transfer Status",
        .recents: "Recent Files"
    ]
}

struct AeroWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "AeroDrop Widget"
    @Parameter(title: "Mode", default: .drop)
    var variant: AeroWidgetVariant
}

enum AeroWidgetDropStore {
    static func setPending(urlStrings: [String]) {
        var s = AeroWidgetStore.load()
        s.pendingDrop = AeroWidgetPendingDrop(urls: urlStrings, timestamp: Date().timeIntervalSince1970)
        AeroWidgetStore.save(s)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
