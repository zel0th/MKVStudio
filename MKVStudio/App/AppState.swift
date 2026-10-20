import AppKit
import Observation
import UniformTypeIdentifiers

extension UTType {
    static let studioProject = UTType(exportedAs: "com.zshfan.mkvstudio.project", conformingTo: .json)
}

@MainActor @Observable
final class AppState {
    var project = StudioProject()
    var selectedSection: StudioSection? = .workspace
    var selectedTrackID: UUID?
    var selectedFileID: UUID?
    var selectedJobID: UUID?
    var tools: ValidatedTools?
    var toolVersion = "Проверка инструментов…"
    var jobs: [QueueJob] = []
    var selectedChapterID: UUID?
    var selectedEditionID: UUID?
    var isLoadingChapters = false
    var isImporting = false
    var importLabel = ""
    var isInspectorVisible = true
    var isLogVisible = false
    var errorMessage: String?
    var infoText = "Выберите исходный Matroska-файл, чтобы изучить его структуру."
    var isReadingInfo = false
    var queueRunning = false
    var appearance = "system" {
        didSet { if persistenceEnabled { defaults.set(appearance, forKey: "appearance") } }
    }
    private var token: ProcessToken?
    @ObservationIgnored private let persistenceEnabled: Bool
    @ObservationIgnored let defaults: UserDefaults
    init(persistenceEnabled: Bool = true, defaults: UserDefaults = .standard) {
        self.persistenceEnabled = persistenceEnabled
        self.defaults = defaults
    }
    var activeProcessID: Int32? { token?.processIdentifier }
    private var bootstrapped = false
    private let historyKey = "MKVStudio.queue.v1"

    var files: [MediaFileItem] { project.files }
    var tracks: [TrackRow] { files.flatMap(\.tracks) }
    var selectedTrack: TrackRow? { tracks.first { $0.id == selectedTrackID } }
    var selectedFile: MediaFileItem? { files.first { $0.id == selectedFileID } ?? files.first }
    var trackSource: MediaFileItem? { files.first { $0.tracks.contains { $0.id == selectedTrackID } } }
    var activeJob: QueueJob? { jobs.first { $0.state == .running } }
    var waitingCount: Int { jobs.filter { $0.state == .waiting }.count }
    var selectedJob: QueueJob? { jobs.first { $0.id == selectedJobID } ?? jobs.last }
    var canMux: Bool { tools != nil && tracks.contains(where: \.included) && !isImporting }

