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
    static let bundledRelativePath = "Contents/Helpers/ConsoleTools"
    static func bundledDirectory(in bundleURL: URL = Bundle.main.bundleURL) -> URL? {
        guard bundleURL.pathExtension == "app" else { return nil }
        let directory = bundleURL.appendingPathComponent(bundledRelativePath, isDirectory: true)
        // Packaged releases require their own payload even if its folder was deleted.
        if Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "MKVStudioBundledTools") as? Bool == true { return directory }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return directory
    }
    static func relocatedExecutable(_ url: URL, bundleURL: URL = Bundle.main.bundleURL) -> URL {
        guard names.contains(url.lastPathComponent),
              url.deletingLastPathComponent().path.hasSuffix(".app/" + bundledRelativePath),
              let directory = bundledDirectory(in: bundleURL) else { return url }
        return directory.appendingPathComponent(url.lastPathComponent)
    }
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
        let standard = [bundledDirectory()].compactMap { $0 } + standardDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
        func exists(_ url: URL) -> Bool {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
        if let current = candidates.first(where: exists) { return current }
        if let installed = standard.first(where: { directory in
            exists(directory) && selectedNames.contains { FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path) }
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
    static func discover(defaults: UserDefaults = .standard, bundleURL: URL = Bundle.main.bundleURL,
                         searchDirectories: [String]? = nil) -> ValidatedTools? {
        let overrides = defaults.dictionary(forKey: "consoleToolPaths") as? [String: String] ?? [:]
        var directories = [defaults.string(forKey: "toolsPath")].compactMap { path in
            path.map { relocatedExecutable(URL(fileURLWithPath: $0).appendingPathComponent("mkvmerge"), bundleURL: bundleURL).deletingLastPathComponent().path }
        }
        if let bundled = bundledDirectory(in: bundleURL) {
            // A packaged app uses one self-contained toolset; a damaged bundle must not
            // silently mix in a different version from the host machine.
            directories.append(bundled.path)
        } else {
            directories += searchDirectories ?? (standardDirectories +
                (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":").filter { $0.hasPrefix("/") })
        }
        var paths: [String: String] = [:]
        for name in names {
            // An explicit invalid override remains visible as an error, never silently replaced.
            paths[name] = overrides[name].map { relocatedExecutable(URL(fileURLWithPath: $0), bundleURL: bundleURL).path }
                ?? directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        return try? validate(paths: paths)
    }
    static func identify(_ url: URL, tools: ValidatedTools) async throws -> MediaFileItem {
        let result = try await ProcessRunner.run(executable: tools.mkvmerge, arguments: ["--ui-language", "en_US", "-J", url.path])
        guard result.exitCode <= 1 else { throw StudioError.message(result.output) }
        return try MediaFileItem.identify(data: Data(result.output.utf8), url: url)
    }
}
