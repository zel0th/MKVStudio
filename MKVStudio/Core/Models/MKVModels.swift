import Foundation

enum TrackKind: String, Codable, CaseIterable, Sendable {
    case video, audio, subtitles, buttons
    var title: String {
        switch self { case .video: "Видео"; case .audio: "Аудио"; case .subtitles: "Субтитры"; case .buttons: "Кнопки" }
    }
    var symbol: String {
        switch self { case .video: "film"; case .audio: "waveform"; case .subtitles: "captions.bubble"; case .buttons: "rectangle.and.hand.point.up.left" }
    }
    var selectionOption: String { "--\(self == .subtitles ? "subtitle" : self == .buttons ? "button" : rawValue)-tracks" }
    var exclusionOption: String { "--no-\(rawValue)" }
}

struct TrackRow: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var sourceID: Int
    var uid: UInt64?
    var kind: TrackKind
    var codec: String
    var codecID: String
    var language: String
    var name: String
    var included = true
    var defaultTrack: Bool
    var forced: Bool
    var delayMS = 0
    var hdr: [String: String]?
    var details: String
    var extractionExtension: String {
        switch codecID {
        case "S_TEXT/UTF8": "srt"
        case "S_TEXT/ASS": "ass"
        case "S_TEXT/SSA": "ssa"
        case "S_HDMV/PGS": "sup"
        case "S_VOBSUB": "idx"
        case "A_AAC": "aac"
        case "A_AC3": "ac3"
        case "A_EAC3": "eac3"
        case "A_DTS": "dts"
        case "A_FLAC": "flac"
        case "A_OPUS", "A_VORBIS": "ogg"
        case "A_MPEG/L3": "mp3"
        case "A_PCM/INT/LIT", "A_PCM/INT/BIG", "A_PCM/FLOAT/IEEE": "wav"
        case "V_VP8", "V_VP9": "ivf"
        case "A_TRUEHD": "thd"
        case "V_MPEG4/ISO/AVC": "h264"
        case "V_MPEGH/ISO/HEVC": "h265"
        case "V_AV1": "ivf"
        default: "bin"
        }
    }
}

struct MediaAttachment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var sourceID: Int
    var name: String
    var mimeType: String
    var size: Int64
    var included = true
}

struct AddedAttachment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var url: URL
    var name: String
    var mimeType: String
}

struct MediaFileItem: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var url: URL
    var container: String
    var durationSeconds: Double
    var size: Int64
    var title: String
    var tracks: [TrackRow]
    var attachments: [MediaAttachment]
    var chapterCount: Int
    var includeChapters = true
    var includeTags = true
    var fileName: String { url.lastPathComponent }
    var fileSize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    var duration: String {
        guard durationSeconds.isFinite, durationSeconds > 0, durationSeconds < Double(Int.max) else { return "—" }
        let s = Int(durationSeconds)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
    var isMatroska: Bool { container.lowercased().contains("matroska") }

    static func identify(data: Data, url: URL) throws -> MediaFileItem {
        let document = try JSONDecoder().decode(Identification.self, from: data)
        guard document.container.recognized, document.container.supported else {
            throw StudioError.message("Формат файла «\(url.lastPathComponent)» не поддерживается mkvmerge.")
        }
        if let error = document.errors?.first { throw StudioError.message(error) }
        let tracks = try document.tracks.map { track -> TrackRow in
            guard let kind = TrackKind(rawValue: track.type) else { throw StudioError.message("Неизвестный тип дорожки: \(track.type)") }
            let p = track.properties
            let details = [p.pixel_dimensions, p.audio_channels.map { "\($0) кан." }, p.audio_sampling_frequency.map { "\(Int($0)) Гц" }].compactMap { $0 }.joined(separator: " · ")
            return TrackRow(sourceID: track.id, uid: p.uid, kind: kind, codec: track.codec, codecID: p.codec_id ?? "", language: p.language_ietf ?? p.language ?? "und", name: p.track_name ?? "", defaultTrack: p.default_track ?? false, forced: p.forced_track ?? false, details: details)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return MediaFileItem(url: url, container: document.container.type ?? "", durationSeconds: (document.container.properties?.duration ?? 0) / 1_000_000_000, size: Int64(size), title: document.container.properties?.title ?? "", tracks: tracks, attachments: (document.attachments ?? []).map { MediaAttachment(sourceID: $0.id, name: $0.file_name, mimeType: $0.content_type, size: $0.size) }, chapterCount: (document.chapters ?? []).reduce(0) { $0 + $1.num_entries })
    }
}

private struct Identification: Decodable {
    struct Container: Decodable {
        struct Properties: Decodable { var duration: Double?; var title: String? }
        var recognized: Bool; var supported: Bool; var type: String?; var properties: Properties?
    }
    struct Track: Decodable {
        struct Properties: Decodable {
            var uid: UInt64?; var codec_id: String?; var language: String?; var language_ietf: String?; var track_name: String?
            var default_track: Bool?; var forced_track: Bool?; var pixel_dimensions: String?
            var audio_channels: Int?; var audio_sampling_frequency: Double?
        }
        var id: Int; var type: String; var codec: String; var properties: Properties
    }
    struct Attachment: Decodable { var id: Int; var file_name: String; var content_type: String; var size: Int64 }
    struct Chapters: Decodable { var num_entries: Int }
    var container: Container; var tracks: [Track]; var attachments: [Attachment]?; var chapters: [Chapters]?; var errors: [String]?
}

struct StudioProject: Codable, Equatable, Sendable {
    var version = 1
    var files: [MediaFileItem] = []
    var attachments: [AddedAttachment] = []
    var title = ""
    var outputPath = ""
    var chaptersURL: URL?
    // Optional additions retain compatibility with saved version 1 projects.
    var assemblyMode: AssemblyMode?
    var splitOptions: SplitOptions?
    var chapterDocument: ChapterDocument?
    var useChapterEditor: Bool?
    var tagEdits: TagEdits?
    var mode: AssemblyMode { assemblyMode ?? .multiplex }
    var split: SplitOptions { splitOptions ?? SplitOptions() }
}

enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}