    func bootstrap() async {
        guard !bootstrapped else { return }; bootstrapped = true
        restorePreferencesAndQueue()
        await detectTools()
    }
    func restorePreferencesAndQueue() {
        // A workspace belongs to this session. Only explicitly saved project files reopen it.
        resetWorkspace()
        if persistenceEnabled { defaults.removeObject(forKey: "MKVStudio.workspace.v1") }
        appearance = defaults.string(forKey: "appearance") ?? "system"
        if let data = defaults.data(forKey: historyKey), let saved = try? JSONDecoder().decode([QueueJob].self, from: data) {
            jobs = saved.map { job in
                var job = job
                if job.state == .running { job.state = .failed; job.log += "\nПриложение было закрыто во время выполнения. Временные данные: \(job.stagingDirectory.path)" }
                return job
            }
        }
    }
    func detectTools() async {
        tools = ToolLocator.discover(defaults: defaults)
        guard let tools else { toolVersion = "Консольные утилиты не найдены"; return }
        do {
            var mergeVersion = ""
            for (name, executable) in zip(ToolLocator.names, tools.executables) {
                let result = try await ProcessRunner.run(executable: executable, arguments: ["--version"], outputLimit: 4096)
                guard result.exitCode == 0, result.output.hasPrefix(name + " v") else { throw StudioError.message("Не удалось проверить \(name). Выберите исполняемый файл этой консольной утилиты.") }
                if name == "mkvmerge" { mergeVersion = result.output.components(separatedBy: .whitespacesAndNewlines).dropFirst().first ?? "" }
            }
            toolVersion = "mkvmerge " + mergeVersion

        } catch { self.tools = nil; toolVersion = "Инструменты недоступны"; report(error) }
    }
    func chooseTools() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Выберите папку с mkvmerge, mkvinfo, mkvextract и mkvpropedit."
        panel.directoryURL = ToolLocator.selectionDirectory(currentExecutable: tools?.mkvmerge, defaults: defaults)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try ToolLocator.validate(directory: url)
            defaults.set(url.path, forKey: "toolsPath")
            defaults.removeObject(forKey: "consoleToolPaths")
            Task { await detectTools() }
        } catch { report(error) }
    }
    func importFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.message = "Добавьте видео, аудио или субтитры в сборку."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importURLs(urls) }
    }
    func importURLs(_ urls: [URL]) async {
        guard !isImporting else { return }
        guard let tools else { errorMessage = "Укажите пути к консольным утилитам в настройках."; return }
        isImporting = true
        defer { isImporting = false; importLabel = "" }
        var failures: [String] = []
        for url in urls where url.isFileURL {
            guard !files.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { continue }
            importLabel = url.lastPathComponent
            do {
                let file = try await ToolLocator.identify(url, tools: tools)
                project.files.append(file)
                if project.files.count == 1 {
                    project.title = file.title
                    project.outputPath = suggestOutput(url).path
                    selectedFileID = file.id; selectedTrackID = file.tracks.first?.id
                }
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        selectedSection = .workspace
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
    }
    func suggestOutput(_ input: URL) -> URL {
        let parent = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        var number = 1
        var url = parent.appendingPathComponent("\(base) — сборка.mkv")
        while FileManager.default.fileExists(atPath: url.path) {
            number += 1; url = parent.appendingPathComponent("\(base) — сборка \(number).mkv")
        }
        return url
    }
    func updateTrack(_ id: UUID, _ edit: (inout TrackRow) -> Void) {
        for f in project.files.indices {
            if let t = project.files[f].tracks.firstIndex(where: { $0.id == id }) { edit(&project.files[f].tracks[t]); return }
        }
    }
    func moveTrack(_ id: UUID, offset: Int) {
        for f in project.files.indices {
            if let t = project.files[f].tracks.firstIndex(where: { $0.id == id }) {
                let destination = t + offset
                guard project.files[f].tracks.indices.contains(destination) else { return }
                project.files[f].tracks.swapAt(t, destination); return
            }
        }
    }
    func removeFile(_ id: UUID) {
        guard files.contains(where: { $0.id == id }) else { return }
        project.files.removeAll { $0.id == id }
        if files.isEmpty {
            // Keep deliberately edited chapters/attachments, but discard the previous source's identity.
            project.title = ""
            project.outputPath = ""
            infoText = "Выберите исходный Matroska-файл, чтобы изучить его структуру."
        }
        if selectedTrack == nil { selectedTrackID = tracks.first?.id }
        if !files.contains(where: { $0.id == selectedFileID }) { selectedFileID = files.first?.id }
    }
    func chooseOutput() {
        guard !files.isEmpty else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: project.outputPath).lastPathComponent
        if !project.outputPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: project.outputPath).deletingLastPathComponent() }
        panel.allowedContentTypes = [UTType(filenameExtension: "mkv") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        project.outputPath = url.path
    }
    func addAttachments() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            project.attachments.append(AddedAttachment(url: url, name: url.lastPathComponent, mimeType: type))
        }
    }
    func chooseChapters() {
        let panel = NSOpenPanel(); panel.message = "Главы в формате XML Matroska или простом текстовом формате глав."
        guard panel.runModal() == .OK else { return }; project.chaptersURL = panel.url
    }
    func enqueue(start: Bool) {
        guard let tools else { return }
        do {
            let job = try MKVCommandBuilder.makeJob(project: project, tools: tools)
            try addJob(job)
            if start { startQueue() }
        } catch { report(error) }
    }
    func addJob(_ job: QueueJob) throws {
        guard !jobs.contains(where: { ($0.state == .waiting || $0.state == .running) && $0.output.standardizedFileURL == job.output.standardizedFileURL }) else {
            throw StudioError.message("Задание с этим файлом результата уже есть в очереди.")
        }
        jobs.append(job); selectedJobID = job.id; selectedSection = .queue; saveHistory()
    }
    func startQueue() {
        guard !queueRunning else { return }
        queueRunning = true
        Task {
            while queueRunning, let id = jobs.first(where: { $0.state == .waiting })?.id { await execute(id) }
            queueRunning = false
        }
    }
    func stopQueue() { queueRunning = false; token?.cancel() }
    func cancelWaiting(_ id: UUID) { guard jobs.first(where: { $0.id == id })?.state == .waiting else { return }; updateJob(id) { $0.state = .cancelled }; saveHistory() }
    func execute(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let currentToken = ProcessToken(); token = currentToken
        updateJob(id) { $0.state = .running; $0.progress = 0; $0.log = "" }; saveHistory()
        defer { token = nil; saveHistory() }
        do {
            guard !FileManager.default.fileExists(atPath: job.output.path) else { throw StudioError.message("Файл результата уже существует. Исходные данные не изменены.") }
            try MKVCommandBuilder.prepare(job)
            if let source = job.copySource {
                try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: source, to: job.stagedOutput) }.value
                if currentToken.isCancelled { throw CancellationError() }
            }
            let buffer = ProcessOutputBuffer()
            let updates = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
                    self?.receive(buffer.drain(), for: id)
                }
            }
            defer { updates.cancel() }
            let result = try await ProcessRunner.run(executable: job.executable, arguments: job.arguments, token: currentToken, outputLimit: 1_048_576) { buffer.append($0) }
            receive(buffer.drain(), for: id)
            guard result.exitCode <= 1 else { throw StudioError.message(result.output) }
            try MKVCommandBuilder.publish(job)
            updateJob(id) { $0.state = result.exitCode == 1 ? .warning : .finished; $0.progress = 1; $0.log = String(result.output.suffix(100_000)) }
            try? FileManager.default.removeItem(at: job.stagingDirectory)
        } catch {
            let cancelled = error is CancellationError
            updateJob(id) { $0.state = cancelled ? .cancelled : .failed; $0.log += "\n\(cancelled ? "Операция отменена." : error.localizedDescription)"; $0.log = String($0.log.suffix(100_000)) }
            // Only this job's unique temporary directory is removed.
            try? FileManager.default.removeItem(at: job.stagingDirectory)
        }
    }
    private func receive(_ lines: [String], for id: UUID) {
        guard !lines.isEmpty else { return }
        guard jobs.first(where: { $0.id == id })?.state == .running else { return }
        updateJob(id) { job in
          for line in lines {
            if line.hasPrefix("#GUI#progress "), let value = Double(line.dropFirst(14).replacingOccurrences(of: "%", with: "")) { job.progress = min(1, max(0, value / 100)) }
            if !line.hasPrefix("#GUI#progress") {
                job.log += line + "\n"
                if job.log.count > 100_000 { job.log = String(job.log.suffix(100_000)) }
            }
          }
        }
    }
    private func updateJob(_ id: UUID, _ edit: (inout QueueJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }; edit(&jobs[i])
    }
    func resetWorkspace() {
        project = StudioProject()
        selectedTrackID = nil; selectedFileID = nil
        selectedChapterID = nil; selectedEditionID = nil
        selectedSection = .workspace
        infoText = "Выберите исходный Matroska-файл, чтобы изучить его структуру."
    }
    func finishSession() {
        resetWorkspace()
        if persistenceEnabled { defaults.removeObject(forKey: "MKVStudio.workspace.v1") }
        saveHistory()
    }
    private func saveHistory() {
        guard persistenceEnabled else { return }
        if let data = try? JSONEncoder().encode(jobs) { defaults.set(data, forKey: historyKey) }
    }
    func clearFinishedJobs() {
        jobs.removeAll { $0.state != .running && $0.state != .waiting }; saveHistory()
    }
    func extractSelectedTrack() {
        guard let file = trackSource, let track = selectedTrack, let tools else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.message = "Для дорожки будет создана отдельная папка."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try addJob(MKVCommandBuilder.extractJob(file: file, track: track, outputDirectory: url, tools: tools)); startQueue() }
        catch { report(error) }
    }
    func editHeaders() {
        guard let tools, let file = selectedFile else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = file.url.deletingPathExtension().lastPathComponent + " — заголовки.mkv"
        panel.message = "Изменить название, языки и флаги дорожек в отдельной копии. Состав дорожек и задержки не меняются."
        guard panel.runModal() == .OK, let output = panel.url else { return }
        do { try addJob(MKVCommandBuilder.headerJob(file: file, title: project.title, output: output, tools: tools)); startQueue() }
        catch { report(error) }
    }
    func readInfo() async {
        guard let tools, let file = selectedFile, !isReadingInfo else { return }
        isReadingInfo = true; defer { isReadingInfo = false }
        do {
            let result = try await ProcessRunner.run(executable: tools.mkvinfo, arguments: ["--ui-language", "en_US", file.url.path], outputLimit: 2_097_152)
            guard result.exitCode <= 1 else { throw StudioError.message(result.output) }
            infoText = result.output
        } catch { infoText = error.localizedDescription }
    }
    func saveProject() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Проект.mkvstudio"; panel.canCreateDirectories = true
        panel.allowedContentTypes = [.studioProject]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(project).write(to: url, options: .atomic) }
        catch { report(error) }
    }
    func openProject() {
        guard !isImporting else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.studioProject]
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try JSONDecoder().decode(StudioProject.self, from: Data(contentsOf: url))
            guard loaded.version == 1 else { throw StudioError.message("Версия проекта не поддерживается.") }
            project = loaded; selectedTrackID = tracks.first?.id; selectedFileID = files.first?.id; selectedSection = .workspace
        } catch { report(error) }
    }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func report(_ error: any Error) { errorMessage = error.localizedDescription }
}

enum StudioSection: String, CaseIterable, Identifiable {
    case workspace, output, chapters, attachments, information, queue
    var id: Self { self }
    var title: String {
        switch self { case .workspace: "Сборка"; case .output: "Склейка и разбиение"; case .chapters: "Редактор глав"; case .attachments: "Вложения"; case .information: "Информация"; case .queue: "Очередь заданий" }
    }
    var symbol: String {
        switch self { case .workspace: "square.stack.3d.up"; case .output: "scissors"; case .chapters: "list.bullet.indent"; case .attachments: "paperclip"; case .information: "info.circle"; case .queue: "list.bullet.rectangle" }
    }
}
