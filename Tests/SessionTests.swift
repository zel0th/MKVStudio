import AppKit
import Testing
@testable import MKVStudio

@MainActor
struct SessionTests {
    private func source(_ name: String) -> MediaFileItem {
        MediaFileItem(url: URL(fileURLWithPath: "/tmp/\(name).mkv"), container: "Matroska",
                      durationSeconds: 60, size: 1024, title: name, tracks: [], attachments: [], chapterCount: 0)
    }

    @Test("Successful processing clears every editor and the next video has no previous metadata")
    func completedWorkspace() async throws {
        let tools = try EngineTests().tools(), fixture = try Fixture()
        defer { fixture.remove() }
        let original = try await fixture.withoutTags(tools: tools)
        let before = try Data(contentsOf: original)
        let file = try await ToolLocator.identify(original, tools: tools)
        for mode in 0..<5 {
            let state = AppState(persistenceEnabled: false); state.tools = tools; state.appearance = "dark"
            state.project = StudioProject(files: [file], title: "Previous title", outputPath: fixture.directory.appendingPathComponent("completed-\(mode).mkv").path)
            state.project.attachments = [AddedAttachment(url: fixture.cover, name: "extra.png", mimeType: "image/png")]
            state.project.tagEdits = TagEdits(language: "ru", values: ["TITLE": "Previous tag", "DATE_RELEASED": "1999"])
            state.setChapters(ChapterDocument(editions: [ChapterEdition(chapters: [ChapterEntry(name: "Previous chapter")])]))
            state.project.chaptersURL = fixture.subtitle // Inactive while the visual editor is enabled.
            state.selectedFileID = file.id; state.selectedTrackID = file.tracks[0].id
            state.tagValues = ["TITLE": "Cached title"]; state.tagsSourceID = file.id
            state.infoText = "Previous container information"
            await state.previewTags(file: file)
            let preview = try #require(state.previewURL, "Temporary preview before completion")
            if mode == 1 { var second = file; second.id = UUID(); state.project.files.append(second); state.project.assemblyMode = .append }
            if mode == 2 { state.project.splitOptions = SplitOptions(mode: .duration, value: "0.5s") }
            let job: QueueJob
            if mode == 3 { job = try MKVCommandBuilder.headerJob(file: file, title: state.project.title, output: URL(fileURLWithPath: state.project.outputPath), tools: tools) }
            else if mode == 4 { job = try MKVCommandBuilder.extractJob(file: file, track: file.tracks[0], outputDirectory: fixture.directory, tools: tools) }
            else { job = try MKVCommandBuilder.makeJob(project: state.project, tools: tools) }
            try state.addJob(job)
            await state.execute(job.id)
            #expect(state.jobs[0].state == .finished || state.jobs[0].state == .warning, state.jobs[0].log)
            #expect(state.project == StudioProject(), "All project fields must reset for operation \(mode)")
            #expect(state.tagValues.isEmpty && state.tagsSourceID == nil && state.previewURL == nil)
            #expect(!FileManager.default.fileExists(atPath: preview.path))
            #expect(state.selectedFileID == nil && state.selectedTrackID == nil && state.selectedChapterID == nil && state.selectedEditionID == nil)
            #expect(state.infoText == AppState(persistenceEnabled: false).infoText)
            #expect(state.selectedJobID == job.id && state.selectedSection == .queue && state.appearance == "dark")
            #expect(FileManager.default.fileExists(atPath: job.output.path))
            await state.importURLs([original]); await state.loadTags()
            #expect(state.project.title.isEmpty && state.project.outputPath == state.suggestOutput(original).path)
            #expect(state.project.tagEdits?.values.isEmpty == true && state.tagValues.values.allSatisfy(\.isEmpty))
            #expect(state.project.attachments.isEmpty && state.project.chapterDocument == nil && state.project.split.mode == .none)
        }
        #expect(try Data(contentsOf: original) == before)
    }

