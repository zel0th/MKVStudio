import AppKit

extension AppState {
    func clearSources() {
        guard !isImporting else { return }
        project.files.removeAll()
        project.title = ""; project.outputPath = ""
        selectedFileID = nil; selectedTrackID = nil
        infoText = "Выберите исходный Matroska-файл, чтобы изучить его структуру."
        clearMetadata()
    }
    func clearMetadata() {
        metadataGeneration = UUID()
        metadataToken?.cancel(); metadataToken = nil
        isLoadingTags = false; tagsSourceID = nil; tagValues = [:]
        project.tagEdits = nil
        dismissPreview()
    }
    func loadTags() async {
        guard let file = files.first, let tools, !isLoadingTags else { return }
        if tagsSourceID == file.id { return }
        let generation = metadataGeneration, token = ProcessToken()
        metadataToken = token; isLoadingTags = true
        defer { if metadataGeneration == generation { isLoadingTags = false; metadataToken = nil } }
        do {
            let tags = try await file.isMatroska ? MetadataService.readTags(file.url, executable: tools.mkvextract, token: token) : MatroskaTags(xml: "<Tags/>")
            let language = try project.tagEdits?.language ?? tags.preferredLanguage()
            let values = try await Task.detached { try tags.values(language: language) }.value
            guard generation == metadataGeneration, files.first?.id == file.id else { return }
            if project.tagEdits == nil { project.tagEdits = TagEdits(language: language) }
            tagValues = values; tagsSourceID = file.id
        } catch {
            if generation == metadataGeneration, !(error is CancellationError) { report(error) }
        }
    }
    func setTag(_ key: String, value: String) {
        if project.tagEdits == nil { project.tagEdits = TagEdits() }
        if value == (tagValues[key] ?? "") { project.tagEdits?.values.removeValue(forKey: key) }
        else { project.tagEdits?.values[key] = value }
    }
    func setTagLanguage(_ language: String) {
        project.tagEdits = TagEdits(language: language)
        tagsSourceID = nil
        Task { await loadTags() }
    }
    func dismissPreview() {
        previewToken?.cancel(); previewToken = nil
        previewURL = nil; isPreparingPreview = false
        if let directory = previewDirectory { try? FileManager.default.removeItem(at: directory) }
        previewDirectory = nil
    }
    private func beginPreview() throws -> (URL, ProcessToken) {
        dismissPreview()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MKVStudio-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let token = ProcessToken()
        previewDirectory = directory; previewToken = token; isPreparingPreview = true
        return (directory, token)
    }
    func previewAddedAttachment(_ item: AddedAttachment) {
        do {
            try AttachmentPreview.checkSize(Int64(try item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
            dismissPreview(); previewURL = item.url
        } catch { report(error) }
    }
    func previewAttachment(file: MediaFileItem, attachment: MediaAttachment) async {
        guard let tools, !isPreparingPreview else { return }
        do {
            try AttachmentPreview.checkSize(attachment.size)
            let (directory, token) = try beginPreview()
            do {
                let url = try await AttachmentPreview.extract(file: file, attachment: attachment, tools: tools, directory: directory, token: token)
                guard previewDirectory == directory, !token.isCancelled else { try? FileManager.default.removeItem(at: directory); return }
                isPreparingPreview = false; previewURL = url
            } catch {
                try? FileManager.default.removeItem(at: directory)
                if previewDirectory == directory { dismissPreview(); if !(error is CancellationError) { report(error) } }
            }
        } catch { report(error) }
    }
    func previewTags(file: MediaFileItem) async {
        guard let tools, !isPreparingPreview else { return }
        do {
            let (directory, token) = try beginPreview()
            do {
                let tags = try await MetadataService.readTags(file.url, executable: tools.mkvextract, token: token)
                guard previewDirectory == directory, !token.isCancelled else { try? FileManager.default.removeItem(at: directory); return }
                let url = directory.appendingPathComponent("Теги.xml")
                try tags.xml.write(to: url, atomically: true, encoding: .utf8)
                isPreparingPreview = false; previewURL = url
            } catch {
                try? FileManager.default.removeItem(at: directory)
                if previewDirectory == directory { dismissPreview(); if !(error is CancellationError) { report(error) } }
            }
        } catch { report(error) }
    }
}
