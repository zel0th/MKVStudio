import AppKit
import Observation

extension AppState {
    var chapterEditionIndex: Int { project.chapterDocument?.editions.firstIndex { $0.id == selectedEditionID } ?? 0 }
    var chapterRows: [ChapterEntry.Row] {
        guard let document = project.chapterDocument, document.editions.indices.contains(chapterEditionIndex) else { return [] }
        return document.editions[chapterEditionIndex].chapters.flatMap { $0.flattened() }
    }
    var selectedChapter: ChapterEntry? { chapterRows.first { $0.id == selectedChapterID }?.entry }
    var timelineDuration: Double {
        let media = project.mode == .append ? files.reduce(0) { $0 + $1.durationSeconds } : files.map(\.durationSeconds).max() ?? 0
        return min(35_999_999, max(1, media, (chapterRows.map { $0.entry.seconds }.max() ?? 0) + 1))
    }
    func chooseTool(_ name: String) {
        let panel = NSOpenPanel(); panel.message = "Выберите исполняемый файл \(name)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { errorMessage = "Этот файл нельзя запустить."; return }
        var paths = UserDefaults.standard.dictionary(forKey: "consoleToolPaths") as? [String: String] ?? [:]
        paths[name] = url.path
        UserDefaults.standard.set(paths, forKey: "consoleToolPaths")
        Task { await detectTools() }
    }
    func toolPath(_ name: String) -> String {
        if let explicit = (UserDefaults.standard.dictionary(forKey: "consoleToolPaths") as? [String: String])?[name] { return explicit }
        return tools?.executables.first { $0.lastPathComponent == name }?.path ?? "Не найден"
    }
    func moveFile(_ id: UUID, offset: Int) {
        guard let index = project.files.firstIndex(where: { $0.id == id }), project.files.indices.contains(index + offset) else { return }
        project.files.swapAt(index, index + offset)
    }
    func updateChapters(_ edit: (inout [ChapterEntry]) -> Void) {
        if project.chapterDocument == nil { project.chapterDocument = ChapterDocument() }
        guard project.chapterDocument!.editions.indices.contains(chapterEditionIndex) else { return }
        edit(&project.chapterDocument!.editions[chapterEditionIndex].chapters)
    }
    func updateChapter(_ id: UUID, _ edit: (inout ChapterEntry) -> Void) {
        updateChapters { ChapterEntry.update(&$0, id: id, edit: edit) }
    }
    func addChapter(child: Bool = false) {
        let entry = ChapterEntry(start: selectedChapter?.start ?? "00:00:00.000000000", name: "Глава \(chapterRows.count + 1)")
        if child, let selectedChapterID { updateChapter(selectedChapterID) { $0.children.append(entry) } }
        else { updateChapters { $0.append(entry) } }
        selectedChapterID = entry.id
        project.useChapterEditor = true
    }
    func removeChapter() {
        guard let selectedChapterID else { return }
        updateChapters { ChapterEntry.remove(&$0, id: selectedChapterID) }
        self.selectedChapterID = chapterRows.first?.id
    }
    func moveChapter(_ offset: Int) {
        guard let selectedChapterID else { return }
        updateChapters { ChapterEntry.move(&$0, id: selectedChapterID, offset: offset) }
    }
    func addEdition() {
        if project.chapterDocument == nil { project.chapterDocument = ChapterDocument() }
        let edition = ChapterEdition()
        project.chapterDocument!.editions.append(edition)
        selectedEditionID = edition.id; selectedChapterID = nil
    }
    func importChapterDocument() {
        let panel = NSOpenPanel(); panel.message = "Импорт XML Matroska или текста CHAPTER01 / CHAPTER01NAME заменит главы в редакторе."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { setChapters(try ChapterDocument.parse(Data(contentsOf: url))) } catch { report(error) }
    }
    func setChapters(_ document: ChapterDocument) {
        project.chapterDocument = document; project.useChapterEditor = true
        selectedEditionID = document.editions.first?.id; selectedChapterID = chapterRows.first?.id
    }
    func extractChapters() {
        guard let file = selectedFile, file.isMatroska, let tools, !isLoadingChapters else { return }
        isLoadingChapters = true
        Task {
            defer { isLoadingChapters = false }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MKVStudio-chapters-\(UUID().uuidString).xml")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let result = try await ProcessRunner.run(executable: tools.mkvextract, arguments: ["--ui-language", "en_US", file.url.path, "chapters", url.path])
                guard result.exitCode <= 1 else { throw StudioError.message(result.output) }
                setChapters(try ChapterDocument.parse(Data(contentsOf: url)))
            } catch { report(error) }
        }
    }
    func exportChapters() {
        do {
            let xml = try (project.chapterDocument ?? ChapterDocument()).xml()
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Главы.xml"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try xml.write(to: url, atomically: true, encoding: .utf8)
        } catch { report(error) }
    }
}
