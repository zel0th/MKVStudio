import Foundation

enum MKVCommandBuilder {
    static func validate(_ project: StudioProject) throws {
        guard !project.files.isEmpty, project.files.contains(where: { $0.tracks.contains(where: \.included) }) else {
            throw StudioError.message("Добавьте файл и выберите хотя бы одну дорожку.")
        }
        guard !project.outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioError.message("Выберите, куда сохранить MKV.")
        }
        let output = destination(project).standardizedFileURL.resolvingSymlinksInPath()
        try project.split.validate()
        if project.useChapterEditor == true { _ = try project.chapterDocument?.xml() }
        if project.mode == .append { try validateAppend(project) }
        let inputs = project.files.map(\.url) + project.attachments.map(\.url) + (project.useChapterEditor == true ? [] : [project.chaptersURL].compactMap { $0 })
        for input in inputs {
            guard FileManager.default.isReadableFile(atPath: input.path) else { throw StudioError.message("Файл недоступен: \(input.path)") }
            guard input.standardizedFileURL.resolvingSymlinksInPath() != output else { throw StudioError.message("Файл результата совпадает с исходным. Выберите другое имя.") }
        }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw StudioError.message("Файл уже существует. Выберите новое имя, чтобы сохранить обе версии.") }
        for track in project.files.flatMap(\.tracks) where track.included {
            if track.kind == .video { try HDRField.validate(track.hdr) }
            guard !track.language.isEmpty, track.language.range(of: "^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$", options: .regularExpression) != nil else {
                throw StudioError.message("Укажите код языка, например ru, en, ja или und.")
            }
        }
    }

    static func remux(project: StudioProject, output: URL, chaptersOverride: URL? = nil) -> [String] {
        var args = ["--ui-language", "en_US", "--gui-mode", "-o", output.path, "--title", project.title]
        if let chapters = chaptersOverride ?? project.chaptersURL { args += ["--chapters", chapters.path] }
        if project.split.enabled {
            args += ["--split", project.split.specification]
            if project.split.maxFiles > 0 { args += ["--split-max-files", String(project.split.maxFiles)] }
            if project.split.linkFiles { args += ["--link"] }
        }
        if project.mode == .append, project.files.count > 1 {
            args += ["--append-mode", "file"]
            var mappings: [String] = []
            for i in 1..<project.files.count {
                let previous = project.files[i - 1].tracks.filter(\.included)
                for (source, target) in zip(project.files[i].tracks.filter(\.included), previous) {
                    mappings.append("\(i):\(source.sourceID):\(i - 1):\(target.sourceID)")
                }
            }
            args += ["--append-to", mappings.joined(separator: ",")]
        }
        let order = project.files.enumerated().flatMap { index, file in
            (project.mode == .append && index > 0 ? [] : file.tracks.filter(\.included)).map { "\(index):\($0.sourceID)" }
        }
        args += ["--track-order", order.joined(separator: ",")]
        for (fileIndex, file) in project.files.enumerated() {
            for kind in TrackKind.allCases {
                let ids = file.tracks.filter { $0.kind == kind && $0.included }.map { String($0.sourceID) }
                args += ids.isEmpty ? [kind.exclusionOption] : [kind.selectionOption, ids.joined(separator: ",")]
            }
            for track in file.tracks where track.included {
                let id = track.sourceID
                args += ["--language", "\(id):\(track.language)", "--track-name", "\(id):\(track.name)", "--default-track-flag", "\(id):\(track.defaultTrack ? 1 : 0)", "--forced-display-flag", "\(id):\(track.forced ? 1 : 0)"]
                if track.kind == .video && (project.mode != .append || fileIndex == 0) { args += HDRField.arguments(track.hdr, id: id) }
                if track.delayMS != 0 { args += ["--sync", "\(id):\(track.delayMS)"] }
            }
            if !file.includeChapters || project.chaptersURL != nil || chaptersOverride != nil { args += ["--no-chapters"] }
            if !file.includeTags { args += ["--no-global-tags", "--no-track-tags"] }
            let attachments = file.attachments.filter(\.included).map { String($0.sourceID) }
            args += attachments.isEmpty ? ["--no-attachments"] : ["--attachments", attachments.joined(separator: ",")]
            // '=' disables automatic discovery of similarly numbered input files.
            if project.mode == .append && fileIndex > 0 { args += ["+"] }
            args += ["=", file.url.path]
        }
        for attachment in project.attachments {
            args += ["--attachment-mime-type", attachment.mimeType, "--attachment-name", attachment.name, "--attach-file", attachment.url.path]
        }
        return args
    }

    static func makeJob(project: StudioProject, tools: ValidatedTools) throws -> QueueJob {
        try validate(project)
        let output = destination(project)
        let stage = output.deletingLastPathComponent().appendingPathComponent(".mkvstudio-\(UUID().uuidString)", isDirectory: true)
        let staged = stage.appendingPathComponent(project.split.enabled ? "result" : output.lastPathComponent, isDirectory: project.split.enabled)
        // Never pass user-controlled printf patterns to split output naming.
        let muxOutput = project.split.enabled ? staged.appendingPathComponent("part.mkv") : staged
        let xml = project.useChapterEditor == true ? try (project.chapterDocument ?? ChapterDocument()).xml() : nil
        let chapterPath = xml == nil ? nil : stage.appendingPathComponent("chapters.xml")
        return QueueJob(title: output.lastPathComponent, executable: tools.mkvmerge, arguments: remux(project: project, output: muxOutput, chaptersOverride: chapterPath), output: output, stagingDirectory: stage, stagedOutput: staged, splitOutput: project.split.enabled, chapterXML: xml)
    }

    static func destination(_ project: StudioProject) -> URL {
        let file = URL(fileURLWithPath: project.outputPath)
        return project.split.enabled ? file.deletingPathExtension().appendingPathExtension("parts") : file
    }
    static func validateAppend(_ project: StudioProject) throws {
        guard project.files.count >= 2 else { throw StudioError.message("Для склейки добавьте минимум два файла.") }
        let base = project.files[0].tracks.filter(\.included)
        for file in project.files.dropFirst() {
            let tracks = file.tracks.filter(\.included)
            guard tracks.count == base.count, zip(tracks, base).allSatisfy({ $0.kind == $1.kind && $0.codecID == $1.codecID && $0.details == $1.details }) else {
                throw StudioError.message("«\(file.fileName)»: для склейки выберите одинаковые типы и число дорожек в одинаковом порядке, с совпадающими кодеками, разрешением и параметрами звука. Окончательную совместимость проверит mkvmerge.")
            }
        }
    }
    static func prepare(_ job: QueueJob) throws {
        guard !FileManager.default.fileExists(atPath: job.output.path) else { throw StudioError.message("Результат уже существует. Выберите другое имя.") }
        try FileManager.default.createDirectory(at: job.stagingDirectory, withIntermediateDirectories: false)
        if job.isExtraction || job.splitOutput == true { try FileManager.default.createDirectory(at: job.stagedOutput, withIntermediateDirectories: false) }
        if let xml = job.chapterXML { try xml.write(to: job.stagingDirectory.appendingPathComponent("chapters.xml"), atomically: true, encoding: .utf8) }
    }

    static func extractJob(file: MediaFileItem, track: TrackRow, outputDirectory: URL, tools: ValidatedTools) throws -> QueueJob {
        guard file.isMatroska else { throw StudioError.message("Для извлечения сначала соберите файл в Matroska.") }
        let base = file.url.deletingPathExtension().lastPathComponent
        let destination = outputDirectory.appendingPathComponent("\(base) — дорожка \(track.sourceID)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw StudioError.message("Папка извлечения уже существует. Выберите другую папку назначения.") }
        let stage = outputDirectory.appendingPathComponent(".mkvstudio-\(UUID().uuidString)", isDirectory: true)
        // All companion files (e.g. VobSub .idx/.sub) live inside the staged folder.
        let staged = stage.appendingPathComponent("result", isDirectory: true)
        let path = staged.appendingPathComponent("track-\(track.sourceID).\(track.extractionExtension)")
        return QueueJob(title: "Извлечь: \(track.name.isEmpty ? track.kind.title : track.name)", executable: tools.mkvextract, arguments: [file.url.path, "tracks", "\(track.sourceID):\(path.path)"], output: destination, stagingDirectory: stage, stagedOutput: staged, isExtraction: true)
    }

    static func headerJob(file: MediaFileItem, title: String, output: URL, tools: ValidatedTools) throws -> QueueJob {
        guard file.isMatroska else { throw StudioError.message("Правка заголовков доступна для Matroska.") }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw StudioError.message("Выберите новое имя файла.") }
        let stage = output.deletingLastPathComponent().appendingPathComponent(".mkvstudio-\(UUID().uuidString)", isDirectory: true)
        let staged = stage.appendingPathComponent(output.lastPathComponent)
        var args = ["--ui-language", "en_US", staged.path, "--edit", "info", "--set", "title=\(title)"]
        for track in file.tracks {
            guard let uid = track.uid else { throw StudioError.message("Не найден UID дорожки. Повторно импортируйте файл.") }
            args += ["--edit", "track:=\(uid)", "--set", "name=\(track.name)", "--set", "language=\(track.language)", "--set", "flag-default=\(track.defaultTrack ? 1 : 0)", "--set", "flag-forced=\(track.forced ? 1 : 0)"]
        }
        return QueueJob(title: "Заголовки: " + output.lastPathComponent, executable: tools.mkvpropedit, arguments: args, output: output, stagingDirectory: stage, stagedOutput: staged, copySource: file.url)
    }

    static func publish(_ job: QueueJob) throws {
        // moveItem refuses an existing destination, including a race after preflight.
        try FileManager.default.moveItem(at: job.stagedOutput, to: job.output)
    }
}
