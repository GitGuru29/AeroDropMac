import WidgetKit
import SwiftUI
import AppIntents
import UniformTypeIdentifiers

struct WidgetPeer: Equatable {
    let id: String
    let name: String
}
struct WidgetTransfer: Equatable {
    enum Status: String { case idle, sending, receiving, completed, failed }
    let status: Status
    let fileName: String
    let progress: Double
    let bytesTotal: Int64
    let bytesTransferred: Int64
    let throughputMBps: Double
    let etaSeconds: Double
    let errorMessage: String?
}
struct ProviderEntry: TimelineEntry {
    let date: Date
    let family: WidgetFamily
    let variant: AeroWidgetVariant
    let peer: WidgetPeer
    let recents: [String]
    let lastTransfer: WidgetTransfer
}

struct AeroDropWidgetProvider: AppIntentTimelineProvider {
    typealias Entry = ProviderEntry
    typealias Intent = AeroWidgetConfigurationIntent
    
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(),
              family: context.family,
              variant: .drop,
              peer: WidgetPeer(id: "dev1", name: "MacBook Pro"),
              recents: ["document.pdf", "photo.jpg"],
              lastTransfer: WidgetTransfer(status: .idle,
                                           fileName: "",
                                           progress: 0,
                                           bytesTotal: 0,
                                           bytesTransferred: 0,
                                           throughputMBps: 0,
                                           etaSeconds: 0,
                                           errorMessage: nil))
    }
    
    func snapshot(for configuration: Intent, in context: Context) async -> Entry {
        loadEntry(for: configuration, in: context, at: Date())
    }
    
    func timeline(for configuration: Intent, in context: Context) async -> Timeline<Entry> {
        let entry = loadEntry(for: configuration, in: context, at: Date())
        return Timeline(entries: [entry], policy: .atEnd)
    }
    
    private func loadEntry(for configuration: Intent, in context: Context, at date: Date) -> Entry {
        let s = AeroWidgetStore.load()
        let variant = configuration.variant
        return Entry(date: date,
                     family: context.family,
                     variant: variant,
                     peer: WidgetPeer(id: s.peer.id, name: s.peer.name),
                     recents: s.recents,
                     lastTransfer: mapTransfer(s.lastTransfer))
    }
    
    private func mapTransfer(_ t: AeroWidgetTransfer) -> WidgetTransfer {
        WidgetTransfer(status: WidgetTransfer.Status(rawValue: t.status.rawValue) ?? .idle,
                       fileName: t.fileName,
                       progress: max(0,min(1,t.progress)),
                       bytesTotal: t.bytesTotal,
                       bytesTransferred: t.bytesTransferred,
                       throughputMBps: t.throughputMBps,
                       etaSeconds: t.etaSeconds,
                       errorMessage: t.errorMessage)
    }
}

struct AeroDropWidgetEntryView: View {
    let entry: ProviderEntry
    
    var body: some View {
        switch entry.variant {
        case .drop: DropVariant(entry: entry)
        case .status: StatusVariant(entry: entry)
        case .recents: RecentsVariant(entry: entry)
        }
    }
}

struct DropVariant: View {
    let entry: ProviderEntry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AeroDrop").font(.headline)
                Spacer()
                if !entry.peer.name.isEmpty {
                    Text(entry.peer.name).font(.caption).lineLimit(1).truncationMode(.middle)
                }
            }
            DropDestinationPreview()
            Text(family == .systemLarge || family == .systemExtraLarge ? "Drag files to send" : "Drop to send")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .containerBackground(for: .widget) { Color(nsColor: .controlBackgroundColor) }
        .dropDestination(for: URL.self) { items, location in
            let payload = items.map { $0.absoluteString }
            AeroWidgetDropStore.setPending(urlStrings: payload)
            return true
        }
    }
}

struct DropDestinationPreview: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(.secondary.opacity(0.4))
            Image(systemName: "airdrop")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct StatusVariant: View {
    let entry: ProviderEntry
    let t: WidgetTransfer
    
    init(entry: ProviderEntry) {
        self.entry = entry
        self.t = entry.lastTransfer
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transfer").font(.headline)
                Spacer()
                if !entry.peer.name.isEmpty { Text(entry.peer.name).font(.caption).lineLimit(1) }
            }
            if t.status == .idle || t.fileName.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready").font(.subheadline)
                    Text("No recent transfer").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.fileName).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    ProgressView(value: t.progress).progressViewStyle(.linear)
                    HStack {
                        Text(statusText(t.status)).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if t.throughputMBps > 0 {
                            Text(String(format: "%.2f MB/s", t.throughputMBps)).font(.caption2).foregroundStyle(.secondary)
                        }
                        if t.etaSeconds > 0 && t.status != .completed && t.status != .failed {
                            Text(String(format: "ETA ~%.0fs", t.etaSeconds)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let e = t.errorMessage, !e.isEmpty {
                        Text(e).font(.caption2).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .containerBackground(for: .widget) { Color(nsColor: .controlBackgroundColor) }
    }
    
    func statusText(_ s: WidgetTransfer.Status) -> String {
        switch s {
        case .idle: return "Idle"
        case .sending: return "Sending"
        case .receiving: return "Receiving"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

struct RecentsVariant: View {
    let entry: ProviderEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent").font(.headline)
                Spacer()
                if !entry.peer.name.isEmpty { Text(entry.peer.name).font(.caption).lineLimit(1) }
            }
            if entry.recents.isEmpty {
                Text("No recent files").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                let list = Array(entry.recents.prefix(maxItems()))
                ForEach(list.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.fill").foregroundStyle(.secondary)
                        Text(list[i]).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .containerBackground(for: .widget) { Color(nsColor: .controlBackgroundColor) }
    }
    
    func maxItems() -> Int {
        switch entry.family {
        case .systemSmall: return 2
        case .systemMedium: return 3
        case .systemLarge: return 6
        case .systemExtraLarge: return 10
        default: return 3
        }
    }
}

@main
struct AeroDropWidget: Widget {
    let kind = "com.siluna.AeroDrop.Widget"
    
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: AeroWidgetConfigurationIntent.self, provider: AeroDropWidgetProvider()) { entry in
            AeroDropWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AeroDrop")
        .description("Quickly send files to your default device, see transfer status, or pick from recent files.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
