import Foundation

/// Only assigned Matroska names are offered for editing. Other tags remain untouched.
struct MatroskaTagField: Identifiable, Sendable {
    let id: String
    let title: String
    var multiline = false
    static let all: [Self] = [
        .init(id: "TITLE", title: "Название произведения"),
        .init(id: "SUBTITLE", title: "Подзаголовок"),
        .init(id: "DATE_RELEASED", title: "Год или дата выпуска"),
        .init(id: "RECORDING_LOCATION", title: "Страна / место съёмки"),
        .init(id: "DIRECTOR", title: "Режиссёр"),
        .init(id: "ACTOR", title: "Актёры"),
        .init(id: "SCREENPLAY_BY", title: "Сценарист"),
        .init(id: "PRODUCER", title: "Продюсер"),
        .init(id: "COMPOSER", title: "Композитор"),
        .init(id: "GENRE", title: "Жанр"),
        .init(id: "SUMMARY", title: "Краткое содержание", multiline: true),
        .init(id: "DESCRIPTION", title: "Описание", multiline: true),
        .init(id: "COMMENT", title: "Комментарий", multiline: true)
    ]
    var hint: String {
        switch id {
        case "DATE_RELEASED": "Например, 1997 или 1997-12-19"
        case "RECORDING_LOCATION": "Код страны: JP, US, RU. Можно добавить регион и город через запятую."
        default: ""
        }
    }
}

