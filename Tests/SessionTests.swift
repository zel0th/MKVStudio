import AppKit
import Testing
@testable import MKVStudio

@MainActor
struct SessionTests {
    private func source(_ name: String) -> MediaFileItem {
        MediaFileItem(url: URL(fileURLWithPath: "/tmp/\(name).mkv"), container: "Matroska",
                      durationSeconds: 60, size: 1024, title: name, tracks: [], attachments: [], chapterCount: 0)
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
