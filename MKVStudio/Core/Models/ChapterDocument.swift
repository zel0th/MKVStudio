import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

struct ChapterEntry: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var start = "00:00:00.000000000"
    var end = ""
    var name = "Новая глава"
    var language = "und"
    var children: [ChapterEntry] = []
    /// Keeps flags, UIDs, alternate names, linked segments and other untouched metadata.
    var template: String?
    var seconds: Double { Double((try? MediaTime.nanoseconds(start)) ?? 0) / 1e9 }
    struct Row: Identifiable { var entry: ChapterEntry; var depth: Int; var id: UUID { entry.id } }
    func flattened(depth: Int = 0) -> [Row] { [Row(entry: self, depth: depth)] + children.flatMap { $0.flattened(depth: depth + 1) } }
    static func update(_ entries: inout [ChapterEntry], id: UUID, edit: (inout ChapterEntry) -> Void) {
        for index in entries.indices {
            if entries[index].id == id { edit(&entries[index]); return }
            update(&entries[index].children, id: id, edit: edit)
        }
    }
    static func remove(_ entries: inout [ChapterEntry], id: UUID) {
        entries.removeAll { $0.id == id }
        for i in entries.indices { remove(&entries[i].children, id: id) }
    }
    static func move(_ entries: inout [ChapterEntry], id: UUID, offset: Int) {
        if let i = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(i + offset) { entries.swapAt(i, i + offset); return }
        for i in entries.indices { move(&entries[i].children, id: id, offset: offset) }
    }
}
struct ChapterEdition: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var chapters: [ChapterEntry] = []
    var template: String?
}
struct ChapterDocument: Codable, Equatable, Sendable {
    var editions = [ChapterEdition()]
    var rootTemplate: String?

