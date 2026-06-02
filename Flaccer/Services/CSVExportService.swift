import Foundation

enum CSVExportService {
    static func csvString(for results: [SpectrumResult]) -> String {
        var rows = [
            [
                "filename",
                "path",
                "format",
                "verdict",
                "confidence",
                "cutoff_khz",
                "nyquist_khz",
                "duration_seconds",
                "sample_rate",
                "high_band_energy",
                "diagnosis"
            ]
        ]

        for result in results {
            rows.append([
                result.fileName,
                result.url.path,
                result.fileExtension,
                result.verdict.rawValue,
                String(format: "%.2f", result.confidence),
                result.cutoffKhz.map { String(format: "%.2f", $0) } ?? "",
                String(format: "%.2f", result.nyquistKhz),
                String(format: "%.2f", result.duration),
                String(format: "%.0f", result.sampleRate),
                String(format: "%.3f", result.highBandEnergy),
                result.diagnosis
            ])
        }

        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n")
    }

    static func write(results: [SpectrumResult], to url: URL) throws {
        let csv = csvString(for: results)
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func escape(_ field: String) -> String {
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
            return "\"\(escaped)\""
        }
        return escaped
    }
}
