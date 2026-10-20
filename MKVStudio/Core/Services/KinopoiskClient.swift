import Foundation
import ImageIO
import UniformTypeIdentifiers

struct KinopoiskFilm: Decodable, Identifiable, Sendable {
    let kinopoiskId: Int
    var id: Int { kinopoiskId }
    var nameRu: String?
    var nameOriginal: String?
    var nameEn: String?
    var year: Int?
    var type: String?
    var posterUrl: String?
    var posterUrlPreview: String?
    var description: String?
    var shortDescription: String?
    var genres: [Genre]?
    var countries: [Country]?
    struct Genre: Decodable, Sendable { let genre: String }
    struct Country: Decodable, Sendable { let country: String }
    var title: String { nameRu ?? nameOriginal ?? nameEn ?? "Без названия" }
    var isSeries: Bool { ["TV_SERIES", "MINI_SERIES", "TV_SHOW"].contains(type ?? "") }
    var kind: String { isSeries ? "Сериал / телепередача" : "Фильм / видео" }
    var scope: Int { isSeries ? 70 : 50 }
}
struct KinopoiskPage: Decodable, Sendable { let totalPages: Int; let items: [KinopoiskFilm] }
struct KinopoiskPerson: Decodable, Sendable { let nameRu: String?; let professionKey: String }
struct KinopoiskDetails: Sendable {
    let film: KinopoiskFilm
    let fields: [String: String]
    init(film: KinopoiskFilm, people: [KinopoiskPerson]) {
        self.film = film
        fields = Self.mapFields(film, people: people)
    }
    private static func mapFields(_ film: KinopoiskFilm, people: [KinopoiskPerson]) -> [String: String] {
        var result: [String: String] = [:]
        func put(_ key: String, _ value: String?) {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { result[key] = value }
        }
        put("TITLE", film.nameRu)
        if let year = film.year, year > 0, year <= 9999 { put("DATE_RELEASED", String(format: "%04d", year)) }
        put("SUMMARY", film.shortDescription); put("DESCRIPTION", film.description)
        put("GENRE", film.genres?.map(\.genre).joined(separator: "\n"))
        for (profession, key) in [("DIRECTOR", "DIRECTOR"), ("ACTOR", "ACTOR"), ("WRITER", "SCREENPLAY_BY"), ("PRODUCER", "PRODUCER"), ("COMPOSER", "COMPOSER")] {
            var seen = Set<String>()
            let names = people.filter { $0.professionKey == profession }.compactMap(\.nameRu)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
            put(key, names.joined(separator: "\n"))
        }
        return result
    }
}

struct HTTPPayload: Sendable { let status: Int; let data: Data }
typealias KinopoiskTransport = @Sendable (URLRequest, Int, Bool) async throws -> HTTPPayload

