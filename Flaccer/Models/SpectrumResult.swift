import Foundation

enum SpectrumVerdict: String, CaseIterable, Identifiable, Codable {
    case all = "ALL"
    case lossless = "LOSSLESS"
    case medium = "MEDIUM"
    case fake = "FAKE"
    case error = "ERROR"

    var id: String { rawValue }
}

struct SpectrumEvidence: Codable {
    let brickwallDropDb: Double
    let upperBandDeltaDb: Double
    let scaledCutoffKhz: Double
    let cutoffToNyquistRatio: Double
    let referenceDb: Double
    let thresholdDb: Double
    let quietOrSparse: Bool
    let upperBandEmpty: Bool
    let windowCount: Int
}

struct SpectrumResult: Identifiable, Codable {
    let id: UUID
    let url: URL
    let fileName: String
    let fileExtension: String
    let duration: TimeInterval
    let sampleRate: Double
    let nyquistKhz: Double
    let cutoffKhz: Double?
    let verdict: SpectrumVerdict
    let confidence: Double
    let diagnosis: String
    let highBandEnergy: Double
    let spectralFrames: [[Float]]
    let evidence: SpectrumEvidence?
    let createdAt: Date
    let errorMessage: String?

    var hasSpectrogram: Bool {
        guard let firstFrame = spectralFrames.first else { return false }
        return !spectralFrames.isEmpty && !firstFrame.isEmpty
    }

    init(
        id: UUID = UUID(),
        url: URL,
        fileName: String,
        fileExtension: String,
        duration: TimeInterval,
        sampleRate: Double,
        nyquistKhz: Double,
        cutoffKhz: Double?,
        verdict: SpectrumVerdict,
        confidence: Double,
        diagnosis: String,
        highBandEnergy: Double,
        spectralFrames: [[Float]],
        evidence: SpectrumEvidence? = nil,
        createdAt: Date = Date(),
        errorMessage: String? = nil
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.duration = duration
        self.sampleRate = sampleRate
        self.nyquistKhz = nyquistKhz
        self.cutoffKhz = cutoffKhz
        self.verdict = verdict
        self.confidence = confidence
        self.diagnosis = diagnosis
        self.highBandEnergy = highBandEnergy
        self.spectralFrames = spectralFrames
        self.evidence = evidence
        self.createdAt = createdAt
        self.errorMessage = errorMessage
    }

    static func error(url: URL, message: String) -> SpectrumResult {
        SpectrumResult(
            url: url,
            fileName: url.lastPathComponent,
            fileExtension: url.pathExtension.uppercased(),
            duration: 0,
            sampleRate: 0,
            nyquistKhz: 0,
            cutoffKhz: nil,
            verdict: .error,
            confidence: 0,
            diagnosis: message,
            highBandEnergy: 0,
            spectralFrames: [],
            errorMessage: message
        )
    }

    func replacingSpectralFrames(_ frames: [[Float]]) -> SpectrumResult {
        SpectrumResult(
            id: id,
            url: url,
            fileName: fileName,
            fileExtension: fileExtension,
            duration: duration,
            sampleRate: sampleRate,
            nyquistKhz: nyquistKhz,
            cutoffKhz: cutoffKhz,
            verdict: verdict,
            confidence: confidence,
            diagnosis: diagnosis,
            highBandEnergy: highBandEnergy,
            spectralFrames: frames,
            evidence: evidence,
            createdAt: createdAt,
            errorMessage: errorMessage
        )
    }
}

enum ScanItemStatus {
    case queued
    case analyzing
    case done
}

struct ScanItem: Identifiable {
    let id: String
    let url: URL
    let sequence: Int
    var result: SpectrumResult?
    var status: ScanItemStatus

    init(url: URL, sequence: Int = 0, result: SpectrumResult? = nil, status: ScanItemStatus = .queued) {
        let standardizedURL = url.standardizedFileURL
        self.id = standardizedURL.path
        self.url = standardizedURL
        self.sequence = sequence
        self.result = result
        self.status = status
    }

    var fileName: String {
        url.lastPathComponent
    }
}

struct ScanItemSection: Identifiable {
    let id: String
    let title: String
    var items: [ScanItem]
}

extension SpectrumResult {
    var confidencePercent: Int {
        Int((confidence * 100).rounded())
    }

    var cutoffText: String {
        guard let cutoffKhz else { return "n/a" }
        return Formatters.khz.string(from: NSNumber(value: cutoffKhz)) ?? String(format: "%.1f kHz", cutoffKhz)
    }
}
