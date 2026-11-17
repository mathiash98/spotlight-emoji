import SwiftUI
import AppIntents
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

struct EmojiRecord: Codable, Sendable {
    let id: String
    let symbol: String
    let name: String
    let keywords: [String]
    var displayName: String { EmojiCatalog.titles[symbol] ?? name }
    var shortcodes: [String] {
        let names = [name, displayName] + (EmojiCatalog.aliases[symbol] ?? [])
        return Array(Set(names.map { value in
            value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "_")
        }.filter { !$0.isEmpty })).sorted()
    }
    var searchTerms: [String] { keywords + (EmojiCatalog.aliases[symbol] ?? []) + [name, displayName, symbol] + shortcodes.flatMap { [$0, ":" + $0, ":" + $0 + ":"] } }
}

enum EmojiCatalog {
    static let titles = ["🙏": "Pray · Folded hands", "🤞": "Fingers crossed", "❤️": "Heart", "😂": "Laughing · Tears of joy", "👍": "Thumbs up", "🎉": "Celebrate · Party popper"]
    static let aliases = [
        "🙏": ["pray", "praying", "prayer", "thank you", "please", "namaste", "be", "ber", "bønn"],
        "🤞": ["fingers crossed", "cross fingers", "good luck", "krysser fingrene", "kryssede fingre"],
        "❤️": ["heart", "love", "hjerte", "kjærlighet"],
        "😂": ["laugh", "laughing", "lol", "haha", "ler"],
        "👍": ["thumbs up", "yes", "ok", "good", "tommel opp"],
        "🎉": ["party", "celebrate", "congratulations", "gratulerer"]
    ]
    static let records: [EmojiRecord] = {
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([EmojiRecord].self, from: data) else { return [] }
        return records
    }()
    static let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    static func search(_ text: String) -> [EmojiRecord] {
        let query = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .replacingOccurrences(of: "_", with: " ")
        if query.isEmpty {
            let favorites = ["😀", "😂", "❤️", "👍", "🎉", "🔥", "🙏", "✅", "🏠", "🚀", "👀", "😊"]
            return favorites.compactMap { symbol in records.first { $0.symbol == symbol } }
        }
        let words = query.split(separator: " ").map(String.init)
        return records.compactMap { record -> (EmojiRecord, Int)? in
            let name = record.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            let keywords = record.searchTerms.map { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) }
            let searchable = ([name, record.symbol] + keywords).joined(separator: " ")
            guard words.allSatisfy({ searchable.contains($0) }) else { return nil }
            let preferred = (aliases[record.symbol] ?? []).contains(query)
            let rank = record.symbol == query ? 0 : preferred ? 1 : name == query ? 2 : keywords.contains(query) ? 3 : name.hasPrefix(query) ? 4 : 5
            return (record, rank)
        }.sorted { a, b in a.1 == b.1 ? (a.0.id.split(separator: " ").count == b.0.id.split(separator: " ").count ? a.0.id < b.0.id : a.0.id.split(separator: " ").count < b.0.id.split(separator: " ").count) : a.1 < b.1 }.prefix(80).map(\.0)
    }
}

struct EmojiEntity: IndexedEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Emoji"
    static var defaultQuery = EmojiQuery()
    var id: String
    var displayRepresentation: DisplayRepresentation {
        guard let record = EmojiCatalog.byID[id] else { return DisplayRepresentation(title: "Emoji") }
        return DisplayRepresentation(title: "\(record.displayName)", subtitle: "\(record.symbol) · Emoji")
    }
}

struct EmojiQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [EmojiEntity] {
        identifiers.filter { EmojiCatalog.byID[$0] != nil }.map { EmojiEntity(id: $0) }
    }
    func entities(matching string: String) async throws -> [EmojiEntity] {
        EmojiCatalog.search(string).map { EmojiEntity(id: $0.id) }
    }
    func suggestedEntities() async throws -> [EmojiEntity] {
        EmojiCatalog.search("").map { EmojiEntity(id: $0.id) }
    }
}

struct CopyEmojiIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy Emoji"
    static var description = IntentDescription("Search emoji by name in English or Norwegian and copy one to paste anywhere.")
    static var supportedModes: IntentModes = .background
    @Parameter(title: "Emoji", requestValueDialog: "Which emoji?") var emoji: EmojiEntity
    static var parameterSummary: some ParameterSummary { Summary("Copy \(\.$emoji)") }
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let record = EmojiCatalog.byID[emoji.id] else { throw EmojiError.notFound }
        EmojiClipboard.copy(record)
        return .result(dialog: "Copied \(record.symbol). Paste with Command-V.")
    }
}
enum EmojiError: Error { case notFound }

