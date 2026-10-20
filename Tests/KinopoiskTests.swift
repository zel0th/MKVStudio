import Foundation
import Testing
@testable import MKVStudio

struct KinopoiskTests {
    static let filmJSON = #"{"kinopoiskId":301,"nameRu":"Проверочный фильм","nameOriginal":"Sample","year":1999,"type":"FILM","posterUrl":"https://kinopoiskapiunofficial.tech/images/posters/kp/301.jpg","posterUrlPreview":"https://kinopoiskapiunofficial.tech/images/posters/kp_small/301.jpg","description":"Описание & текст <кино>","shortDescription":"Кратко","genres":[{"genre":"фантастика"}],"countries":[{"country":"США"}]}"#
    static let peopleJSON = #"[{"nameRu":"Режиссёр","professionKey":"DIRECTOR"},{"nameRu":"Актёр","professionKey":"ACTOR"},{"nameRu":"Актёр","professionKey":"ACTOR"},{"nameRu":null,"professionKey":"ACTOR"},{"nameRu":"Сценарист","professionKey":"WRITER"}]"#
    static func details(series: Bool = false) throws -> KinopoiskDetails {
        let json = series ? filmJSON.replacingOccurrences(of: "FILM", with: "TV_SERIES") : filmJSON
        return KinopoiskDetails(film: try JSONDecoder().decode(KinopoiskFilm.self, from: Data(json.utf8)), people: try JSONDecoder().decode([KinopoiskPerson].self, from: Data(peopleJSON.utf8)))
    }
    @Test("Official API schema, query encoding, Russian-only standard mapping and credential isolation")
    func requests() async throws {
        let recorder = RequestRecorder()
        let client = KinopoiskClient(key: "test-key", transport: { request, limit, poster in
            await recorder.add(request)
            if poster { return HTTPPayload(status: 404, data: Data()) }
            let body = request.url!.path == "/api/v2.2/films" ? "{\"totalPages\":2,\"items\":[\(Self.filmJSON)]}" : request.url!.path == "/api/v1/staff" ? Self.peopleJSON : Self.filmJSON
            return HTTPPayload(status: 200, data: Data(body.utf8))
        })
        let page = try await client.search("текст & + кино", year: "1999", page: 2)
        #expect(page.items.count == 1 && page.totalPages == 2)
        let requests = await recorder.requests
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(URLQueryItem(name: "keyword", value: "текст & + кино")))
        #expect(query.contains(URLQueryItem(name: "page", value: "2")))
        #expect(requests[0].value(forHTTPHeaderField: "X-API-KEY") == "test-key")
        let details = try await client.details(301)
        #expect(details.fields["TITLE"] == "Проверочный фильм")
        #expect(details.fields["ACTOR"] == "Актёр" && details.fields["SCREENPLAY_BY"] == "Сценарист")
        #expect(details.fields["RECORDING_LOCATION"] == nil && details.fields["COUNTRY"] == nil)
        var posterFailed = false
        do { _ = try await client.poster(details.film.posterUrl!) } catch { posterFailed = true }
        #expect(posterFailed)
        let last = await recorder.requests.last
        #expect(last?.value(forHTTPHeaderField: "X-API-KEY") == nil)
        #expect(KinopoiskClient.filmID("https://www.kinopoisk.ru/series/301/?x=1") == 301)
        #expect(KinopoiskClient.filmID("https://evil.test/film/301/") == nil)
        #expect(KinopoiskClient.posterURL("https://localhost/a.jpg") == nil)
        #expect(KinopoiskClient.posterURL("https://kinopoiskapiunofficial.tech.evil.test/a.jpg") == nil)
        #expect(KinopoiskClient.posterURL("http://st.kp.yandex.net/a.jpg")?.scheme == "https")
        #expect(!KinopoiskClient.validKey("abc\r\nX-Evil: value"))
        #expect(try JSONDecoder().decode(TagEdits.self, from: Data(#"{"language":"ru","values":{}}"#.utf8)).scope == 50)
    }
    @Test("API failures are actionable; invalid images and malformed responses never become attachments")
    func failures() async throws {
        for status in [401, 402, 403, 404, 429, 500] {
            let client = KinopoiskClient(key: "test-key", transport: { _, _, _ in HTTPPayload(status: status, data: Data("secret body".utf8)) })
            var failed = false
            do { _ = try await client.search("Фильм") } catch { failed = true; #expect(!error.localizedDescription.contains("secret body")) }
            #expect(failed)
        }
        let bad = KinopoiskClient(key: "test-key", transport: { _, _, _ in HTTPPayload(status: 200, data: Data("<html>".utf8)) })
        var failed = false
        do { _ = try await bad.search("Фильм") } catch { failed = true }
        #expect(failed)
        #expect(throws: (any Error).self) { _ = try PosterImage(data: Data("<svg/>".utf8)) }
        #expect(throws: (any Error).self) { _ = try PosterImage(data: Data(repeating: 0, count: KinopoiskClient.posterLimit + 1)) }
        let slow = KinopoiskClient(key: "test-key", transport: { _, _, _ in try await Task.sleep(for: .seconds(20)); return HTTPPayload(status: 200, data: Data()) })
        let task = Task { try await slow.search("Фильм") }; task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test("Selected tags and poster survive queue/project roundtrip; sources, translations and unselected fields stay intact")
    @MainActor func importing() async throws {
        let tools = try EngineTests().tools(), fixture = try Fixture()
        defer { fixture.remove() }
        let original = try await fixture.original(tools: tools), before = try Data(contentsOf: original)
        let file = try await ToolLocator.identify(original, tools: tools)
        let image = try Data(contentsOf: fixture.cover)
        let recorder = RequestRecorder()
        let client = KinopoiskClient(key: "test-key", transport: { request, _, _ in
            await recorder.add(request); return HTTPPayload(status: 200, data: image)
        })
        let state = AppState(persistenceEnabled: false); state.tools = tools; state.project.files = [file]
        state.project.title = "Исходное внутреннее название"
        state.project.tagEdits = TagEdits(language: "ru", values: ["DIRECTOR": "Свой режиссёр"])
        let details = try Self.details()
        try await state.applyKinopoisk(details, selection: .init(fields: ["TITLE", "DIRECTOR", "DESCRIPTION"], poster: false), client: client, sourceID: file.id, generation: state.metadataGeneration)
        let noPosterRequests = await recorder.requests
        #expect(noPosterRequests.isEmpty)
        #expect(state.project.tagEdits?.values["DIRECTOR"] == "Свой режиссёр")
        #expect((state.tagValues["DIRECTOR"] ?? "").isEmpty)
        #expect(state.project.tagEdits?.values["ACTOR"] == nil && state.project.title == "Исходное внутреннее название")
        try await state.applyKinopoisk(details, selection: .init(fields: ["DATE_RELEASED"], poster: true, containerTitle: true, onlyEmpty: false), client: client, sourceID: file.id, generation: state.metadataGeneration, posterRoot: fixture.directory.appendingPathComponent("posters"))
        #expect(state.project.title == "Проверочный фильм" && state.project.attachments.count == 1)
        let attachment = state.project.attachments[0]
        #expect(try Data(contentsOf: attachment.url) == image)
        #expect(try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(state.project)) == state.project)
        state.project.outputPath = fixture.directory.appendingPathComponent("online.mkv").path
        let job = try MKVCommandBuilder.makeJob(project: state.project, tools: tools)
        try state.addJob(job); state.clearSources(); await state.execute(job.id)
        #expect(state.jobs[0].state == .finished, state.jobs[0].log)
        let result = try await ToolLocator.identify(job.output, tools: tools)
        #expect(result.attachments.count == file.attachments.count + 1 && result.title == "Проверочный фильм")
        let tags = try await MetadataService.readTags(job.output, executable: tools.mkvextract)
        let values = try tags.values(language: "ru")
        #expect(values["TITLE"] == "Проверочный фильм" && values["DIRECTOR"] == "Свой режиссёр")
        #expect(values["DESCRIPTION"] == "Описание & текст <кино>" && values["DATE_RELEASED"] == "1999")
        #expect(values["ACTOR"] == "")
        let cover = result.attachments.last!
        let extracted = fixture.directory.appendingPathComponent("downloaded-cover.png")
        _ = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [job.output.path, "attachments", "\(cover.sourceID):\(extracted.path)"])
        #expect(try Data(contentsOf: extracted) == image)
        for track in file.tracks {
            let a = fixture.directory.appendingPathComponent("before-\(track.sourceID).bin"), b = fixture.directory.appendingPathComponent("after-\(track.sourceID).bin")
            _ = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [original.path, "tracks", "\(track.sourceID):\(a.path)"])
            _ = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [job.output.path, "tracks", "\(track.sourceID):\(b.path)"])
            #expect(try Data(contentsOf: a) == Data(contentsOf: b))
        }
        #expect(try Data(contentsOf: original) == before)
    }
    @Test("Series scope, language conflicts, stale workspaces and failed poster download are atomic")
    @MainActor func atomicity() async throws {
        let tools = try EngineTests().tools(), fixture = try Fixture(); defer { fixture.remove() }
        let file = try await ToolLocator.identify(try await fixture.original(tools: tools), tools: tools)
        let state = AppState(persistenceEnabled: false); state.tools = tools; state.project.files = [file]
        let details = try Self.details(series: true)
        let client = KinopoiskClient(key: "test-key", transport: { _, _, _ in HTTPPayload(status: 500, data: Data()) })
        let before = state.project
        var failed = false
        do { try await state.applyKinopoisk(details, selection: .init(fields: ["TITLE"], poster: true), client: client, sourceID: file.id, generation: state.metadataGeneration) }
        catch { failed = true }
        #expect(failed && state.project == before)
        let generation = state.metadataGeneration; state.clearSources()
        var cancelled = false
        do { try await state.applyKinopoisk(details, selection: .init(fields: ["TITLE"]), client: client, sourceID: file.id, generation: generation) }
        catch is CancellationError { cancelled = true }
        #expect(cancelled)
        let xml = try MatroskaTags(xml: "<Tags><Tag><Targets/><Simple><Name>TITLE</Name><TagLanguageIETF>ru</TagLanguageIETF><String>Название эпизода</String></Simple></Tag></Tags>")
        let patched = try MatroskaTags(xml: xml.applying(TagEdits(language: "ru", targetTypeValue: 70, values: details.fields)))
        #expect(try patched.values(language: "ru")["TITLE"] == "Название эпизода")
        #expect(try patched.values(language: "ru", scope: 70)["TITLE"] == "Проверочный фильм")
        state.project.files = [file]; state.project.tagEdits = TagEdits(language: "en", values: ["TITLE": "Keep"])
        failed = false
        do { try await state.applyKinopoisk(details, selection: .init(fields: ["TITLE"]), client: client, sourceID: file.id, generation: state.metadataGeneration) } catch { failed = true }
        #expect(failed && state.project.tagEdits?.values["TITLE"] == "Keep")
    }
    @Test("Actual URLSession bounds, redirect refusal and cancellation on local fixture server")
    func http() async throws {
        guard let base = ProcessInfo.processInfo.environment["MKVSTUDIO_HTTP_FIXTURE"] else { return }
        func request(_ path: String) -> URLRequest { URLRequest(url: URL(string: base + path)!) }
        let normal = try await BoundedHTTP.load(request("/ok"), limit: 64, poster: false)
        #expect(normal.status == 200 && String(data: normal.data, encoding: .utf8) == "okay")
        for path in ["/large-header", "/large-chunks"] {
            var failed = false
            do { _ = try await BoundedHTTP.load(request(path), limit: 64, poster: false) } catch { failed = true }
            #expect(failed)
        }
        let redirect = try await BoundedHTTP.load(request("/redirect"), limit: 64, poster: false)
        #expect(redirect.status == 302)
        let slow = Task { try await BoundedHTTP.load(request("/slow"), limit: 64, poster: false) }
        try await Task.sleep(for: .milliseconds(100)); slow.cancel()
        await #expect(throws: CancellationError.self) { try await slow.value }
    }
}
actor RequestRecorder {
    var requests: [URLRequest] = []
    func add(_ request: URLRequest) { requests.append(request) }
}
