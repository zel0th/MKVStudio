import Foundation
import Observation
import ImageIO

struct KinopoiskImportSelection: Sendable {
    var fields: Set<String>
    var poster = false
    var containerTitle = false
    var onlyEmpty = true
}

extension AppState {
    func russianTags(scope: Int, includeEdits: Bool = true) async throws -> [String: String] {
        guard let file = files.first, let tools else { throw StudioError.message("Добавьте исходный файл.") }
        let tags = try await file.isMatroska ? MetadataService.readTags(file.url, executable: tools.mkvextract) : MatroskaTags(xml: "<Tags/>")
        var values = try await Task.detached { try tags.values(language: "ru", scope: scope) }.value
        if includeEdits, let edits = project.tagEdits, edits.language == "ru", edits.scope == scope {
            values.merge(edits.values) { _, new in new }
        }
        return values
    }
    func applyKinopoisk(_ details: KinopoiskDetails, selection: KinopoiskImportSelection, client: KinopoiskClient,
                        sourceID: UUID, generation: UUID, posterRoot: URL? = nil) async throws {
        guard files.first?.id == sourceID, metadataGeneration == generation else { throw CancellationError() }
        let scope = details.film.scope
        if let edits = project.tagEdits, !edits.values.isEmpty, (edits.language != "ru" || edits.scope != scope) {
            throw StudioError.message("Сначала сохраните сборку или сбросьте правки тегов другого языка / уровня. Затем повторите импорт.")
        }
        let original = try await russianTags(scope: scope, includeEdits: false)
        var baseline = original
        if let edits = project.tagEdits, edits.language == "ru", edits.scope == scope { baseline.merge(edits.values) { _, new in new } }
        var edits = project.tagEdits ?? TagEdits(language: "ru")
        edits.language = "ru"; edits.targetTypeValue = scope
        let available = details.fields
        for key in selection.fields {
            guard let value = available[key], !value.isEmpty else { continue }
            if !selection.onlyEmpty || (baseline[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { edits.values[key] = value }
        }
        try edits.validate()
        var poster: PosterImage?
        if selection.poster {
            guard let url = details.film.posterUrl else { throw StudioError.message("Постер не найден.") }
            poster = try await client.poster(url)
        }
        try Task.checkCancellation()
        guard files.first?.id == sourceID, metadataGeneration == generation else { throw CancellationError() }
        var attachment: AddedAttachment?
        if let poster {
            // Immutable persistent asset: saved projects and queued jobs must survive closing the sheet/app.
            let root = posterRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MKVStudio/ImportedPosters", isDirectory: true)
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("cover.\(poster.fileExtension)")
                try poster.data.write(to: url, options: .atomic)
                attachment = AddedAttachment(url: url, name: url.lastPathComponent, mimeType: poster.mime)
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }
        // Commit all changes together after successful downloads; source media is never edited here.
        metadataToken?.cancel(); metadataToken = nil; isLoadingTags = false
        metadataGeneration = UUID()
        project.tagEdits = edits; tagValues = original; tagsSourceID = sourceID
        if selection.containerTitle, let title = details.film.nameRu, !title.isEmpty,
           !selection.onlyEmpty || project.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { project.title = title }
        if let attachment { project.attachments.append(attachment) }
    }
}

@MainActor @Observable
final class KinopoiskSearchModel {
    var query: String
    var year = ""
    var results: [KinopoiskFilm] = []
    var page = 1
    var totalPages = 1
    var searched = false
    var details: KinopoiskDetails?
    var baseline: [String: String] = [:]
    var selection = KinopoiskImportSelection(fields: [])
    var preview: CGImage?
    var error: String?
    var posterError: String?
    var busy = false
    var applying = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored var client: KinopoiskClient?
    init(query: String) { self.query = query }
    func cancel() { requestID = UUID(); task?.cancel(); task = nil; busy = false; applying = false }
    func search(page requested: Int = 1) {
        cancel(); let id = requestID
        error = nil; posterError = nil; details = nil; preview = nil; results = []; busy = true; searched = false
        let query = query, year = year
        task = Task {
            defer { if requestID == id { busy = false } }
            do {
                let client = try self.client ?? KinopoiskClient(key: APIKeyStore().read() ?? "")
                let result = try await client.search(query, year: year, page: requested)
                try Task.checkCancellation(); guard requestID == id else { return }
                self.client = client; results = result.items; page = requested; totalPages = min(20, max(1, result.totalPages)); searched = true
            } catch is CancellationError {} catch { if requestID == id { self.error = error.localizedDescription } }
        }
    }
    func select(_ film: KinopoiskFilm, state: AppState) {
        cancel(); let id = requestID
        error = nil; posterError = nil; preview = nil; details = nil; busy = true
        task = Task {
            defer { if requestID == id { busy = false } }
            do {
                guard let client else { return }
                let found = try await client.details(film.id)
                let existing = try await state.russianTags(scope: found.film.scope)
                try Task.checkCancellation(); guard requestID == id else { return }
                baseline = existing; details = found
                selection = KinopoiskImportSelection(fields: Set(found.fields.keys))
                if let url = found.film.posterUrlPreview ?? found.film.posterUrl {
                    do {
                        let image = try await client.poster(url)
                        let thumb = await Task.detached { image.thumbnail() }.value
                        try Task.checkCancellation(); guard requestID == id else { return }
                        preview = thumb
                    } catch is CancellationError {} catch { if requestID == id { posterError = error.localizedDescription } }
                }
            } catch is CancellationError {} catch { if requestID == id { self.error = error.localizedDescription } }
        }
    }
    func apply(state: AppState, sourceID: UUID, generation: UUID, done: @escaping @MainActor () -> Void) {
        guard let details, let client else { return }
        cancel(); let id = requestID
        busy = true; applying = true; error = nil
        task = Task {
            defer { if requestID == id { busy = false; applying = false } }
            do {
                try await state.applyKinopoisk(details, selection: selection, client: client, sourceID: sourceID, generation: generation)
                try Task.checkCancellation(); guard requestID == id else { return }
                done()
            } catch is CancellationError {} catch { if requestID == id { self.error = error.localizedDescription } }
        }
    }
}
