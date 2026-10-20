import Foundation

final class BookmarkStore {
    private let key = "mkvstudio.toolDirectoryBookmark"

    func save(url: URL) {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            NSLog("Bookmark save error: %@", error.localizedDescription)
        }
    }

    func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        do {
            return try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
        } catch {
            NSLog("Bookmark resolve error: %@", error.localizedDescription)
            return nil
        }
    }
}
