import Foundation
import Testing
@testable import MKVStudio

@MainActor struct BundledToolsTests {
    @Test("A complete bundled toolset wins over host tools, with explicit overrides and fail-closed damage detection")
    func discovery() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let suite = "MKVStudio-bundled-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite), "Isolated defaults")
        defer { defaults.removePersistentDomain(forName: suite) }
        let bundle = fixture.directory.appendingPathComponent("Приложение с пробелами.app")
        let directory = bundle.appendingPathComponent(ToolLocator.bundledRelativePath)
        let external = fixture.directory.appendingPathComponent("external")
        for folder in [directory, external] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ToolLocator.names {
                let path = folder.appendingPathComponent(name)
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            }
        }
        let bundled = try #require(ToolLocator.discover(defaults: defaults, bundleURL: bundle, searchDirectories: [external.path]), "Bundled tools")
        #expect(bundled.executables.allSatisfy { $0.deletingLastPathComponent().path == directory.path })
        // No system installation or PATH is needed.
        #expect(ToolLocator.discover(defaults: defaults, bundleURL: bundle, searchDirectories: []) != nil)
        defaults.set(["mkvinfo": external.appendingPathComponent("mkvinfo").path], forKey: "consoleToolPaths")
        #expect(ToolLocator.discover(defaults: defaults, bundleURL: bundle)?.mkvinfo.deletingLastPathComponent().path == external.path)
        defaults.set(["mkvinfo": "/missing/explicit/mkvinfo"], forKey: "consoleToolPaths")
        #expect(ToolLocator.discover(defaults: defaults, bundleURL: bundle) == nil)
        defaults.removeObject(forKey: "consoleToolPaths")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("mkvinfo"))
        #expect(ToolLocator.discover(defaults: defaults, bundleURL: bundle, searchDirectories: [external.path]) == nil)
        try FileManager.default.removeItem(at: directory)
        #expect(ToolLocator.discover(defaults: defaults, bundleURL: bundle, searchDirectories: [external.path])?.mkvinfo.deletingLastPathComponent().path == external.path)
        let damaged = fixture.directory.appendingPathComponent("Damaged.app")
        try FileManager.default.createDirectory(at: damaged.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let marker = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": suite, "MKVStudioBundledTools": true], format: .xml, options: 0)
        try marker.write(to: damaged.appendingPathComponent("Contents/Info.plist"))
        #expect(ToolLocator.discover(defaults: defaults, bundleURL: damaged, searchDirectories: [external.path]) == nil)
    }

    @Test("Persisted queue executables and tag tools follow a relocated bundle without changing external selections")
    func relocation() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let tools = try EngineTests().tools()
        let bundle = fixture.directory.appendingPathComponent("Перенесённая программа.app")
        let directory = bundle.appendingPathComponent(ToolLocator.bundledRelativePath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, executable) in zip(ToolLocator.names, tools.executables) {
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(name), withDestinationURL: executable)
        }
        let old = URL(fileURLWithPath: "/Volumes/Old DMG/MKVStudio.app/" + ToolLocator.bundledRelativePath)
        let file = try await ToolLocator.identify(fixture.wave, tools: tools)
        var project = StudioProject(files: [file], outputPath: fixture.directory.appendingPathComponent("moved.mkv").path)
        project.tagEdits = TagEdits(values: ["TITLE": "После переноса"])
        var queued = try MKVCommandBuilder.makeJob(project: project, tools: tools)
        queued.executable = old.appendingPathComponent("mkvmerge")
        queued.tagOptions?.extract = old.appendingPathComponent("mkvextract")
        queued.tagOptions?.propedit = old.appendingPathComponent("mkvpropedit")
        let restored = try JSONDecoder().decode(QueueJob.self, from: JSONEncoder().encode(queued)).relocatingBundledTools(to: bundle)
        #expect(restored.executable == directory.appendingPathComponent("mkvmerge"))
        #expect(restored.tagOptions?.extract == directory.appendingPathComponent("mkvextract"))
        #expect(restored.tagOptions?.propedit == directory.appendingPathComponent("mkvpropedit"))
        let external = URL(fileURLWithPath: "/custom/bin/mkvmerge")
        #expect(ToolLocator.relocatedExecutable(external, bundleURL: bundle) == external)
        let state = AppState(persistenceEnabled: false); state.tools = tools
        try state.addJob(restored); await state.execute(restored.id)
        #expect(state.jobs.first?.state == .finished, state.jobs.first?.log ?? "Missing job")
        let tags = try await MetadataService.readTags(restored.output, executable: tools.mkvextract)
        #expect(try tags.values(language: "und")["TITLE"] == "После переноса")
    }
}