struct KinopoiskClient: Sendable {
    static let apiHost = "kinopoiskapiunofficial.tech"
    static let posterLimit = 8 * 1024 * 1024
    let key: String
    var transport: KinopoiskTransport = { request, limit, poster in
        try await BoundedHTTP.load(request, limit: limit, poster: poster)
    }
    static func validKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }
    static func filmID(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Int(text), (1...15_000_000).contains(id) { return id }
        guard let url = URL(string: text), ["kinopoisk.ru", "www.kinopoisk.ru"].contains(url.host?.lowercased() ?? ""),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, ["film", "series"].contains(parts[0]), let id = Int(parts[1]), (1...15_000_000).contains(id) else { return nil }
        return id
    }
    func search(_ text: String, year: String = "", page: Int = 1) async throws -> KinopoiskPage {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 300, (1...20).contains(page) else { throw StudioError.message("Введите название, ссылку Кинопоиска или ID фильма.") }
        if let id = Self.filmID(text) { return KinopoiskPage(totalPages: 1, items: [try await film(id)]) }
        if text.contains("://") { throw StudioError.message("Используйте ссылку вида https://www.kinopoisk.ru/film/301/ или название.") }
        var query = [URLQueryItem(name: "keyword", value: text), URLQueryItem(name: "page", value: String(page))]
        if !year.isEmpty {
            guard let number = Int(year), (1000...3000).contains(number) else { throw StudioError.message("Год должен состоять из четырёх цифр.") }
            query += [URLQueryItem(name: "yearFrom", value: year), URLQueryItem(name: "yearTo", value: year)]
        }
        return try await json("/api/v2.2/films", query: query)
    }
    func film(_ id: Int) async throws -> KinopoiskFilm {
        guard (1...15_000_000).contains(id) else { throw StudioError.message("Некорректный ID фильма.") }
        return try await json("/api/v2.2/films/\(id)")
    }
    func details(_ id: Int) async throws -> KinopoiskDetails {
        let film = try await film(id)
        let people: [KinopoiskPerson] = try await json("/api/v1/staff", query: [URLQueryItem(name: "filmId", value: String(id))])
        let details = KinopoiskDetails(film: film, people: people)
        try TagEdits(language: "ru", values: details.fields).validate()
        return details
    }
    private func json<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard Self.validKey(key) else { throw StudioError.message("Введите и сохраните ключ Kinopoisk Unofficial API в настройках.") }
        var components = URLComponents(); components.scheme = "https"; components.host = Self.apiHost; components.path = path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!); request.timeoutInterval = 25
        request.setValue(key, forHTTPHeaderField: "X-API-KEY"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await transport(request, 2 * 1024 * 1024, false)
        try Self.checkStatus(response.status)
        do { return try JSONDecoder().decode(T.self, from: response.data) }
        catch { throw StudioError.message("Сервис вернул данные в неизвестном формате. Попробуйте позже.") }
    }
    static func checkStatus(_ status: Int) throws {
        switch status {
        case 200...299: return
        case 401: throw StudioError.message("Ключ API не принят. Проверьте его в настройках.")
        case 402: throw StudioError.message("Лимит запросов API исчерпан. Проверьте тариф или попробуйте позже.")
        case 403: throw StudioError.message("Доступ к API запрещён. Проверьте состояние учётной записи сервиса.")
        case 404: throw StudioError.message("Фильм или постер не найден.")
        case 429: throw StudioError.message("Слишком много запросов. Подождите немного и повторите поиск.")
        default: throw StudioError.message("Сервис временно недоступен (HTTP \(status)). Попробуйте позже.")
        }
    }
    static func posterURL(_ raw: String?) -> URL? {
        guard let raw, var parts = URLComponents(string: raw), let host = parts.host?.lowercased(),
              [apiHost, "st.kp.yandex.net", "avatars.mds.yandex.net", "kinopoisk.ru", "www.kinopoisk.ru"].contains(host),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443 else { return nil }
        parts.scheme = "https"
        return parts.url
    }
    func poster(_ raw: String) async throws -> PosterImage {
        guard let url = Self.posterURL(raw) else { throw StudioError.message("Адрес постера не поддерживается.") }
        // The API credential is never sent to an image host, including redirects.
        var request = URLRequest(url: url); request.timeoutInterval = 25
        request.setValue("image/jpeg,image/png", forHTTPHeaderField: "Accept")
        let response = try await transport(request, Self.posterLimit, true)
        try Self.checkStatus(response.status)
        return try await Task.detached { try PosterImage(data: response.data) }.value
    }
}

struct PosterImage: Sendable {
    let data: Data
    let fileExtension: String
    let mime: String
    private let preview: CGImage
    init(data: Data) throws {
        guard data.count <= KinopoiskClient.posterLimit,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, [UTType.jpeg.identifier, UTType.png.identifier].contains(type),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = info[kCGImagePropertyPixelWidth] as? Int, let h = info[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 16000, h <= 16000, Int64(w) * Int64(h) <= 80_000_000,
              let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw StudioError.message("Постер должен быть исправным JPEG или PNG размером до 8 МБ и 80 мегапикселей.")
        }
        self.data = data; self.preview = preview; fileExtension = type == UTType.jpeg.identifier ? "jpg" : "png"
        mime = type == UTType.jpeg.identifier ? "image/jpeg" : "image/png"
    }
    func thumbnail() -> CGImage { preview }
}