struct OpenEmojiIntent: OpenIntent {
    static var title: LocalizedStringResource = "Copy Emoji Result"
    static var supportedModes: IntentModes = .foreground(.immediate)
    @Parameter(title: "Emoji") var target: EmojiEntity
    static var parameterSummary: some ParameterSummary { Summary("Copy \(\.$target)") }
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let record = EmojiCatalog.byID[target.id] else { throw EmojiError.notFound }
        EmojiClipboard.copy(record, source: "spotlight-intent")
        NSApplication.shared.hide(nil)
        return .result(dialog: "Copied \(record.symbol). Paste with Command-V.")
    }
}

@MainActor
final class EmojiIndex: ObservableObject {
    @Published var status = "Adding emoji to Spotlight…"
    static let index = CSSearchableIndex(name: "SpotlightEmojiCatalog")
    static let domain = "no.mathias.SpotlightEmoji.catalog"
    static func thumbnail(_ symbol: String) -> Data? {
        let image = NSImage(size: NSSize(width: 128, height: 128))
        image.lockFocus()
        let text = NSAttributedString(string: symbol, attributes: [.font: NSFont.systemFont(ofSize: 92)])
        let size = text.size()
        text.draw(at: NSPoint(x: (128-size.width)/2, y: (128-size.height)/2))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
    func verifySearch() async throws -> Int {
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["title", "displayName", "textContent"]
        let query = CSSearchQuery(queryString: "title == \"Fingers crossed\"cd", queryContext: context)
        return try await withCheckedThrowingContinuation { continuation in
            query.completionHandler = { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: query.foundItemCount) }
            }
            query.start()
        }
    }
    func update() async {
        if UserDefaults.standard.integer(forKey: "catalogVersion") == 5 {
            status = "\(EmojiCatalog.records.count) emoji · Also searchable in Spotlight"
            return
        }
        do {
            var batch: [CSSearchableItem] = []
            for (offset, record) in EmojiCatalog.records.enumerated() {
                let attributes = CSSearchableItemAttributeSet(contentType: .text)
                attributes.title = record.displayName
                attributes.displayName = record.displayName
                attributes.contentDescription = "\(record.symbol) · :\(record.shortcodes.first ?? record.name): · Return to copy"
                attributes.containerTitle = "Spotlight Emoji"
                attributes.kind = "Emoji"
                attributes.keywords = record.searchTerms + ["emoji"]
                attributes.thumbnailData = Self.thumbnail(record.symbol)
                attributes.textContent = record.searchTerms.joined(separator: " ")
                attributes.rankingHint = EmojiCatalog.titles[record.symbol] != nil ? 100 : record.name.contains("skin tone") ? 5 : 70
                let priority = EmojiCatalog.titles[record.symbol] != nil ? 100 : record.name.contains("skin tone") ? 1 : 10
                attributes.associateAppEntity(EmojiEntity(id: record.id), priority: priority)
                let item = CSSearchableItem(uniqueIdentifier: record.id, domainIdentifier: Self.domain, attributeSet: attributes)
                item.expirationDate = .distantFuture
                batch.append(item)
                if batch.count == 100 || offset == EmojiCatalog.records.count - 1 {
                    try await Self.index.indexSearchableItems(batch)
                    batch.removeAll()
                    status = "Added \(offset + 1) of \(EmojiCatalog.records.count) emoji…"
                }
            }
            UserDefaults.standard.set(5, forKey: "catalogVersion")
            let matches = try await verifySearch()
            status = matches > 0
                ? "Ready · \(EmojiCatalog.records.count) emoji · Search verified"
                : "Indexed \(EmojiCatalog.records.count) emoji · Waiting for Spotlight search"
            let report = "indexed=\(EmojiCatalog.records.count) crossedFingersMatches=\(matches)\n"
            let reportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SpotlightEmoji-index-check.txt")
            try? report.write(to: reportURL, atomically: true, encoding: .utf8)
        } catch {
            status = "Could not update Spotlight: \(error.localizedDescription)"
        }
    }
}

struct EmojiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CopyEmojiIntent(), phrases: ["Copy an emoji with \(.applicationName)", "Find emoji in \(.applicationName)"], shortTitle: "Copy Emoji", systemImageName: "face.smiling")
    }
}


