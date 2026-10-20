import Foundation

enum AssemblyMode: String, Codable, CaseIterable, Sendable {
    case multiplex, append
    var title: String { self == .multiplex ? "Объединить дорожки" : "Склеить последовательно" }
}

enum SplitMode: String, Codable, CaseIterable, Sendable {
    case none, size, duration, timestamps, parts, chapters
    var title: String {
        switch self {
        case .none: "Один файл"; case .size: "По размеру"; case .duration: "По длительности"
        case .timestamps: "По отметкам времени"; case .parts: "Выбранные фрагменты"; case .chapters: "По главам"
        }
    }
    var example: String {
        switch self {
        case .none: ""; case .size: "700M"; case .duration: "00:10:00"
        case .timestamps: "00:05:00,00:12:30"; case .parts: "00:01:00-00:02:00,00:04:00-00:06:00"; case .chapters: "all или 2,4,6"
        }
    }
}
struct SplitOptions: Codable, Equatable, Sendable {
    var mode: SplitMode = .none
    var value = ""
    var maxFiles = 0
    var linkFiles = false
    var enabled: Bool { mode != .none }
    var specification: String { "\(mode.rawValue):\(value.replacingOccurrences(of: " ", with: ""))" }
    func validate() throws {
        guard enabled else { return }
        guard maxFiles == 0 || (2...10000).contains(maxFiles) else { throw StudioError.message("Число частей: 0 — без ограничения, либо от 2 до 10 000.") }
        let v = value.replacingOccurrences(of: " ", with: "")
        var valid = false
        switch mode {
        case .none: return
        case .size:
            valid = v.range(of: "^[1-9][0-9]{0,12}[kKmMgG]?$", options: .regularExpression) != nil
        case .duration: valid = (try? MediaTime.nanoseconds(v)) ?? 0 > 0
        case .timestamps:
            let times = v.split(separator: ",", omittingEmptySubsequences: false).compactMap { try? MediaTime.nanoseconds(String($0)) }
            valid = times.count == v.components(separatedBy: ",").count && !times.isEmpty && times[0] > 0 && zip(times, times.dropFirst()).allSatisfy { $0 < $1 }
        case .chapters:
            let values = v.components(separatedBy: ",").compactMap(Int.init)
            valid = v == "all" || (!values.isEmpty && values.count == v.components(separatedBy: ",").count && values.allSatisfy { $0 > 0 } && zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
        case .parts:
            var previousEnd: Int64 = 0
            let ranges = v.components(separatedBy: ",")
            valid = !ranges.isEmpty
            for (i, raw) in ranges.enumerated() {
                let range = raw.hasPrefix("+") ? String(raw.dropFirst()) : raw
                let bounds = range.components(separatedBy: "-")
                guard bounds.count == 2, !(i == 0 && raw.hasPrefix("+")) else { valid = false; break }
                let start = bounds[0].isEmpty ? previousEnd : (try? MediaTime.nanoseconds(bounds[0])) ?? -1
                let end = bounds[1].isEmpty ? Int64.max : (try? MediaTime.nanoseconds(bounds[1])) ?? -1
                guard start >= previousEnd, end > start, !(end == Int64.max && i != ranges.count - 1) else { valid = false; break }
                previousEnd = end
            }
        }
        guard valid else { throw StudioError.message("Некорректное разбиение. Пример: \(mode.example). Временные отметки должны идти по возрастанию.") }
    }
}

enum MediaTime {
    static func nanoseconds(_ text: String) throws -> Int64 {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = value.hasSuffix("s") ? [String(value.dropLast())] : value.components(separatedBy: ":")
        guard (1...3).contains(fields.count), fields.allSatisfy({ !$0.isEmpty }) else { throw invalid }
        let seconds = fields.last!.components(separatedBy: ".")
        guard (1...2).contains(seconds.count), let sec = Int64(seconds[0]), sec >= 0,
              seconds[0].allSatisfy(\.isNumber), fields.count == 1 || sec < 60 else { throw invalid }
        var whole = sec
        if fields.count >= 2 {
            guard let minutes = Int64(fields[fields.count - 2]), (0..<60).contains(minutes) else { throw invalid }
            whole += minutes * 60
        }
        if fields.count == 3 {
            guard let hours = Int64(fields[0]), (0...9999).contains(hours) else { throw invalid }
            whole += hours * 3600
        }
        guard whole < 36_000_000 else { throw invalid }
        let fraction = seconds.count == 2 ? seconds[1] : ""
        guard fraction.count <= 9, fraction.allSatisfy(\.isNumber), seconds.count == 1 || !fraction.isEmpty else { throw invalid }
        return whole * 1_000_000_000 + (Int64(fraction.padding(toLength: 9, withPad: "0", startingAt: 0)) ?? 0)
    }
    static var invalid: StudioError { .message("Укажите время в формате ЧЧ:ММ:СС.ннн или число секунд с суффиксом s.") }
    static func format(_ nanoseconds: Int64) -> String {
        let n = max(0, nanoseconds), s = n / 1_000_000_000
        return String(format: "%02lld:%02lld:%02lld.%09lld", s / 3600, s / 60 % 60, s % 60, n % 1_000_000_000)
    }
}

enum HDRField: String, CaseIterable, Sendable {
    case matrix = "color-matrix-coefficients", bits = "color-bits-per-channel", range = "color-range"
    case transfer = "color-transfer-characteristics", primaries = "color-primaries"
    case maxCLL = "max-content-light", maxFALL = "max-frame-light"
    case chromaticity = "chromaticity-coordinates", white = "white-color-coordinates"
    case maxLuminance = "max-luminance", minLuminance = "min-luminance"
    var title: String {
        switch self {
        case .matrix: "Матрица"; case .bits: "Бит на канал"; case .range: "Диапазон"
        case .transfer: "Передаточная функция"; case .primaries: "Основные цвета"
        case .maxCLL: "MaxCLL, кд/м²"; case .maxFALL: "MaxFALL, кд/м²"
        case .chromaticity: "Координаты R, G, B"; case .white: "Белая точка x, y"
        case .maxLuminance: "Макс. яркость, кд/м²"; case .minLuminance: "Мин. яркость, кд/м²"
        }
    }
    var choices: [(String, String)] {
        switch self {
        case .matrix: [("0", "RGB"), ("1", "BT.709"), ("2", "Не указана"), ("9", "BT.2020 NCL"), ("10", "BT.2020 CL")]
        case .range: [("0", "Не указан"), ("1", "Ограниченный"), ("2", "Полный"), ("3", "По функции/матрице")]
        case .transfer: [("1", "BT.709"), ("2", "Не указана"), ("13", "sRGB"), ("16", "PQ · ST 2084"), ("18", "HLG")]
        case .primaries: [("1", "BT.709"), ("2", "Не указаны"), ("9", "BT.2020"), ("11", "DCI-P3"), ("12", "Display P3")]
        default: []
        }
    }
    static func arguments(_ values: [String: String]?, id: Int) -> [String] {
        allCases.flatMap { field -> [String] in
            guard let value = values?[field.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return [] }
            return ["--" + field.rawValue, "\(id):\(value.replacingOccurrences(of: " ", with: ""))"]
        }
    }
    static func validate(_ values: [String: String]?) throws {
        guard let values else { return }
        for field in allCases {
            guard let raw = values[field.rawValue], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let value = raw.replacingOccurrences(of: " ", with: "")
            let valid: Bool
            switch field {
            case .chromaticity, .white:
                let parts = value.components(separatedBy: ",")
                valid = parts.count == (field == .white ? 2 : 6) && parts.allSatisfy { Double($0).map { $0.isFinite && (0...1).contains($0) } ?? false }
            case .minLuminance, .maxLuminance:
                valid = Double(value).map { $0.isFinite && (0...100_000).contains($0) } ?? false
            default:
                let upper = field == .bits ? 64 : field == .range ? 3 : field == .matrix ? 14 : field == .transfer ? 18 : field == .primaries ? 22 : 65535
                valid = Int(value).map { (0...upper).contains($0) } ?? false
            }
            guard valid else { throw StudioError.message("Некорректное значение «\(field.title)»: \(raw)") }
        }
        if let min = Double(values[HDRField.minLuminance.rawValue] ?? ""), let max = Double(values[HDRField.maxLuminance.rawValue] ?? ""), min > max {
            throw StudioError.message("Минимальная яркость не может превышать максимальную.")
        }
    }
}
