import Foundation
import Darwin

@main struct KinopoiskBenchmark {
    static func cpu() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    static func rss() -> Double {
        var info = proc_taskinfo(); let size = MemoryLayout<proc_taskinfo>.size
        _ = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, Int32(size))
        return Double(info.pti_resident_size) / 1048576
    }
    static func emit(_ value: [String: Any]) throws {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: .sortedKeys) + Data([10]))
    }
    static func main() async throws {
        let poster = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let film: [String: Any] = ["kinopoiskId": 301, "nameRu": "Проверочный фильм", "year": 1999, "type": "FILM", "description": String(repeating: "Описание фильма. ", count: 1000), "posterUrl": "https://kinopoiskapiunofficial.tech/images/posters/kp/301.jpg"]
        let filmData = try JSONSerialization.data(withJSONObject: film)
        let pageData = try JSONSerialization.data(withJSONObject: ["totalPages": 1, "items": Array(repeating: film, count: 20)])
        let staffData = try JSONSerialization.data(withJSONObject: (0..<300).map { ["nameRu": "Актёр \($0)", "professionKey": "ACTOR"] })
        let client = KinopoiskClient(key: "fixture-only", transport: { request, _, isPoster in
            HTTPPayload(status: 200, data: isPoster ? poster : request.url!.path == "/api/v1/staff" ? staffData : request.url!.path == "/api/v2.2/films" ? pageData : filmData)
        })
        for batch in 0..<3 {
            let before = cpu(), start = Date(); var peak = rss()
            for _ in 0..<100 {
                _ = try await client.search("Фильм")
                let details = try await client.details(301)
                let image = try await client.poster(details.film.posterUrl!)
                _ = image.thumbnail(); peak = max(peak, rss())
            }
            let duration = Date().timeIntervalSince(start)
            try emit(["scenario": "metadata_fixture_batch", "batch": batch + 1, "iterations": 100, "wall_s": duration,
                      "cpu_seconds": cpu() - before, "peak_rss_mib": peak, "end_rss_mib": rss()])
        }
        let before = cpu(), start = Date()
        try await Task.sleep(for: .seconds(5))
        let duration = Date().timeIntervalSince(start)
        try emit(["scenario": "metadata_after_idle", "wall_s": duration, "cpu_pct": 100 * (cpu() - before) / duration, "rss_mib": rss()])
    }
}