    static func parse(_ data: Data) throws -> ChapterDocument {
        guard data.count <= 8 * 1024 * 1024, let decoded = String(data: data, encoding: .utf8) else { throw StudioError.message("Главы должны быть в UTF-8 и занимать не более 8 МБ.") }
        let text = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") { return try parseSimple(text) }
        guard !text.uppercased().contains("<!ENTITY") else { throw StudioError.message("Объявления XML-сущностей в главах не поддерживаются.") }
        let document = try XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement(), root.name == "Chapters" else { throw StudioError.message("Ожидается XML с корневым элементом Chapters.") }
        var result = ChapterDocument(editions: [], rootTemplate: nil)
        var count = 0
        for edition in root.elements(forName: "EditionEntry") {
            let entries = try edition.elements(forName: "ChapterAtom").map { try parseEntry($0, depth: 0, count: &count) }
            edition.elements(forName: "ChapterAtom").forEach { $0.detach() }
            result.editions.append(ChapterEdition(chapters: entries, template: edition.xmlString))
            edition.detach()
        }
        result.rootTemplate = root.xmlString
        if result.editions.isEmpty { result.editions = [ChapterEdition()] }
        return result
    }
    private static func parseEntry(_ node: XMLElement, depth: Int, count: inout Int) throws -> ChapterEntry {
        count += 1
        guard count <= 10000, depth <= 32 else { throw StudioError.message("Слишком большая структура глав: допустимо 10 000 глав и 32 уровня.") }
        let display = node.elements(forName: "ChapterDisplay").first
        let children = try node.elements(forName: "ChapterAtom").map { try parseEntry($0, depth: depth + 1, count: &count) }
        node.elements(forName: "ChapterAtom").forEach { $0.detach() }
        return ChapterEntry(start: value(node, "ChapterTimeStart") ?? "00:00:00.000000000", end: value(node, "ChapterTimeEnd") ?? "", name: display.flatMap { value($0, "ChapterString") } ?? "", language: display.flatMap { value($0, "ChapLanguageIETF") ?? value($0, "ChapterLanguage") } ?? "und", children: children, template: node.xmlString)
    }
    private static func parseSimple(_ text: String) throws -> ChapterDocument {
        var times: [Int: String] = [:], names: [Int: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].hasPrefix("CHAPTER") else { throw StudioError.message("Ожидаются строки CHAPTER01=00:00:00.000 и CHAPTER01NAME=Название.") }
            let name = pair[0].hasSuffix("NAME")
            let key = pair[0].dropFirst(7)
            guard let index = Int(name ? String(key.dropLast(4)) : String(key)), index > 0 else { throw StudioError.message("Некорректный номер главы.") }
            if name { names[index] = String(pair[1]) } else { times[index] = String(pair[1]) }
        }
        guard !times.isEmpty, times.count <= 10000, Set(names.keys).isSubset(of: Set(times.keys)) else { throw StudioError.message("Не найдены времена начала глав.") }
        let entries = try times.keys.sorted().map { index in
            ChapterEntry(start: MediaTime.format(try MediaTime.nanoseconds(times[index]!)), name: names[index] ?? "Глава \(index)")
        }
        return ChapterDocument(editions: [ChapterEdition(chapters: entries)])
    }
    func xml() throws -> String {
        let root = try rootTemplate.map { try XMLElement(xmlString: $0) } ?? XMLElement(name: "Chapters")
        for edition in editions {
            let node = try edition.template.map { try XMLElement(xmlString: $0) } ?? XMLElement(name: "EditionEntry")
            if Self.value(node, "EditionUID") == nil { Self.set(node, "EditionUID", String(UInt64.random(in: 1...UInt64.max))) }
            for chapter in edition.chapters { node.addChild(try Self.makeEntry(chapter)) }
            root.addChild(node)
        }
        let doc = XMLDocument(rootElement: root)
        doc.version = "1.0"; doc.characterEncoding = "UTF-8"
        return doc.xmlString(options: [.nodePrettyPrint])
    }
    private static func makeEntry(_ entry: ChapterEntry) throws -> XMLElement {
        let start = try MediaTime.nanoseconds(entry.start)
        if !entry.end.isEmpty, try MediaTime.nanoseconds(entry.end) <= start { throw StudioError.message("Конец главы «\(entry.name)» должен быть позже начала.") }
        guard entry.language.range(of: "^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$", options: .regularExpression) != nil else { throw StudioError.message("Укажите код языка главы, например ru или en.") }
        let node = try entry.template.map { try XMLElement(xmlString: $0) } ?? XMLElement(name: "ChapterAtom")
        if value(node, "ChapterUID") == nil { set(node, "ChapterUID", String(UInt64.random(in: 1...UInt64.max))) }
        set(node, "ChapterTimeStart", MediaTime.format(start))
        set(node, "ChapterTimeEnd", entry.end.isEmpty ? nil : MediaTime.format(try MediaTime.nanoseconds(entry.end)))
        let display = node.elements(forName: "ChapterDisplay").first ?? XMLElement(name: "ChapterDisplay")
        if display.parent == nil { node.addChild(display) }
        set(display, "ChapterString", entry.name)
        // IETF is authoritative; preserve legacy languages only when unchanged.
        let originalLanguage = value(display, "ChapLanguageIETF") ?? value(display, "ChapterLanguage") ?? "und"
        if originalLanguage != entry.language || entry.template == nil {
            display.elements(forName: "ChapterLanguage").forEach { $0.detach() }
            display.elements(forName: "ChapLanguageIETF").forEach { $0.detach() }
            set(display, "ChapLanguageIETF", entry.language)
        }
        for child in entry.children { node.addChild(try makeEntry(child)) }
        return node
    }
    private static func value(_ node: XMLElement, _ key: String) -> String? { node.elements(forName: key).first?.stringValue }
    private static func set(_ node: XMLElement, _ key: String, _ value: String?) {
        guard let value else { node.elements(forName: key).forEach { $0.detach() }; return }
        if let existing = node.elements(forName: key).first { existing.stringValue = value }
        else { node.addChild(XMLElement(name: key, stringValue: value)) }
    }
}