@MainActor
enum EmojiClipboard {
    static func copy(_ record: EmojiRecord, source: String = "app-window") {
        NSPasteboard.general.clearContents()
        let success = NSPasteboard.general.setString(record.symbol, forType: .string)
        UserDefaults.standard.set(record.symbol, forKey: "lastCopiedEmoji")
        UserDefaults.standard.set(source, forKey: "lastCopySource")
        UserDefaults.standard.set(success, forKey: "lastCopySucceeded")
        UserDefaults.standard.set(Date(), forKey: "lastCopyDate")
    }
}


@MainActor
final class EmojiAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        Self.handle(userActivity)
    }
    static func handle(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == CSSearchableItemActionType,
              let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let record = EmojiCatalog.byID[id] else { return false }
        EmojiClipboard.copy(record, source: "spotlight-activity")
        NSApplication.shared.hide(nil)
        return true
    }
}

struct EmojiSearchView: View {
    @ObservedObject var index: EmojiIndex
    @State private var search = ""
    @State private var selection: String?
    @State private var copied: String?
    @FocusState private var searchFocused: Bool
    private var results: [EmojiRecord] { EmojiCatalog.search(search) }
    private var selected: EmojiRecord? {
        results.first { $0.id == selection } ?? results.first
    }
    private func copy(_ record: EmojiRecord?) {
        guard let record else { return }
        EmojiClipboard.copy(record)
        copied = "Copied \(record.symbol)"
        searchFocused = true
    }
    private func move(_ step: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selection } ?? 0
        selection = results[min(max(current + step, 0), results.count - 1)].id
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search emoji — :heart:, pray, hjerte…", text: $search)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($searchFocused)
                    .accessibilityLabel("Search emoji")
                    .onSubmit { copy(selected) }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                if !search.isEmpty {
                    Button { search = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.padding(18)
            Divider()
            if results.isEmpty {
                ContentUnavailableView.search(text: search).frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(results, id: \.id, selection: $selection) { record in
                        HStack(spacing: 14) {
                            Text(record.symbol).font(.system(size: 30)).frame(width: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.displayName).font(.body.weight(.medium))
                                if record.displayName != record.name {
                                    Text(record.name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button { copy(record) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Copy \(record.displayName)")
                                .accessibilityLabel("Copy \(record.displayName)")
                        }.padding(.vertical, 5).tag(record.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { copy(record) }
                    }.listStyle(.inset)
                        .onKeyPress(.return) { copy(selected); return .handled }
                        .onChange(of: selection) { _, value in
                            if let value { proxy.scrollTo(value) }
                        }
                }
            }
            Divider()
            HStack {
                Text(copied ?? "↑ ↓ to choose · Return to copy · ⌘ V to paste")
                    .foregroundStyle(copied == nil ? Color.secondary : Color.accentColor)
                Spacer()
                Text(search.isEmpty ? "English + Norsk" : "\(results.count) results")
                    .foregroundStyle(.secondary)
            }.font(.caption).padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 520)
        .onAppear { selection = results.first?.id; searchFocused = true }
        .onChange(of: search) { _, _ in selection = results.first?.id; copied = nil }
        .task { await index.update() }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            _ = EmojiAppDelegate.handle(activity)
        }
    }
}

@main
struct SpotlightEmojiApp: App {
    @NSApplicationDelegateAdaptor(EmojiAppDelegate.self) private var appDelegate
    @StateObject private var index = EmojiIndex()
    init() {
        if CommandLine.arguments.contains("--check-search") {
            let cases = [("pray", "🙏"), ("fingers crossed", "🤞"), ("hjerte", "❤️"), ("thumbs up", "👍"), ("lol", "😂"), (":heart", "❤️"), (":heart:", "❤️"), (":pray:", "🙏"), (":thumbs_up:", "👍"), (":fingers_crossed:", "🤞")]
            for (query, expected) in cases {
                let actual = EmojiCatalog.search(query).first?.symbol
                guard actual == expected else { print("FAIL \(query): \(actual ?? "nil")"); exit(1) }
                print("PASS \(query) → \(expected)")
            }
            guard EmojiCatalog.search("zzzz-no-emoji-zzzz").isEmpty else { exit(1) }
            guard Set(EmojiCatalog.records.map(\.id)).count == EmojiCatalog.records.count else { exit(1) }
            print("PASS empty results and unique identifiers; \(EmojiCatalog.records.count) emoji")
            exit(0)
        }
        EmojiShortcuts.updateAppShortcutParameters()
    }
    var body: some Scene {
        WindowGroup("Spotlight Emoji") { EmojiSearchView(index: index) }
            .defaultSize(width: 560, height: 520)
    }
}