struct TagEdits: Codable, Equatable, Sendable {
    var language = "und"
    var targetTypeValue: Int?
    var scope: Int { targetTypeValue ?? 50 }
    var values: [String: String] = [:]
    func validate() throws {
        guard [50, 70].contains(scope) else { throw StudioError.message("Неподдерживаемый уровень тегов.") }
        guard language.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]+)*$", options: .regularExpression) != nil else {
            throw StudioError.message("Укажите код языка тегов, например und, ru или en.")
        }
        guard values.count <= MatroskaTagField.all.count else { throw StudioError.message("Слишком много полей тегов.") }
        for (key, text) in values {
            guard let field = MatroskaTagField.all.first(where: { $0.id == key }), text.utf8.count <= 65536,
                  text.unicodeScalars.allSatisfy({ $0.value >= 32 || [9, 10, 13].contains($0.value) }) else {
                throw StudioError.message("Недопустимое поле или значение тега: \(key).")
            }
            for value in Self.items(text, field: field) {
                if key == "DATE_RELEASED" {
                    guard Self.validDate(value) else {
                        throw StudioError.message("Дата выпуска: используйте ГГГГ, ГГГГ-ММ или ГГГГ-ММ-ДД.")
                    }
                }
                if key == "RECORDING_LOCATION" {
                    let country = String(value.split(separator: ",", omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespaces)
                    guard Locale.Region.isoRegions.contains(where: { $0.identifier == country }) else {
                        throw StudioError.message("Место съёмки должно начинаться с кода страны, например JP, US или RU.")
                    }
                }
            }
        }
    }
    static func validDate(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]{4}(-[0-9]{2}){0,2}( [0-9]{2}(:[0-9]{2}){0,2}(\\.[0-9]{3})?)?$", options: .regularExpression) != nil else { return false }
        let halves = value.split(separator: " ")
        let date = halves[0].split(separator: "-").compactMap { Int($0) }
        guard let year = date.first, year > 0 else { return false }
        let month = date.count > 1 ? date[1] : 1, day = date.count > 2 ? date[2] : 1
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day)
        guard let resolved = calendar.date(from: parts), calendar.dateComponents([.year, .month, .day], from: resolved) == parts else { return false }
        if halves.count == 2 {
            guard date.count == 3 else { return false }
            let time = halves[1].split(separator: ":")
            guard let hour = Int(time[0]), hour < 24 else { return false }
            if time.count > 1, (Int(time[1]) ?? 60) >= 60 { return false }
            if time.count > 2, (Double(time[2]) ?? 60) >= 60 { return false }
            if halves[1].contains("."), time.count != 3 { return false }
        }
        return true
    }
    static func items(_ text: String, field: MatroskaTagField) -> [String] {
        let values = field.multiline ? [text] : text.components(separatedBy: .newlines)
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// XML is parsed off the UI thread. Only edited global, default-language values at level 50 change.
struct MatroskaTags: Sendable {
    static let limit = 2 * 1024 * 1024
    let xml: String
    init(xml: String) throws {
        _ = try Self.document(xml)
        self.xml = xml
    }
    static func document(_ xml: String) throws -> XMLDocument {
        guard xml.utf8.count <= limit, !xml.uppercased().contains("<!ENTITY") else {
            throw StudioError.message("Теги превышают 2 МБ или содержат объявления XML-сущностей.")
        }
        let doc = try XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever])
        guard let root = doc.rootElement(), root.name == "Tags" else { throw StudioError.message("Ожидается XML Matroska с корневым элементом Tags.") }
        var pending: [(XMLNode, Int)] = [(root, 0)], count = 0
        while let (node, depth) = pending.popLast() {
            count += 1
            guard depth <= 32, count <= 20000 else { throw StudioError.message("Слишком сложная структура тегов.") }
            pending += (node.children ?? []).map { ($0, depth + 1) }
        }
        return doc
    }
    private static func global(_ tag: XMLElement, scope: Int) -> Bool {
        guard let targets = tag.elements(forName: "Targets").first else { return scope == 50 }
        return (targets.elements(forName: "TargetTypeValue").first?.stringValue ?? "50") == String(scope)
            && !["TrackUID", "ChapterUID", "EditionUID", "AttachmentUID"].contains { !targets.elements(forName: $0).isEmpty }
    }
    private static func language(_ simple: XMLElement) -> String {
        normalizedLanguage(simple.elements(forName: "TagLanguageIETF").first?.stringValue ?? simple.elements(forName: "TagLanguage").first?.stringValue ?? "eng")
    }
    static func normalizedLanguage(_ value: String) -> String {
        let lower = value.lowercased()
        return ["eng": "en", "rus": "ru", "jpn": "ja", "deu": "de", "ger": "de", "fra": "fr", "fre": "fr"][lower] ?? lower
    }
    private static func matches(_ simple: XMLElement, key: String, language: String) -> Bool {
        simple.elements(forName: "Name").first?.stringValue == key && Self.language(simple) == normalizedLanguage(language)
            && (simple.elements(forName: "DefaultLanguage").first?.stringValue ?? "1") == "1"
            && simple.elements(forName: "Binary").isEmpty
    }
    func preferredLanguage(scope: Int = 50) throws -> String {
        let tags = try Self.document(xml).rootElement()!.elements(forName: "Tag").filter { Self.global($0, scope: scope) }
        let fields = Set(MatroskaTagField.all.map(\.id))
        let node = tags.flatMap { $0.elements(forName: "Simple") }.first {
            fields.contains($0.elements(forName: "Name").first?.stringValue ?? "")
                && ($0.elements(forName: "DefaultLanguage").first?.stringValue ?? "1") == "1"
        }
        return node.map(Self.language) ?? "und"
    }
    func values(language: String, scope: Int = 50) throws -> [String: String] {
        let root = try Self.document(xml).rootElement()!
        let nodes = root.elements(forName: "Tag").filter { Self.global($0, scope: scope) }.flatMap { $0.elements(forName: "Simple") }
        return Dictionary(uniqueKeysWithValues: MatroskaTagField.all.map { field in
            (field.id, nodes.filter { Self.matches($0, key: field.id, language: language) }.compactMap { $0.elements(forName: "String").first?.stringValue }.joined(separator: "\n"))
        })
    }
    func applying(_ edits: TagEdits) throws -> String {
        try edits.validate()
        let doc = try Self.document(xml), root = doc.rootElement()!
        let tags = root.elements(forName: "Tag").filter { Self.global($0, scope: edits.scope) }
        let destination = tags.first ?? XMLElement(name: "Tag")
        if destination.parent == nil {
            let targets = XMLElement(name: "Targets")
            targets.addChild(XMLElement(name: "TargetTypeValue", stringValue: String(edits.scope)))
            destination.addChild(targets); root.addChild(destination)
        }
        for field in MatroskaTagField.all {
            guard let text = edits.values[field.id] else { continue }
            let existing = tags.flatMap { $0.elements(forName: "Simple") }.filter { Self.matches($0, key: field.id, language: edits.language) }
            let values = TagEdits.items(text, field: field)
            for (index, value) in values.enumerated() {
                let node: XMLElement
                if index < existing.count { node = existing[index] }
                else {
                    node = XMLElement(name: "Simple")
                    node.addChild(XMLElement(name: "Name", stringValue: field.id))
                    node.addChild(XMLElement(name: "TagLanguage", stringValue: "und"))
                    node.addChild(XMLElement(name: "TagLanguageIETF", stringValue: edits.language))
                    node.addChild(XMLElement(name: "DefaultLanguage", stringValue: "1"))
                    destination.addChild(node)
                }
                // Preserve child Simple nodes (e.g. actor roles) and language metadata.
                node.elements(forName: "String").forEach { $0.detach() }
                node.addChild(XMLElement(name: "String", stringValue: value))
            }
            existing.dropFirst(values.count).forEach { $0.detach() }
        }
        root.elements(forName: "Tag").filter { $0.elements(forName: "Simple").isEmpty }.forEach { $0.detach() }
        doc.dtd = nil; doc.version = "1.0"; doc.characterEncoding = "UTF-8"
        return doc.xmlString(options: [.nodePrettyPrint])
    }
}
