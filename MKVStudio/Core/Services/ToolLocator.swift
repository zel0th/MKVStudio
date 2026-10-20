import Foundation

struct ValidatedTools: Sendable {
    var mkvmerge: URL
    var mkvinfo: URL
    var mkvextract: URL
    var mkvpropedit: URL
    var executables: [URL] { [mkvmerge, mkvinfo, mkvextract, mkvpropedit] }
}
enum ToolLocator {
    static let names = ["mkvmerge", "mkvinfo", "mkvextract", "mkvpropedit"]
    static let standardDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin",
        "/Library/Application Support/MKVStudio/ConsoleTools/bin"
    ]

    static func selectionDirectory(for name: String? = nil, currentExecutable: URL? = nil,
                                   defaults: UserDefaults = .standard) -> URL {
        let overrides = defaults.dictionary(forKey: "consoleToolPaths") as? [String: String] ?? [:]
        let selectedNames = name.map { [$0] } ?? names
        let explicit = selectedNames.compactMap { overrides[$0] }.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent()
        }
        let configured = defaults.string(forKey: "toolsPath").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let candidates = explicit + [currentExecutable?.deletingLastPathComponent(), configured].compactMap { $0 }
        let standard = standardDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        func exists(_ url: URL) -> Bool {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
        if let current = candidates.first(where: exists) { return current }
        if let installed = standard.first(where: { directory in
            selectedNames.contains { FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path) }
        }) { return installed }
        return standard.first(where: exists) ?? URL(fileURLWithPath: "/Applications", isDirectory: true)
    }
    static func validate(directory: URL) throws -> ValidatedTools {
        try validate(paths: Dictionary(uniqueKeysWithValues: names.map { ($0, directory.appendingPathComponent($0).path) }))
    }
    static func validate(paths: [String: String]) throws -> ValidatedTools {
        let urls = try names.map { name -> URL in
            guard let path = paths[name], FileManager.default.isExecutableFile(atPath: path) else { throw StudioError.message("Не найдена консольная утилита \(name). Укажите её в настройках.") }
            return URL(fileURLWithPath: path)
        }
        return ValidatedTools(mkvmerge: urls[0], mkvinfo: urls[1], mkvextract: urls[2], mkvpropedit: urls[3])
    }
    static func discover(defaults: UserDefaults = .standard) -> ValidatedTools? {
        let overrides = defaults.dictionary(forKey: "consoleToolPaths") as? [String: String] ?? [:]
        var directories = [defaults.string(forKey: "toolsPath")].compactMap { $0 }
        directories += standardDirectories
        directories += (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":").filter { $0.hasPrefix("/") }
        var paths: [String: String] = [:]
        for name in names {
            // An explicit invalid override remains visible as an error, never silently replaced.
            paths[name] = overrides[name] ?? directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        return try? validate(paths: paths)
    }
    static func identify(_ url: URL, tools: ValidatedTools) async throws -> MediaFileItem {
        let result = try await ProcessRunner.run(executable: tools.mkvmerge, arguments: ["--ui-language", "en_US", "-J", url.path])
        guard result.exitCode <= 1 else { throw StudioError.message(result.output) }
        return try MediaFileItem.identify(data: Data(result.output.utf8), url: url)
    }
}
