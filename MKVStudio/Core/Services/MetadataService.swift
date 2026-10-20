import Foundation

struct TagJobOptions: Codable, Sendable {
    var edits: TagEdits
    var extract: URL
    var propedit: URL
}

enum MetadataService {
    static func readTags(_ source: URL, executable: URL, token: ProcessToken = ProcessToken()) async throws -> MatroskaTags {
        let result = try await ProcessRunner.run(executable: executable, arguments: ["--ui-language", "en_US", source.path, "tags"], token: token, outputLimit: MatroskaTags.limit)
        guard result.exitCode == 0 else { throw StudioError.message(result.output) }
        return try await Task.detached { try MatroskaTags(xml: result.output) }.value
    }
    /// Patch the tags extracted from the actual result, after mkvmerge has mapped track/chapter UIDs.
    static func applyTags(_ job: QueueJob, token: ProcessToken) async throws -> String {
        guard let options = job.tagOptions else { return "" }
        let files: [URL]
        if job.splitOutput == true {
            files = try FileManager.default.contentsOfDirectory(at: job.stagedOutput, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mkv" }.sorted { $0.path < $1.path }
        } else { files = [job.stagedOutput] }
        var warnings = ""
        for file in files {
            if token.isCancelled { throw CancellationError() }
            let original = try await readTags(file, executable: options.extract, token: token)
            let xml = try await Task.detached { try original.applying(options.edits) }.value
            let path = job.stagingDirectory.appendingPathComponent("tags.xml")
            try xml.write(to: path, atomically: true, encoding: .utf8)
            let result = try await ProcessRunner.run(executable: options.propedit, arguments: ["--ui-language", "en_US", file.path, "--tags", "all:\(path.path)"], token: token, outputLimit: 65536)
            guard result.exitCode <= 1 else { throw StudioError.message(result.output) }
            if result.exitCode == 1 { warnings += String(result.output.suffix(8192)) + "\n" }
        }
        return warnings
    }
}

/// One temporary preview at a time; never uses attachment names as extraction paths.
enum AttachmentPreview {
    static let limit: Int64 = 50 * 1024 * 1024
    static func checkSize(_ size: Int64) throws {
        guard size >= 0, size <= limit else { throw StudioError.message("Предпросмотр доступен для вложений до 50 МБ.") }
    }
    static func extract(file: MediaFileItem, attachment: MediaAttachment, tools: ValidatedTools, directory: URL, token: ProcessToken) async throws -> URL {
        try checkSize(attachment.size)
        let extensions = ["image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif", "text/xml": "xml", "application/xml": "xml", "text/plain": "txt", "application/json": "json", "application/pdf": "pdf", "font/ttf": "ttf", "font/otf": "otf"]
        let ext = extensions[attachment.mimeType] ?? "bin"
        let output = directory.appendingPathComponent("Вложение.\(ext)")
        let result = try await ProcessRunner.run(executable: tools.mkvextract, arguments: ["--ui-language", "en_US", file.url.path, "attachments", "\(attachment.sourceID):\(output.path)"], token: token, outputLimit: 65536)
        guard result.exitCode <= 1 else { throw StudioError.message(result.output) }
        try checkSize(Int64(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        return output
    }
}
