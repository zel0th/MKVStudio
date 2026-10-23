import Foundation
import Testing
@testable import MKVStudio

struct Fixture {
    let directory: URL
    let wave: URL
    let subtitle: URL
    let cover: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MKVStudio-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        wave = directory.appendingPathComponent("Звук $name ' one.wav")
        subtitle = directory.appendingPathComponent("English.srt")
        cover = directory.appendingPathComponent("cover.png")
        var wav = Data()
        func text(_ value: String) { wav.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        let count: UInt32 = 48000 * 2
        text("RIFF"); u32(36 + count); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16); text("data"); u32(count)
        wav.append(Data(repeating: 0, count: Int(count)))
        try wav.write(to: wave)
        try "1\n00:00:00,000 --> 00:00:00,900\nMKVStudio — проверка\n\n".write(to: subtitle, atomically: true, encoding: .utf8)
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZlV8AAAAASUVORK5CYII=")!.write(to: cover)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func original(tools: ValidatedTools) async throws -> URL {
        let url = directory.appendingPathComponent("Исходный фильм.mkv")
        let result = try await ProcessRunner.run(executable: tools.mkvmerge, arguments: ["-o", url.path, "--language", "0:ru", wave.path, "--language", "0:en", subtitle.path, "--attachment-mime-type", "image/png", "--attach-file", cover.path])
        #expect(result.exitCode == 0, "\(result.output)")
        return url
    }
    func withoutTags(tools: ValidatedTools) async throws -> URL {
        let url = try await original(tools: tools)
        let removed = try await ProcessRunner.run(executable: tools.mkvpropedit, arguments: [url.path, "--tags", "all:"])
        #expect(removed.exitCode == 0, removed.output)
        let extracted = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [url.path, "tags"])
        #expect(extracted.exitCode == 0 && extracted.output.isEmpty, "Fixture must contain no Tags element")
        return url
    }
}

@Suite("Console utilities integration")
struct EngineTests {
    func tools() throws -> ValidatedTools {
        if let path = ProcessInfo.processInfo.environment["MKVSTUDIO_TOOLS_DIRECTORY"] {
            return try ToolLocator.validate(directory: URL(fileURLWithPath: path))
        }
        return try #require(ToolLocator.discover(), "Build the standalone app or provide console tools before running integration tests")
    }