    /// A controlled child process makes changes during processing deterministic, without large media or timing guesses.
    private func controlledJob(in directory: URL, exitCode: Int = 0) throws -> (QueueJob, URL, URL) {
        let id = UUID().uuidString, stage = directory.appendingPathComponent("stage-\(id)")
        let gate = directory.appendingPathComponent("release-\(id)"), ready = directory.appendingPathComponent("ready-\(id)")
        let staged = stage.appendingPathComponent("result.mkv")
        let script = #"touch "$1"; while [ ! -e "$2" ]; do /bin/sleep 0.01; done; printf result > "$3"; exit "$4""#
        let job = QueueJob(title: "Controlled job", executable: URL(fileURLWithPath: "/bin/sh"),
                           arguments: ["-c", script, "test", ready.path, gate.path, staged.path, String(exitCode)],
                           output: directory.appendingPathComponent("result-\(id).mkv"), stagingDirectory: stage, stagedOutput: staged)
        return (job, gate, ready)
    }
    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw StudioError.message("Controlled process did not signal readiness")
    }

    @Test("Warnings clear completed work; failures, cancellation and publication errors preserve it")
    func completionOutcomes() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        for outcome in 0..<4 {
            let state = AppState(persistenceEnabled: false)
            state.project = StudioProject(files: [source("Original")], title: "Keep on failure", outputPath: "/tmp/chosen.mkv")
            state.project.tagEdits = TagEdits(values: ["TITLE": "Keep"])
            let expected = state.project
            let (job, gate, ready) = try controlledJob(in: fixture.directory, exitCode: outcome == 0 ? 1 : outcome == 1 ? 2 : 0)
            try state.addJob(job)
            let task = Task { await state.execute(job.id) }
            defer { try? Data().write(to: gate); state.stopQueue() }
            try await waitForFile(ready)
            if outcome == 2 { state.stopQueue() }
            if outcome == 3 { try Data("occupied".utf8).write(to: job.output) }
            try Data().write(to: gate)
            await task.value
            if outcome == 0 {
                #expect(state.jobs[0].state == .warning && state.project == StudioProject())
            } else {
                #expect(state.jobs[0].state == (outcome == 2 ? .cancelled : .failed), state.jobs[0].log)
                #expect(state.project == expected)
                if outcome == 3 { #expect(try String(contentsOf: job.output, encoding: .utf8) == "occupied") }
                else { #expect(!FileManager.default.fileExists(atPath: job.output.path)) }
            }
        }
    }

    @Test("Old queued work cannot clear a newer project or edits made during processing")
    func newerWorkSurvives() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let state = AppState(persistenceEnabled: false)
        state.project = StudioProject(files: [source("First")], title: "First", outputPath: "/tmp/first.mkv")
        let (first, firstGate, firstReady) = try controlledJob(in: fixture.directory)
        try state.addJob(first)
        state.project.title = "Second"; state.project.outputPath = "/tmp/second.mkv"
        let secondProject = state.project
        let (second, secondGate, _) = try controlledJob(in: fixture.directory)
        try state.addJob(second)
        try Data().write(to: firstGate); try Data().write(to: secondGate)
        await state.execute(first.id)
        #expect(state.project == secondProject && state.jobs[1].state == .waiting)
        await state.execute(second.id)
        #expect(state.project == StudioProject() && state.jobs.allSatisfy { $0.state == .finished })

        for change in 0..<4 {
            state.project = secondProject
            let (job, gate, ready) = try controlledJob(in: fixture.directory)
            try state.addJob(job)
            let task = Task { await state.execute(job.id) }
            defer { try? Data().write(to: gate); state.stopQueue() }
            try await waitForFile(ready)
            if change == 0 { state.project.tagEdits = TagEdits(values: ["TITLE": "Edited while running"]) }
            if change == 1 { state.resetWorkspace(); state.project = secondProject }
            if change == 2 { state.isImporting = true }
            // Merely opening the tag editor materializes an empty edit object; this is not a new edit.
            if change == 3 { state.project.tagEdits = TagEdits(language: "ru") }
            let expected = state.project
            try Data().write(to: gate); await task.value
            #expect(state.jobs.last?.state == .finished)
            #expect(state.project == (change == 3 ? StudioProject() : expected))
            state.isImporting = false
        }
        #expect(FileManager.default.fileExists(atPath: firstReady.path))
    }

    @Test("Late chapter and information reads cannot repopulate a cleared workspace")
    func lateReaders() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        for kind in 0..<4 {
            let ready = fixture.directory.appendingPathComponent("read-ready-\(kind)")
            let gate = fixture.directory.appendingPathComponent("read-release-\(kind)")
            let executable = fixture.directory.appendingPathComponent("read-\(kind).sh")
            func quote(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = """
            #!/bin/sh
            touch \(quote(ready))
            while [ ! -e \(quote(gate)) ]; do /bin/sleep 0.01; done
            if [ "$4" = chapters ]; then
                printf '<Chapters><EditionEntry><ChapterAtom><ChapterTimeStart>00:00:00.000</ChapterTimeStart></ChapterAtom></EditionEntry></Chapters>' > "$5"
            else
                printf 'Stale container information'
            fi
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            var tools = try EngineTests().tools(); tools.mkvextract = executable; tools.mkvinfo = executable
            let state = AppState(persistenceEnabled: false); state.tools = tools; state.project.files = [source("Old")]
            let task = Task { if kind % 2 == 0 { await state.extractChapters() } else { await state.readInfo() } }
            defer { try? Data().write(to: gate) }
            try await waitForFile(ready)
            if kind < 2 { state.resetWorkspace() } else { state.clearMetadata() }
            try Data().write(to: gate); await task.value
            if kind < 2 { #expect(state.project == StudioProject()) }
            #expect(state.chapterRows.isEmpty && state.errorMessage == nil)
            #expect(!state.isLoadingChapters && !state.isReadingInfo)
            #expect(state.infoText == AppState(persistenceEnabled: false).infoText)
        }
    }

    @Test("Removing the last input clears its title and destination without deleting edited chapters")
    func removeLastSource() throws {
        let state = AppState(persistenceEnabled: false)
        let first = source("First"), second = source("Second")
        state.project = StudioProject(files: [first, second], title: "Custom", outputPath: "/tmp/custom.mkv")
        state.setChapters(ChapterDocument())
        state.selectedFileID = first.id
        state.removeFile(first.id)
        #expect(state.project.outputPath == "/tmp/custom.mkv")
        #expect(state.selectedFileID == second.id)
        state.removeFile(second.id)
        #expect(state.files.isEmpty && state.project.outputPath.isEmpty && state.project.title.isEmpty)
        #expect(state.selectedFileID == nil && state.selectedTrackID == nil)
        #expect(state.project.chapterDocument != nil)
        #expect(!state.canMux)
    }

    @Test("A new session ignores old workspace autosaves and retains explicit projects, preferences and queue")
    func freshSession() throws {
        let suite = "MKVStudio-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite), "Isolated preferences")
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldProject = StudioProject(files: [source("Old")], title: "Old title", outputPath: "/tmp/old-output.mkv")
        let savedProject = try JSONEncoder().encode(oldProject)
        defaults.set(savedProject, forKey: "MKVStudio.workspace.v1")
        defaults.set("dark", forKey: "appearance")
        defaults.set(["mkvmerge": "/custom/bin/mkvmerge"], forKey: "consoleToolPaths")
        let state = AppState(defaults: defaults)
        let job = QueueJob(title: "Waiting", executable: URL(fileURLWithPath: "/usr/bin/true"),
                           arguments: [], output: URL(fileURLWithPath: "/tmp/result.mkv"),
                           stagingDirectory: URL(fileURLWithPath: "/tmp/staging"),
                           stagedOutput: URL(fileURLWithPath: "/tmp/staging/result.mkv"))
        try state.addJob(job)
        state.restorePreferencesAndQueue()
        #expect(state.project == StudioProject())
        #expect(defaults.data(forKey: "MKVStudio.workspace.v1") == nil)
        #expect(state.appearance == "dark")
        #expect(state.toolPath("mkvmerge") == "/custom/bin/mkvmerge")
        #expect(state.jobs.map(\.id) == [job.id])
        // Opening an explicitly saved project remains supported.
        state.project = try JSONDecoder().decode(StudioProject.self, from: savedProject)
        #expect(state.files.count == 1 && state.project.title == "Old title")
        state.finishSession()
        #expect(state.project == StudioProject())
        let relaunched = AppState(defaults: defaults)
        relaunched.restorePreferencesAndQueue()
        #expect(relaunched.project == StudioProject())
        #expect(relaunched.jobs.map(\.id) == [job.id])
        #expect(relaunched.appearance == "dark")
    }

    @Test("Tool dialogs prefer configured and detected executable directories")
    func toolDirectories() throws {
        let suite = "MKVStudio-tool-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite), "Isolated preferences")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let custom = root.appendingPathComponent("custom"), detected = root.appendingPathComponent("detected")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: detected, withIntermediateDirectories: true)
        defaults.set(["mkvextract": custom.appendingPathComponent("mkvextract").path], forKey: "consoleToolPaths")
        let executable = detected.appendingPathComponent("mkvextract")
        #expect(ToolLocator.selectionDirectory(for: "mkvextract", currentExecutable: executable, defaults: defaults).path == custom.path)
        #expect(ToolLocator.selectionDirectory(for: "mkvinfo", currentExecutable: executable, defaults: defaults).path == detected.path)
        #expect(ToolLocator.selectionDirectory(defaults: defaults).path == custom.path)
        defaults.removeObject(forKey: "consoleToolPaths")
        defaults.set(custom.path, forKey: "toolsPath")
        #expect(ToolLocator.selectionDirectory(defaults: defaults).path == custom.path)
        defaults.set("/missing/tools", forKey: "toolsPath")
        let fallback = ToolLocator.selectionDirectory(defaults: defaults)
        #expect(FileManager.default.fileExists(atPath: fallback.path))
        #expect(ToolLocator.standardDirectories.contains(fallback.path) || fallback.path == "/Applications")
    }

    @Test("Settings placement stays on the workspace display including negative display origins")
    func settingsPlacement() throws {
        let size = CGSize(width: 700, height: 678)
        for display in [CGRect(x: 0, y: 30, width: 1710, height: 1042),
                        CGRect(x: -1920, y: -800, width: 1920, height: 1080),
                        CGRect(x: 1710, y: 200, width: 1280, height: 800)] {
            let main = CGRect(x: display.minX + 20, y: display.minY + 10, width: 1200, height: 720)
            let result = SettingsWindowPlacement.frame(size: size, mainFrame: main, visibleFrame: display)
            #expect(display.contains(result))
            #expect(result.size == size)
        }
    }
}
