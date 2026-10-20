import Foundation

enum QueueJobState: String, Codable, Sendable {
    case waiting, running, finished, warning, failed, cancelled
    var title: String {
        switch self {
        case .waiting: "Ожидает"; case .running: "Выполняется"; case .finished: "Готово"
        case .warning: "Готово с предупреждениями"; case .failed: "Ошибка"; case .cancelled: "Отменено"
        }
    }
}
struct QueueJob: Identifiable, Codable, Sendable {
    var id = UUID()
    var title: String
    var executable: URL
    var arguments: [String]
    var output: URL
    var stagingDirectory: URL
    var stagedOutput: URL
    var progress = 0.0
    var state: QueueJobState = .waiting
    var log = ""
    var createdAt = Date()
    var isExtraction = false
    var copySource: URL?
    var splitOutput: Bool?
    var chapterXML: String?
}
