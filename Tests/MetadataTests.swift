import Foundation
import Testing
@testable import MKVStudio

struct MetadataTests {
    let xml = """
    <Tags>
      <Tag><Targets><TargetTypeValue>50</TargetTypeValue></Targets>
        <Simple><Name>TITLE</Name><TagLanguage>und</TagLanguage><String>Old</String></Simple>
        <Simple><Name>TITLE</Name><TagLanguage>eng</TagLanguage><String>English</String></Simple>
        <Simple><Name>DIRECTOR</Name><TagLanguage>und</TagLanguage><String>Before</String><Simple><Name>URL</Name><String>https://example.org</String></Simple></Simple>
        <Simple><Name>_PRIVATE</Name><String>Keep</String></Simple>
      </Tag>
      <Tag><Targets><TargetTypeValue>70</TargetTypeValue></Targets><Simple><Name>TITLE</Name><TagLanguage>und</TagLanguage><String>Collection</String></Simple></Tag>
      <Tag><Targets><TrackUID>1234</TrackUID></Targets><Simple><Name>TITLE</Name><TagLanguage>und</TagLanguage><String>Track title</String></Simple></Tag>
    </Tags>
    """
    @Test("Standard edits preserve translations, targets, nested and unassigned tags")
    func preservation() throws {
        let tags = try MatroskaTags(xml: xml)
        let edits = TagEdits(values: ["TITLE": "Новое & <название>", "DIRECTOR": "Новый режиссёр", "ACTOR": "Первый\nВторой", "DATE_RELEASED": "1997", "RECORDING_LOCATION": "JP"])
        let changed = try MatroskaTags(xml: tags.applying(edits))
        let values = try changed.values(language: "und")
        #expect(values["TITLE"] == "Новое & <название>")
        #expect(values["ACTOR"] == "Первый\nВторой")
        #expect(try changed.values(language: "en")["TITLE"] == "English")
        for expected in ["https://example.org", "Keep", "Collection", "Track title", "1234"] { #expect(changed.xml.contains(expected)) }
        #expect(try tags.preferredLanguage() == "und")
        let english = try MatroskaTags(xml: tags.applying(TagEdits(language: "en", values: ["TITLE": "New English"])))
        #expect(try english.values(language: "en")["TITLE"] == "New English")
        #expect(try english.values(language: "und")["TITLE"] == "Old")
        #expect(TagEdits.validDate("2024-02-29") && !TagEdits.validDate("2023-02-29"))
        let deleted = try MatroskaTags(xml: changed.applying(TagEdits(values: ["TITLE": ""])))
        #expect(try deleted.values(language: "und")["TITLE"] == "")
        #expect(try deleted.values(language: "en")["TITLE"] == "English")
        #expect(throws: (any Error).self) { try TagEdits(values: ["FAKE_FIELD": "x"]).validate() }
        #expect(throws: (any Error).self) { try TagEdits(values: ["DATE_RELEASED": "yesterday"]).validate() }
        #expect(throws: (any Error).self) { try TagEdits(values: ["RECORDING_LOCATION": "Japan"]).validate() }
        #expect(throws: (any Error).self) { _ = try MatroskaTags(xml: "<!DOCTYPE Tags [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><Tags>&x;</Tags>") }
        #expect(throws: (any Error).self) { _ = try MatroskaTags(xml: "<Tags>" + String(repeating: " ", count: MatroskaTags.limit) + "</Tags>") }
    }

    @Test("Queued tag edits apply to remux, append and every split part without modifying sources")
    @MainActor func realTags() async throws {
        let tools = try EngineTests().tools(), fixture = try Fixture()
        defer { fixture.remove() }
        let original = try await fixture.original(tools: tools)
        var file = try await ToolLocator.identify(original, tools: tools)
        let sourceXML = xml.replacingOccurrences(of: "<TrackUID>1234</TrackUID>", with: "<TrackUID>\(file.tracks[0].uid!)</TrackUID>")
        let tagsURL = fixture.directory.appendingPathComponent("tags.xml")
        try sourceXML.write(to: tagsURL, atomically: true, encoding: .utf8)
        let added = try await ProcessRunner.run(executable: tools.mkvpropedit, arguments: [original.path, "--tags", "all:\(tagsURL.path)"])
        #expect(added.exitCode == 0, added.output)
        let before = try Data(contentsOf: original)
        file = try await ToolLocator.identify(original, tools: tools)
        for mode in 0..<3 {
            var second = file; second.id = UUID()
            let state = AppState(persistenceEnabled: false); state.tools = tools
            var project = StudioProject(files: mode == 1 ? [file, second] : [file], title: "Внутреннее название", outputPath: fixture.directory.appendingPathComponent("result-\(mode).mkv").path)
            if mode == 1 { project.assemblyMode = .append }
            if mode == 2 { project.splitOptions = SplitOptions(mode: .duration, value: "1s") }
            project.tagEdits = TagEdits(values: ["TITLE": "Новое название", "DIRECTOR": "Новый режиссёр", "DATE_RELEASED": "2001", "RECORDING_LOCATION": "JP", "ACTOR": "A\nB"])
            let job = try MKVCommandBuilder.makeJob(project: project, tools: tools)
            let roundtrip = try JSONDecoder().decode(QueueJob.self, from: JSONEncoder().encode(job))
            try state.addJob(roundtrip)
            state.project = project
            state.clearSources()
            #expect(state.files.isEmpty && state.project.title.isEmpty && state.project.outputPath.isEmpty && state.project.tagEdits == nil)
            #expect(state.jobs.count == 1)
            await state.execute(job.id)
            #expect(state.jobs[0].state == .finished, state.jobs[0].log)
            let results = mode == 2 ? try FileManager.default.contentsOfDirectory(at: job.output, includingPropertiesForKeys: nil) : [job.output]
            #expect(!results.isEmpty)
            for output in results {
                let tags = try await MetadataService.readTags(output, executable: tools.mkvextract)
                #expect(try tags.values(language: "und")["TITLE"] == "Новое название")
                #expect(try tags.values(language: "und")["ACTOR"] == "A\nB")
                #expect(tags.xml.contains("English") && tags.xml.contains("Track title") && tags.xml.contains("Keep") && tags.xml.contains("https://example.org"))
                let actual = try await ToolLocator.identify(output, tools: tools)
                #expect(actual.title == "Внутреннее название")
            }
            if mode == 0 {
                for track in file.tracks {
                    let a = fixture.directory.appendingPathComponent("before-\(track.sourceID).bin"), b = fixture.directory.appendingPathComponent("after-\(track.sourceID).bin")
                    _ = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [original.path, "tracks", "\(track.sourceID):\(a.path)"])
                    _ = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [job.output.path, "tracks", "\(track.sourceID):\(b.path)"])
                    #expect(try Data(contentsOf: a) == Data(contentsOf: b))
                }
            }
        }
        #expect(try Data(contentsOf: original) == before)
    }

    @Test("MKV without Tags supports the editor, preview and first tag write")
    @MainActor func absentTags() async throws {
        let tools = try EngineTests().tools(), fixture = try Fixture()
        defer { fixture.remove() }
        let source = try await fixture.withoutTags(tools: tools), before = try Data(contentsOf: source)
        let tags = try await MetadataService.readTags(source, executable: tools.mkvextract)
        #expect(try tags.values(language: "ru").values.allSatisfy(\.isEmpty))
        #expect(try tags.preferredLanguage() == "und")

        let file = try await ToolLocator.identify(source, tools: tools)
        let state = AppState(persistenceEnabled: false); state.tools = tools; state.project.files = [file]
        await state.loadTags()
        #expect(state.errorMessage == nil && state.tagsSourceID == file.id && !state.isLoadingTags)
        #expect(state.tagValues.values.allSatisfy(\.isEmpty))
        await state.previewTags(file: file)
        let preview = try #require(state.previewURL, "Empty tags XML preview")
        let previewTags = try MatroskaTags(xml: String(contentsOf: preview, encoding: .utf8))
        #expect(try previewTags.values(language: "ru").values.allSatisfy(\.isEmpty))
        state.dismissPreview()

        // Exercise first-write on a staged file with no Tags, before any remux adds statistics.
        state.project.outputPath = fixture.directory.appendingPathComponent("first-tags.mkv").path
        state.project.tagEdits = TagEdits(language: "ru", values: ["TITLE": "Первое название"])
        let job = try MKVCommandBuilder.makeJob(project: state.project, tools: tools)
        try MKVCommandBuilder.prepare(job)
        try FileManager.default.copyItem(at: source, to: job.stagedOutput)
        _ = try await MetadataService.applyTags(job, token: ProcessToken())
        let written = try await MetadataService.readTags(job.stagedOutput, executable: tools.mkvextract)
        #expect(try written.values(language: "ru")["TITLE"] == "Первое название")
        #expect(try Data(contentsOf: source) == before)

        // Empty successful extraction is supported; failed extraction and malformed XML still fail.
        var failed = false
        do { _ = try await MetadataService.readTags(fixture.directory.appendingPathComponent("missing.mkv"), executable: tools.mkvextract) }
        catch { failed = true }
        #expect(failed)
        #expect(throws: (any Error).self) { _ = try MatroskaTags(xml: "") }
        #expect(throws: (any Error).self) { _ = try MatroskaTags(xml: "<wrong-root/>") }
    }

    @Test("Attachment preview extraction is bounded and ignores path traversal in names")
    @MainActor func previews() async throws {
        let tools = try EngineTests().tools(), fixture = try Fixture()
        defer { fixture.remove() }
        let original = try await fixture.original(tools: tools)
        let file = try await ToolLocator.identify(original, tools: tools)
        var attachment = file.attachments[0]; attachment.name = "../../escape.png"
        let state = AppState(persistenceEnabled: false); state.tools = tools; state.project.files = [file]
        await state.previewAttachment(file: file, attachment: attachment)
        let url = try #require(state.previewURL, "Preview URL")
        let directory = try #require(state.previewDirectory, "Preview directory")
        #expect(url.deletingLastPathComponent() == directory)
        #expect(try Data(contentsOf: url) == Data(contentsOf: fixture.cover))
        state.dismissPreview()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(state.previewURL == nil)
        attachment.size = AttachmentPreview.limit + 1
        await state.previewAttachment(file: file, attachment: attachment)
        #expect(state.previewURL == nil && state.errorMessage != nil)
        state.errorMessage = nil
        await state.previewTags(file: file)
        #expect(state.previewURL?.pathExtension == "xml")
        let tagPath = try #require(state.previewURL, "Tags preview")
        state.clearSources()
        #expect(!FileManager.default.fileExists(atPath: tagPath.path))
        #expect(state.previewURL == nil)
    }
}
