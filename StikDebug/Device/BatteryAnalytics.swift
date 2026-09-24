import Foundation

struct BatteryHealthSample: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let healthPercent: Double?
    let cycleCount: Int?
    let availableCapacity: Int?
    let originalCapacity: Int?
    let averageTemperature: Double?
    let sourceName: String
}

enum BatteryAnalyticsService {
    private struct Archive: Codable {
        var samplesByDevice: [String: [BatteryHealthSample]] = [:]
    }

    private static let lock = NSLock()

    static func storedSamples(for targetID: String) throws -> [BatteryHealthSample] {
        lock.lock()
        defer { lock.unlock() }
        return try loadArchive().samplesByDevice[targetID, default: []].sorted { $0.date < $1.date }
    }

    static func syncFromDevice(
        target: DeviceConnectionSnapshot,
        context: JITEnableContext = .shared
    ) throws -> [BatteryHealthSample] {
        let existing = try storedSamples(for: target.id)
        let importedNames = Set(existing.map(\.sourceName))
        let candidates = try context.crashReports()
            .filter { entry in
                let name = entry.name.lowercased()
                return (name.contains("analytics-") || name.contains("log-aggregated-"))
                    && !importedNames.contains(entry.name)
            }

        var parsed: [BatteryHealthSample] = []
        for report in candidates {
            autoreleasepool {
                guard let url = try? context.downloadCrashReport(at: report.path),
                      let data = try? Data(contentsOf: url),
                      let sample = parse(data: data, sourceName: report.name) else { return }
                parsed.append(sample)
                try? FileManager.default.removeItem(at: url)
            }
        }
        return try merge(parsed, for: target.id)
    }

    static func importFiles(_ urls: [URL], targetID: String) throws -> [BatteryHealthSample] {
        let parsed = try urls.compactMap { url -> BatteryHealthSample? in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return parse(data: try Data(contentsOf: url), sourceName: url.lastPathComponent)
        }
        return try merge(parsed, for: targetID)
    }

    static func parse(data: Data, sourceName: String) -> BatteryHealthSample? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return nil
        }

        let cycle = number(in: text, keys: ["CycleCount", "last_value_CycleCount", "cycle_count"]).map { Int($0.rounded()) }
        let available = number(in: text, keys: [
            "NominalChargeCapacity", "last_value_NominalChargeCapacity", "AppleRawMaxCapacity",
            "last_value_AppleRawMaxCapacity", "raw_max_capacity", "AvailableMax"
        ]).map { Int($0.rounded()) }
        let original = number(in: text, keys: [
            "MaximumFCC", "last_value_MaximumFCC", "DesignCapacity", "last_value_DesignCapacity", "OriginalMax"
        ]).map { Int($0.rounded()) }
        let reportedHealth = number(in: text, keys: [
            "MaximumCapacityPercent", "last_value_MaximumCapacityPercent", "maximumCapacity"
        ]).flatMap { (0 ... 110).contains($0) ? $0 : nil }
        let calculatedHealth = available.flatMap { available in
            original.flatMap { original in original > 0 ? Double(available) / Double(original) * 100 : nil }
        }
        let temperature = normalizeTemperature(number(in: text, keys: [
            "AverageTemperature", "last_value_AverageTemperature", "averageTemperature"
        ]))

        guard reportedHealth != nil || calculatedHealth != nil || cycle != nil || available != nil else { return nil }
        return BatteryHealthSample(
            id: UUID(),
            date: date(in: text, sourceName: sourceName),
            healthPercent: reportedHealth ?? calculatedHealth,
            cycleCount: cycle,
            availableCapacity: available,
            originalCapacity: original,
            averageTemperature: temperature,
            sourceName: sourceName
        )
    }

    private static func merge(_ incoming: [BatteryHealthSample], for targetID: String) throws -> [BatteryHealthSample] {
        lock.lock()
        defer { lock.unlock() }
        var archive = try loadArchive()
        var samples = archive.samplesByDevice[targetID, default: []]
        for sample in incoming {
            if let index = samples.firstIndex(where: { $0.sourceName == sample.sourceName }) {
                samples[index] = sample
            } else {
                samples.append(sample)
            }
        }
        samples.sort { $0.date < $1.date }
        archive.samplesByDevice[targetID] = samples
        try saveArchive(archive)
        return samples
    }

    private static func number(in text: String, keys: [String]) -> Double? {
        for key in keys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let patterns = [
                "\\\"\(escaped)\\\"\\s*:\\s*(-?\\d+(?:\\.\\d+)?)",
                "<key>\(escaped)</key>\\s*<(?:integer|real)>(-?\\d+(?:\\.\\d+)?)</(?:integer|real)>",
                "\\\"(?:name|key)\\\"\\s*:\\s*\\\"\(escaped)\\\".{0,180}?\\\"(?:value|last_value)\\\"\\s*:\\s*(-?\\d+(?:\\.\\d+)?)"
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range(at: 1), in: text),
                      let value = Double(text[range]) else { continue }
                return value
            }
        }
        return nil
    }

    private static func date(in text: String, sourceName: String) -> Date {
        let combined = sourceName + "\n" + String(text.prefix(2_000))
        guard let regex = try? NSRegularExpression(pattern: "20\\d{2}-\\d{2}-\\d{2}(?:[T ][0-9:.+-Z]+)?"),
              let match = regex.firstMatch(in: combined, range: NSRange(combined.startIndex..., in: combined)),
              let range = Range(match.range, in: combined) else { return Date() }
        let value = String(combined[range]).replacingOccurrences(of: " ", with: "T")
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        let day = String(value.prefix(10))
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        return dayFormatter.date(from: day) ?? Date()
    }

    private static func normalizeTemperature(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if (200 ... 400).contains(value) { return value - 273.15 }
        if (1_000 ... 5_000).contains(value) { return value / 100 }
        return (-30 ... 100).contains(value) ? value : nil
    }

    private static func archiveURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("BatteryAnalytics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.json")
    }

    private static func loadArchive() throws -> Archive {
        let url = try archiveURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return Archive() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Archive.self, from: Data(contentsOf: url))
    }

    private static func saveArchive(_ archive: Archive) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(archive).write(to: archiveURL(), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