    @Test("Remux preserves streams and attachments, applies real track options")
    func remux() async throws {
        let tools = try tools(); let fixture = try Fixture(); defer { fixture.remove() }
        let original = try await fixture.original(tools: tools)
        let originalData = try Data(contentsOf: original)
        var file = try await ToolLocator.identify(original, tools: tools)
        #expect(file.tracks.count == 2); #expect(file.attachments.count == 1)
        file.tracks[0].name = "Русский звук ' $value"; file.tracks[0].language = "ja"; file.tracks[0].defaultTrack = false
        file.tracks[1].forced = true
        let output = fixture.directory.appendingPathComponent("Результат с пробелами.mkv")
        var project = StudioProject(files: [file], title: "Тестовый фильм", outputPath: output.path)
        project.attachments = [AddedAttachment(url: fixture.cover, name: "second cover.png", mimeType: "image/png")]
        let job = try MKVCommandBuilder.makeJob(project: project, tools: tools)
        try FileManager.default.createDirectory(at: job.stagingDirectory, withIntermediateDirectories: false)
        let result = try await ProcessRunner.run(executable: job.executable, arguments: job.arguments)
        #expect(result.exitCode == 0, "\(result.output)")
        try MKVCommandBuilder.publish(job)
        let actual = try await ToolLocator.identify(output, tools: tools)
        #expect(actual.title == "Тестовый фильм")
        #expect(actual.tracks.count == 2); #expect(actual.attachments.count == 2)
        #expect(actual.tracks[0].name == "Русский звук ' $value")
        #expect(actual.tracks[0].language == "ja"); #expect(!actual.tracks[0].defaultTrack)
        #expect(actual.tracks[1].forced)
        #expect(try Data(contentsOf: original) == originalData)
        for index in 0..<2 {
            let before = fixture.directory.appendingPathComponent("before-\(index).bin")
            let after = fixture.directory.appendingPathComponent("after-\(index).bin")
            let a = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [original.path, "tracks", "\(index):\(before.path)"])
            let b = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [output.path, "tracks", "\(index):\(after.path)"])
            #expect(a.exitCode == 0 && b.exitCode == 0)
            #expect(try Data(contentsOf: before) == Data(contentsOf: after))
        }
        let attachment = fixture.directory.appendingPathComponent("extracted-cover.png")
        _ = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [output.path, "attachments", "\(actual.attachments[0].sourceID):\(attachment.path)"])
        #expect(try Data(contentsOf: attachment) == Data(contentsOf: fixture.cover))
    }

    @Test("Excluding audio removes it rather than selecting all tracks")
    func excludeTrack() async throws {
        let tools = try tools(); let fixture = try Fixture(); defer { fixture.remove() }
        let original = try await fixture.original(tools: tools)
        var file = try await ToolLocator.identify(original, tools: tools)
        file.tracks[0].included = false
        file.attachments[0].included = false
        let output = fixture.directory.appendingPathComponent("subtitles.mkv")
        let project = StudioProject(files: [file], outputPath: output.path)
        let result = try await ProcessRunner.run(executable: tools.mkvmerge, arguments: MKVCommandBuilder.remux(project: project, output: output))
        #expect(result.exitCode == 0, "\(result.output)")
        let actual = try await ToolLocator.identify(output, tools: tools)
        #expect(actual.tracks.count == 1); #expect(actual.tracks.first?.kind == .subtitles); #expect(actual.attachments.isEmpty)
    }

    @Test("Extract and edit headers use mkvextract and mkvpropedit")
    func extractAndHeaders() async throws {
        let tools = try tools(); let fixture = try Fixture(); defer { fixture.remove() }
        let original = try await fixture.original(tools: tools)
        let before = try Data(contentsOf: original)
        var file = try await ToolLocator.identify(original, tools: tools)
        file.tracks[1].name = "Перевод"; file.tracks[1].language = "ru"; file.tracks[1].forced = true
        // Reorder UI rows: edits still target the track UID, not its current row.
        file.tracks.reverse()
        let headers = try MKVCommandBuilder.headerJob(file: file, title: "Новое название", output: fixture.directory.appendingPathComponent("headers.mkv"), tools: tools)
        try FileManager.default.createDirectory(at: headers.stagingDirectory, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: original, to: headers.stagedOutput)
        let h = try await ProcessRunner.run(executable: headers.executable, arguments: headers.arguments)
        #expect(h.exitCode == 0, "\(h.output)")
        try MKVCommandBuilder.publish(headers)
        let actual = try await ToolLocator.identify(headers.output, tools: tools)
        #expect(actual.title == "Новое название")
        #expect(actual.tracks[1].name == "Перевод"); #expect(actual.tracks[1].forced)
        #expect(try Data(contentsOf: original) == before)
        let info = try await ProcessRunner.run(executable: tools.mkvinfo, arguments: [headers.output.path])
        #expect(info.exitCode == 0); #expect(info.output.contains("Новое название"))
        let extraction = try MKVCommandBuilder.extractJob(file: actual, track: actual.tracks[1], outputDirectory: fixture.directory, tools: tools)
        try FileManager.default.createDirectory(at: extraction.stagedOutput, withIntermediateDirectories: true)
        let e = try await ProcessRunner.run(executable: extraction.executable, arguments: extraction.arguments)
        #expect(e.exitCode == 0)
        try MKVCommandBuilder.publish(extraction)
        let text = try String(contentsOf: extraction.output.appendingPathComponent("track-1.srt"), encoding: .utf8)
        #expect(text.contains("MKVStudio — проверка"))
    }

    @Test("Input aliases and existing outputs cannot be overwritten")
    func outputSafety() async throws {
        let tools = try tools(); let fixture = try Fixture(); defer { fixture.remove() }
        let file = try await ToolLocator.identify(fixture.wave, tools: tools)
        let project = StudioProject(files: [file], outputPath: fixture.wave.path)
        #expect(throws: (any Error).self) { try MKVCommandBuilder.validate(project) }
        let alias = fixture.directory.appendingPathComponent("alias.mkv")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.wave)
        #expect(throws: (any Error).self) { try MKVCommandBuilder.validate(StudioProject(files: [file], outputPath: alias.path)) }
        let out = fixture.directory.appendingPathComponent("existing.mkv")
        let job = try MKVCommandBuilder.makeJob(project: StudioProject(files: [file], outputPath: out.path), tools: tools)
        try FileManager.default.createDirectory(at: job.stagingDirectory, withIntermediateDirectories: false)
        try Data("staged".utf8).write(to: job.stagedOutput)
        try Data("valuable".utf8).write(to: out)
        #expect(throws: (any Error).self) { try MKVCommandBuilder.publish(job) }
        #expect(try String(contentsOf: out, encoding: .utf8) == "valuable")
    }

    @Test("Projects retain editing state and real source paths")
    func persistence() async throws {
        let tools = try tools(); let fixture = try Fixture(); defer { fixture.remove() }
        var file = try await ToolLocator.identify(fixture.wave, tools: tools)
        file.tracks[0].delayMS = -500; file.tracks[0].included = false
        let project = StudioProject(files: [file], title: "Проект")
        let restored = try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project))
        #expect(restored.files == project.files)
        #expect(restored.title == "Проект")
    }

    @Test("Video, audio and subtitles with repeated source track IDs combine correctly")
    func multipleSources() async throws {
        let tools = try tools(); let fixture = try Fixture(); defer { fixture.remove() }
        let defaultSample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Samples/Видео.mp4").path
        let sample = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MKVSTUDIO_SAMPLE_PATH"] ?? defaultSample)
        var video = try await ToolLocator.identify(sample, tools: tools)
        var audio = try await ToolLocator.identify(fixture.wave, tools: tools)
        var subtitles = try await ToolLocator.identify(fixture.subtitle, tools: tools)
        video.tracks[0].name = "Видео"; audio.tracks[0].name = "Аудио"; subtitles.tracks[0].name = "Субтитры"
        let output = fixture.directory.appendingPathComponent("combined.mkv")
        let project = StudioProject(files: [video, audio, subtitles], outputPath: output.path)
        let result = try await ProcessRunner.run(executable: tools.mkvmerge, arguments: MKVCommandBuilder.remux(project: project, output: output))
        #expect(result.exitCode == 0, "\(result.output)")
        let actual = try await ToolLocator.identify(output, tools: tools)
        #expect(actual.tracks.map(\.kind) == [.video, .audio, .subtitles])
        #expect(actual.tracks.map(\.name) == ["Видео", "Аудио", "Субтитры"])
    }

    @Test("No shell interpretation and no deadlock on large output")
    func processOutput() async throws {
        let args = ["' $(touch /tmp/unwanted) ; русский"]
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: args)
        #expect(result.output.trimmingCharacters(in: .newlines) == args[0])
        let flood = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/seq"), arguments: ["1", "30000"])
        #expect(flood.exitCode == 0); #expect(flood.output.hasSuffix("30000\n"))
    }

    @Test("Cancelling stops a running child process")
    func cancellation() async throws {
        let token = ProcessToken()
        let task = Task { try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], token: token) }
        try await Task.sleep(for: .milliseconds(100))
        token.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Append maps tracks explicitly and doubles duration without re-encoding")
    func appendFiles() async throws {
        let tools = try tools(), fixture = try Fixture(); defer { fixture.remove() }
        let original = try await fixture.original(tools: tools)
        let copy = fixture.directory.appendingPathComponent("Part 2.mkv")
        try FileManager.default.copyItem(at: original, to: copy)
        let a = try await ToolLocator.identify(original, tools: tools), b = try await ToolLocator.identify(copy, tools: tools)
        var project = StudioProject(files: [a, b], outputPath: fixture.directory.appendingPathComponent("joined.mkv").path)
        project.assemblyMode = .append
        let job = try MKVCommandBuilder.makeJob(project: project, tools: tools)
        try await run(job)
        let result = try await ToolLocator.identify(job.output, tools: tools)
        #expect(result.tracks.count == 2)
        #expect(abs(result.durationSeconds - 2 * a.durationSeconds) < 0.01)
        let raw = fixture.directory.appendingPathComponent("joined.wav")
        let extracted = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [job.output.path, "tracks", "0:\(raw.path)"])
        #expect(extracted.exitCode == 0)
        let data = try pcm(raw), input = try pcm(fixture.wave)
        #expect(data == input + input)
        project.files[1].tracks.removeLast()
        #expect(throws: (any Error).self) { try MKVCommandBuilder.validate(project) }
    }

    @Test("Split modes produce atomic directories with real parts")
    func splitFiles() async throws {
        let tools = try tools(), fixture = try Fixture(); defer { fixture.remove() }
        let original = try await fixture.original(tools: tools)
        var source = try await ToolLocator.identify(original, tools: tools)
        source.tracks[1].included = false
        let before = try Data(contentsOf: original)
        for (mode, value) in [(SplitMode.duration, "0.25s"), (.size, "30000"), (.timestamps, "0.25s,0.5s"), (.parts, "0s-0.25s,+0.5s-0.75s")] {
            var project = StudioProject(files: [source], outputPath: fixture.directory.appendingPathComponent("\(mode.rawValue).mkv").path)
            project.splitOptions = SplitOptions(mode: mode, value: value)
            let job = try MKVCommandBuilder.makeJob(project: project, tools: tools)
            try await run(job)
            let parts = try FileManager.default.contentsOfDirectory(at: job.output, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mkv" }.sorted { $0.path < $1.path }
            #expect(parts.count >= (mode == .parts ? 1 : 2))
            #expect(parts.allSatisfy { $0.lastPathComponent.hasPrefix("part") })
            var combined = Data()
            for (i, part) in parts.enumerated() {
                let raw = fixture.directory.appendingPathComponent("\(mode)-\(i).wav")
                let result = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [part.path, "tracks", "0:\(raw.path)"])
                #expect(result.exitCode == 0)
                combined += try pcm(raw)
            }
            if mode != .parts { #expect(combined == (try pcm(fixture.wave))) }
            else { #expect(combined.count > 30000 && combined.count < 80000) }
            #expect(try Data(contentsOf: original) == before)
            #expect(throws: (any Error).self) { _ = try MKVCommandBuilder.makeJob(project: project, tools: tools) }
        }
        var invalid = SplitOptions(mode: .timestamps, value: "2s,1s")
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = SplitOptions(mode: .parts, value: "0s-2s,1s-3s")
        #expect(throws: (any Error).self) { try invalid.validate() }
    }

    @Test("Chapter editor preserves editions, nested nodes, languages and flags")
    func chapters() async throws {
        let tools = try tools(), fixture = try Fixture(); defer { fixture.remove() }
        let original = try await fixture.original(tools: tools)
        let source = try await ToolLocator.identify(original, tools: tools)
        let xml = """
        <?xml version="1.0"?><Chapters><EditionEntry><EditionUID>42</EditionUID><EditionFlagDefault>1</EditionFlagDefault>
        <ChapterAtom><ChapterUID>100</ChapterUID><ChapterTimeStart>00:00:00.000000001</ChapterTimeStart><ChapterFlagHidden>1</ChapterFlagHidden>
        <ChapterDisplay><ChapterString>Old</ChapterString><ChapterLanguage>eng</ChapterLanguage></ChapterDisplay>
        <ChapterDisplay><ChapterString>別名</ChapterString><ChapterLanguage>jpn</ChapterLanguage></ChapterDisplay>
        <ChapterAtom><ChapterUID>101</ChapterUID><ChapterTimeStart>00:00:00.250000000</ChapterTimeStart><ChapterDisplay><ChapterString>Child</ChapterString></ChapterDisplay></ChapterAtom>
        </ChapterAtom><ChapterAtom><ChapterUID>102</ChapterUID><ChapterTimeStart>00:00:00.500000000</ChapterTimeStart><ChapterDisplay><ChapterString>Second</ChapterString></ChapterDisplay></ChapterAtom></EditionEntry></Chapters>
        """
        var doc = try ChapterDocument.parse(Data(xml.utf8))
        doc.editions[0].chapters[0].name = "Вступление & <начало>"
        doc.editions[0].chapters[0].language = "ru"
        let rendered = try doc.xml()
        #expect(rendered.contains("<ChapterUID>101</ChapterUID>"))
        #expect(rendered.contains("<ChapterFlagHidden>1</ChapterFlagHidden>"))
        #expect(rendered.contains("別名"))
        #expect(rendered.contains("00:00:00.000000001"))
        let reparsed = try ChapterDocument.parse(Data(rendered.utf8))
        #expect(reparsed.editions[0].chapters[0].children.count == 1)
        #expect(reparsed.editions[0].chapters[0].name == "Вступление & <начало>")
        var project = StudioProject(files: [source], outputPath: fixture.directory.appendingPathComponent("chapters.mkv").path)
        project.chapterDocument = doc; project.useChapterEditor = true
        let job = try MKVCommandBuilder.makeJob(project: project, tools: tools)
        // The queued XML is a snapshot independent of later editor changes.
        project.chapterDocument!.editions[0].chapters[0].name = "Later"
        try await run(job)
        let exported = fixture.directory.appendingPathComponent("extracted.xml")
        let extract = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [job.output.path, "chapters", exported.path])
        #expect(extract.exitCode == 0)
        let actual = try ChapterDocument.parse(Data(contentsOf: exported))
        #expect(actual.editions[0].chapters[0].name == "Вступление & <начало>")
        #expect(actual.editions[0].chapters[0].language == "ru")
        #expect(actual.editions[0].chapters[0].children.count == 1)
        project.outputPath = fixture.directory.appendingPathComponent("chapter-parts.mkv").path
        project.chapterDocument!.editions[0].chapters[0].start = "00:00:00.000000000"
        project.splitOptions = SplitOptions(mode: .chapters, value: "all")
        let split = try MKVCommandBuilder.makeJob(project: project, tools: tools)
        try await run(split)
        let parts = try FileManager.default.contentsOfDirectory(at: split.output, includingPropertiesForKeys: nil)
        #expect(parts.count == 2, "Chapter split count: \(parts.map(\.lastPathComponent)); log \(split.arguments)")
        let simple = try ChapterDocument.parse(Data("CHAPTER01=00:00:00.000\nCHAPTER01NAME=Привет\n".utf8))
        #expect(simple.editions[0].chapters[0].name == "Привет")
        #expect(throws: (any Error).self) { _ = try ChapterDocument.parse(Data("<!DOCTYPE Chapters [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><Chapters/>".utf8)) }
    }

    @Test("HDR metadata changes while the encoded video is identical")
    func hdrMetadata() async throws {
        let tools = try tools(), fixture = try Fixture(); defer { fixture.remove() }
        let videoURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MKVSTUDIO_SAMPLE_PATH"] ?? "Samples/Видео.mp4")
        var video = try await ToolLocator.identify(videoURL, tools: tools)
        video.tracks[0].hdr = ["color-matrix-coefficients": "9", "color-transfer-characteristics": "16", "color-primaries": "9", "color-range": "1", "color-bits-per-channel": "10", "max-content-light": "1000", "max-frame-light": "400", "chromaticity-coordinates": "0.68,0.32,0.265,0.69,0.15,0.06", "white-color-coordinates": "0.3127,0.3290", "max-luminance": "1000", "min-luminance": "0.005"]
        let project = StudioProject(files: [video], outputPath: fixture.directory.appendingPathComponent("hdr.mkv").path)
        let job = try MKVCommandBuilder.makeJob(project: project, tools: tools)
        try await run(job)
        let result = try await ProcessRunner.run(executable: tools.mkvmerge, arguments: ["-J", job.output.path])
        let json = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as! [String: Any]
        let properties = (json["tracks"] as! [[String: Any]])[0]["properties"] as! [String: Any]
        #expect(properties["color_transfer_characteristics"] as? Int == 16)
        #expect(properties["color_primaries"] as? Int == 9)
        #expect(properties["max_content_light"] as? Int == 1000)
        #expect(properties["max_frame_light"] as? Int == 400)
        #expect(abs((properties["min_luminance"] as? Double ?? -1) - 0.005) < 0.0001)
        var plain = project; plain.files[0].tracks[0].hdr = nil; plain.outputPath = fixture.directory.appendingPathComponent("plain.mkv").path
        let unmodified = try MKVCommandBuilder.makeJob(project: plain, tools: tools); try await run(unmodified)
        let a = fixture.directory.appendingPathComponent("a.h264"), b = fixture.directory.appendingPathComponent("b.h264")
        _ = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [job.output.path, "tracks", "0:\(a.path)"])
        _ = try await ProcessRunner.run(executable: tools.mkvextract, arguments: [unmodified.output.path, "tracks", "0:\(b.path)"])
        #expect(try Data(contentsOf: a) == Data(contentsOf: b))
        #expect(throws: (any Error).self) { try HDRField.validate(["max-luminance": "nan"]) }
        #expect(throws: (any Error).self) { try HDRField.validate(["chromaticity-coordinates": "2,0,0,0,0,0"]) }
    }

    @Test("Version one projects and history still load without the new optional fields")
    func legacyPersistence() async throws {
        let project = try JSONDecoder().decode(StudioProject.self, from: Data("{\"version\":1,\"files\":[],\"attachments\":[],\"title\":\"Old\",\"outputPath\":\"\"}".utf8))
        #expect(project.mode == .multiplex); #expect(!project.split.enabled); #expect(project.chapterDocument == nil)
        #expect(try MediaTime.nanoseconds("9999:59:59.999999999") == 35_999_999_999_999_999)
        #expect(throws: (any Error).self) { _ = try MediaTime.nanoseconds("999999999999999s") }
    }


    @Test("Output capture and UI mailbox stay bounded with newline-free and noisy output")
    func boundedOutput() async throws {
        let buffer = ProcessOutputBuffer()
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "4194304", "/dev/zero"], outputLimit: 65536) { buffer.append($0) }
        #expect(result.exitCode == 0)
        #expect(result.output.utf8.count < 66000)
        #expect(buffer.drain().reduce(0) { $0 + $1.utf8.count } <= 100000)
        for index in 0..<30000 { buffer.append("Diagnostic line \(index)"); buffer.append("#GUI#progress \(index % 101)%") }
        let lines = buffer.drain()
        #expect(lines.last == "#GUI#progress 2%")
        #expect(lines.joined().utf8.count <= 100030)
        #expect(buffer.drain().isEmpty)
    }

    @Test("Console tools can be located in four independent directories")
    func independentTools() async throws {
        let tools = try tools(), fixture = try Fixture(); defer { fixture.remove() }
        var paths: [String: String] = [:]
        for (index, name) in ToolLocator.names.enumerated() {
            let directory = fixture.directory.appendingPathComponent("tool-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let path = directory.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: tools.executables[index])
            paths[name] = path.path
        }
        let separate = try ToolLocator.validate(paths: paths)
        let actual = try await ToolLocator.identify(fixture.wave, tools: separate)
        #expect(actual.tracks.first?.kind == .audio)
        paths["mkvinfo"] = "/missing/mkvinfo"
        #expect(throws: (any Error).self) { _ = try ToolLocator.validate(paths: paths) }
    }

    private func run(_ job: QueueJob) async throws {
        defer { try? FileManager.default.removeItem(at: job.stagingDirectory) }
        try MKVCommandBuilder.prepare(job)
        let result = try await ProcessRunner.run(executable: job.executable, arguments: job.arguments)
        #expect(result.exitCode <= 1, result.output)
        try MKVCommandBuilder.publish(job)
    }
    private func pcm(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= data.count {
            let size = Int(data[offset+4]) | Int(data[offset+5]) << 8 | Int(data[offset+6]) << 16 | Int(data[offset+7]) << 24
            if String(decoding: data[offset..<offset+4], as: UTF8.self) == "data" { return data.subdata(in: offset+8..<min(data.count,offset+8+size)) }
            offset += 8 + size + (size % 2)
        }
        throw StudioError.message("Missing WAV data")
    }

}
