import Accelerate
import AudioToolbox
import Foundation

enum AudioAnalyzer {
    private static let fftSize = 8192
    private static let spectrogramBins = 256
    private static let maxAnalysisWindows = 72
    private static let maxSpectrogramWindows = 420
    private static let minWindows = 10

    static func analyze(url: URL) async -> SpectrumResult {
        await Task.detached(priority: .userInitiated) {
            do {
                return try analyzeSynchronously(url: url, includeSpectrogram: false)
            } catch {
                return SpectrumResult.error(url: url, message: error.localizedDescription)
            }
        }.value
    }

    static func spectrogramFrames(url: URL) async throws -> [[Float]] {
        try await Task.detached(priority: .utility) {
            try spectrogramFramesSynchronously(url: url)
        }.value
    }

    private static func analyzeSynchronously(url: URL, includeSpectrogram: Bool) throws -> SpectrumResult {
        let reader = try AudioSampleReader(url: url)
        let sampleRate = reader.sampleRate
        let channelCount = reader.channelCount
        let frameCount = reader.frameCount

        guard sampleRate > 0, channelCount > 0, frameCount > 0 else {
            throw AnalyzerError.emptyFile
        }
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2)) else {
            throw AnalyzerError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let duration = Double(frameCount) / sampleRate
        let nyquistKhz = sampleRate / 2_000
        let analysisPositions = samplePositions(totalFrames: frameCount, maxWindowCount: maxAnalysisWindows)
        let powerBinCount = fftSize / 2
        var averagePower = [Double](repeating: 0, count: powerBinCount)
        var usedWindowCount = 0

        for position in analysisPositions {
            autoreleasepool {
                guard let powers = powers(
                    at: position,
                    from: reader,
                    hannWindow: hannWindow,
                    setup: setup
                ) else { return }
                for index in 0..<powerBinCount {
                    averagePower[index] += Double(powers[index])
                }
                usedWindowCount += 1
            }
        }

        guard usedWindowCount > 0 else {
            throw AnalyzerError.unreadablePCM
        }

        let inverseCount = 1.0 / Double(usedWindowCount)
        averagePower = averagePower.map { max($0 * inverseCount, 1.0e-18) }

        let analysis = classify(
            averagePower: averagePower,
            sampleRate: sampleRate,
            duration: duration,
            windowCount: usedWindowCount
        )

        return SpectrumResult(
            url: url,
            fileName: url.lastPathComponent,
            fileExtension: url.pathExtension.uppercased(),
            duration: duration,
            sampleRate: sampleRate,
            nyquistKhz: nyquistKhz,
            cutoffKhz: analysis.cutoffKhz,
            verdict: analysis.verdict,
            confidence: analysis.confidence,
            diagnosis: analysis.diagnosis,
            highBandEnergy: analysis.highBandEnergy,
            spectralFrames: includeSpectrogram ? makeSpectrogramFrames(
                from: reader,
                hannWindow: hannWindow,
                setup: setup
            ) : [],
            evidence: analysis.evidence,
            errorMessage: nil
        )
    }

    private static func spectrogramFramesSynchronously(url: URL) throws -> [[Float]] {
        let reader = try AudioSampleReader(url: url)
        let sampleRate = reader.sampleRate
        let channelCount = reader.channelCount
        let frameCount = reader.frameCount

        guard sampleRate > 0, channelCount > 0, frameCount > 0 else {
            throw AnalyzerError.emptyFile
        }
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2)) else {
            throw AnalyzerError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        return makeSpectrogramFrames(
            from: reader,
            hannWindow: hannWindow,
            setup: setup
        )
    }

    private static func makeSpectrogramFrames(
        from reader: AudioSampleReader,
        hannWindow: [Float],
        setup: FFTSetup
    ) -> [[Float]] {
        let spectrogramPositions = spectrogramSamplePositions(totalFrames: reader.frameCount, sampleRate: reader.sampleRate)
        var spectralDbFrames: [[Float]] = []
        spectralDbFrames.reserveCapacity(spectrogramPositions.count)

        for position in spectrogramPositions {
            autoreleasepool {
                guard let powers = powers(
                    at: position,
                    from: reader,
                    hannWindow: hannWindow,
                    setup: setup
                ) else { return }
                spectralDbFrames.append(decibelFrame(from: powers))
            }
        }

        return normalizedSpectrogramFrames(from: spectralDbFrames)
    }

    private static func samplePositions(totalFrames: Int64, maxWindowCount: Int) -> [Int64] {
        let usableFrames = max(totalFrames - Int64(fftSize), 1)
        let naturalCount = Int(totalFrames / 44_100)
        let windowCount = min(max(naturalCount, minWindows), maxWindowCount)

        guard windowCount > 1 else { return [0] }

        return (0..<windowCount).map { index in
            let fraction = Double(index) / Double(windowCount - 1)
            return Int64(Double(usableFrames) * fraction)
        }
    }

    private static func spectrogramSamplePositions(totalFrames: Int64, sampleRate: Double) -> [Int64] {
        guard sampleRate > 0 else {
            return samplePositions(totalFrames: totalFrames, maxWindowCount: maxSpectrogramWindows)
        }

        let usableFrames = max(totalFrames - Int64(fftSize), 1)
        let duration = Double(totalFrames) / sampleRate
        let windowCount = min(max(Int((duration * 4.0).rounded(.up)), minWindows), maxSpectrogramWindows)

        guard windowCount > 1 else { return [0] }

        return (0..<windowCount).map { index in
            let fraction = Double(index) / Double(windowCount - 1)
            return Int64(Double(usableFrames) * fraction)
        }
    }

    private static func powers(
        at position: Int64,
        from reader: AudioSampleReader,
        hannWindow: [Float],
        setup: FFTSetup
    ) -> [Float]? {
        let readableFrameCount = reader.frameCount
        guard readableFrameCount > 0 else {
            return nil
        }

        let maxStartFrame = max(readableFrameCount - 1, 0)
        let safePosition = min(max(position, 0), maxStartFrame)
        let remainingFrames = readableFrameCount - safePosition
        guard remainingFrames > 0 else {
            return nil
        }

        let framesToRead = Int(min(Int64(fftSize), remainingFrames))
        guard let mono = reader.readMonoSamples(at: safePosition, frameCount: framesToRead, outputFrameCount: fftSize) else {
            return nil
        }

        let powers = fftPowers(for: mono, hannWindow: hannWindow, setup: setup)
        return powers.isEmpty ? nil : powers
    }

    private static func fftPowers(
        for mono: [Float],
        hannWindow: [Float],
        setup: FFTSetup
    ) -> [Float] {
        var windowed = [Float](repeating: 0, count: fftSize)
        mono.withUnsafeBufferPointer { monoBuffer in
            hannWindow.withUnsafeBufferPointer { windowBuffer in
                windowed.withUnsafeMutableBufferPointer { outputBuffer in
                    vDSP_vmul(
                        monoBuffer.baseAddress!,
                        1,
                        windowBuffer.baseAddress!,
                        1,
                        outputBuffer.baseAddress!,
                        1,
                        vDSP_Length(fftSize)
                    )
                }
            }
        }

        let halfSize = fftSize / 2
        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)
        var powers = [Float](repeating: 0, count: halfSize)

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var splitComplex = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )

                windowed.withUnsafeBufferPointer { windowedBuffer in
                    windowedBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexBuffer in
                        vDSP_ctoz(complexBuffer, 2, &splitComplex, 1, vDSP_Length(halfSize))
                    }
                }

                vDSP_fft_zrip(
                    setup,
                    &splitComplex,
                    1,
                    vDSP_Length(log2(Double(fftSize))),
                    FFTDirection(FFT_FORWARD)
                )

                powers.withUnsafeMutableBufferPointer { powersBuffer in
                    vDSP_zvmags(&splitComplex, 1, powersBuffer.baseAddress!, 1, vDSP_Length(halfSize))
                }
            }
        }

        return powers
    }

    private static func decibelFrame(from powers: [Float]) -> [Float] {
        guard !powers.isEmpty else { return [] }

        var frame: [Float] = []
        frame.reserveCapacity(spectrogramBins)

        for bin in 0..<spectrogramBins {
            let start = bin * powers.count / spectrogramBins
            let end = max(start + 1, (bin + 1) * powers.count / spectrogramBins)
            let slice = powers[start..<min(end, powers.count)]
            let averagePower = slice.reduce(Float(0), +) / Float(max(slice.count, 1))
            let db = 10 * log10(max(averagePower, 1.0e-18))
            frame.append(db)
        }

        return frame
    }

    private static func normalizedSpectrogramFrames(from dbFrames: [[Float]]) -> [[Float]] {
        let values = dbFrames.flatMap { frame in
            frame.map(Double.init)
        }

        guard !values.isEmpty else { return [] }

        let noiseDb = percentile(values, percentile: 0.24) ?? -120
        let peakDb = percentile(values, percentile: 0.996) ?? (values.max() ?? -30)
        let floorDb = max(noiseDb + 4, peakDb - 78)
        let rangeDb = max(peakDb - floorDb, 1)

        return dbFrames.map { frame in
            frame.map { db in
                let normalized = min(max((Double(db) - floorDb) / rangeDb, 0), 1)
                return Float(normalized)
            }
        }
    }

    private static func classify(
        averagePower: [Double],
        sampleRate: Double,
        duration: TimeInterval,
        windowCount: Int
    ) -> Classification {
        let nyquistKhz = sampleRate / 2_000
        let binKhz = (sampleRate / 1_000) / Double(fftSize)
        let db = averagePower.map { 10 * log10(max($0, 1.0e-18)) }
        let smoothDb = movingAverage(db, radius: 7)

        let referenceRange = binIndexes(fromKhz: 1.0, toKhz: min(12.0, nyquistKhz * 0.62), binKhz: binKhz, upperBound: smoothDb.count)
        let referenceDb = percentile(referenceRange.map { smoothDb[$0] }, percentile: 0.85) ?? -90
        let thresholdDb = max(referenceDb - 58, -112)

        let cutoffBin = estimateCutoffBin(smoothDb: smoothDb, thresholdDb: thresholdDb)
        let cutoffKhz = Double(cutoffBin) * binKhz
        let ratioToNyquist = nyquistKhz > 0 ? cutoffKhz / nyquistKhz : 0
        let scaledTo441 = cutoffKhz / max(nyquistKhz / 22.05, 0.1)

        let oneKhzBins = max(4, Int((1.0 / max(binKhz, 0.001)).rounded()))
        let belowRange = max(1, cutoffBin - oneKhzBins)..<max(1, cutoffBin)
        let aboveStart = min(smoothDb.count - 1, cutoffBin + 1)
        let aboveEnd = min(smoothDb.count, cutoffBin + (oneKhzBins * 2))
        let belowDb = average(smoothDb, in: belowRange) ?? referenceDb
        let aboveDb = aboveStart < aboveEnd ? (average(smoothDb, in: aboveStart..<aboveEnd) ?? thresholdDb) : thresholdDb
        let brickwallDrop = max(0, belowDb - aboveDb)

        let upperRange = binIndexes(fromKhz: nyquistKhz * 0.86, toKhz: nyquistKhz * 0.99, binKhz: binKhz, upperBound: smoothDb.count)
        let upperDb = average(upperRange.map { smoothDb[$0] }) ?? -120
        let midRange = binIndexes(fromKhz: min(7.0, nyquistKhz * 0.35), toKhz: min(14.0, nyquistKhz * 0.70), binKhz: binKhz, upperBound: smoothDb.count)
        let midDb = average(midRange.map { smoothDb[$0] }) ?? referenceDb
        let upperBandDelta = upperDb - midDb
        let highBandEnergy = min(max((upperDb - thresholdDb + 18) / 36, 0), 1)
        let upperBandEmpty = upperDb < thresholdDb + 3
        let brickwallStrong = brickwallDrop >= 22
        let brickwallModerate = brickwallDrop >= 15
        let quietOrSparse = referenceDb < -56 || duration < 25 || windowCount < minWindows
        let evidence = SpectrumEvidence(
            brickwallDropDb: brickwallDrop,
            upperBandDeltaDb: upperBandDelta,
            scaledCutoffKhz: scaledTo441,
            cutoffToNyquistRatio: ratioToNyquist,
            referenceDb: referenceDb,
            thresholdDb: thresholdDb,
            quietOrSparse: quietOrSparse,
            upperBandEmpty: upperBandEmpty,
            windowCount: windowCount
        )

        let verdict: SpectrumVerdict
        var confidence: Double

        if ratioToNyquist >= 0.93, !upperBandEmpty, brickwallDrop < 18 {
            verdict = .lossless
            confidence = 0.70 + min(0.22, highBandEnergy * 0.22) + min(0.08, ratioToNyquist - 0.93)
        } else if brickwallStrong, scaledTo441 <= 19.5, upperBandEmpty {
            verdict = .fake
            confidence = 0.72 + min(0.18, (brickwallDrop - 22) / 70) + lossySignatureBonus(scaledCutoffKhz: scaledTo441)
        } else if brickwallModerate, scaledTo441 <= 20.5, upperBandEmpty {
            verdict = .medium
            confidence = 0.58 + min(0.22, (brickwallDrop - 15) / 55) + lossySignatureBonus(scaledCutoffKhz: scaledTo441) * 0.5
        } else if ratioToNyquist < 0.82, upperBandEmpty {
            verdict = brickwallModerate ? .fake : .medium
            confidence = brickwallModerate ? 0.66 : 0.52
        } else {
            verdict = .medium
            confidence = 0.48 + min(0.24, highBandEnergy * 0.24)
        }

        if quietOrSparse {
            confidence *= 0.78
        }

        confidence = min(max(confidence, 0.20), 0.98)

        let diagnosis = diagnosisText(
            verdict: verdict,
            cutoffKhz: cutoffKhz,
            nyquistKhz: nyquistKhz,
            brickwallDrop: brickwallDrop,
            upperBandDelta: upperBandDelta,
            quietOrSparse: quietOrSparse
        )

        return Classification(
            cutoffKhz: cutoffKhz,
            verdict: verdict,
            confidence: confidence,
            diagnosis: diagnosis,
            highBandEnergy: highBandEnergy,
            evidence: evidence
        )
    }

    private static func estimateCutoffBin(smoothDb: [Double], thresholdDb: Double) -> Int {
        guard smoothDb.count > 8 else { return 0 }

        for index in stride(from: smoothDb.count - 2, through: 3, by: -1) {
            let lower = max(1, index - 5)
            let sustainedBins = smoothDb[lower...index].filter { $0 > thresholdDb }.count
            if sustainedBins >= 3 {
                return index
            }
        }

        return 1
    }

    private static func movingAverage(_ values: [Double], radius: Int) -> [Double] {
        guard values.count > 1, radius > 0 else { return values }
        return values.indices.map { index in
            let start = max(values.startIndex, index - radius)
            let end = min(values.endIndex - 1, index + radius)
            return average(Array(values[start...end])) ?? values[index]
        }
    }

    private static func binIndexes(fromKhz: Double, toKhz: Double, binKhz: Double, upperBound: Int) -> [Int] {
        guard upperBound > 0, toKhz > fromKhz else { return [] }
        let start = min(max(Int((fromKhz / max(binKhz, 0.001)).rounded()), 1), upperBound - 1)
        let end = min(max(Int((toKhz / max(binKhz, 0.001)).rounded()), start + 1), upperBound)
        return Array(start..<end)
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func average(_ values: [Double], in range: Range<Int>) -> Double? {
        guard !range.isEmpty else { return nil }
        let bounded = range.clamped(to: values.startIndex..<values.endIndex)
        guard !bounded.isEmpty else { return nil }
        return average(Array(values[bounded]))
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(max(Int(Double(sorted.count - 1) * percentile), 0), sorted.count - 1)
        return sorted[index]
    }

    private static func lossySignatureBonus(scaledCutoffKhz: Double) -> Double {
        let signatures = [16.0, 18.5, 19.2]
        let closest = signatures.map { abs($0 - scaledCutoffKhz) }.min() ?? 4
        return max(0, 0.08 - closest * 0.025)
    }

    private static func diagnosisText(
        verdict: SpectrumVerdict,
        cutoffKhz: Double,
        nyquistKhz: Double,
        brickwallDrop: Double,
        upperBandDelta: Double,
        quietOrSparse: Bool
    ) -> String {
        let cutoff = String(format: "%.1f kHz", cutoffKhz)
        let nyquist = String(format: "%.1f kHz", nyquistKhz)
        let drop = String(format: "%.0f dB", brickwallDrop)
        let upper = String(format: "%.0f dB", upperBandDelta)
        let caution = quietOrSparse ? " Confidence reduced because the track is short, quiet, or sparse." : ""

        switch verdict {
        case .lossless:
            return "High-frequency energy reaches close to Nyquist (\(nyquist)) without a hard cutoff. Upper band sits \(upper) relative to the mid band.\(caution)"
        case .fake:
            return "A sharp brickwall cutoff appears near \(cutoff), with about \(drop) of energy loss above it. This matches common lossy transcode behavior.\(caution)"
        case .medium:
            return "The spectrum becomes weak around \(cutoff), below Nyquist (\(nyquist)), but the cutoff is not decisive enough for a clean fake verdict.\(caution)"
        case .error:
            return "The file could not be analyzed."
        case .all:
            return ""
        }
    }
}

private final class AudioSampleReader {
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int64

    private let audioFile: ExtAudioFileRef
    private var currentFramePosition: Int64 = 0

    init(url: URL) throws {
        var fileRef: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(url as CFURL, &fileRef)
        guard openStatus == noErr, let fileRef else {
            throw AnalyzerError.audioOpenFailed(openStatus)
        }

        audioFile = fileRef

        var fileFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = ExtAudioFileGetProperty(
            audioFile,
            kExtAudioFileProperty_FileDataFormat,
            &formatSize,
            &fileFormat
        )
        guard formatStatus == noErr else {
            throw AnalyzerError.audioFormatFailed(formatStatus)
        }

        sampleRate = fileFormat.mSampleRate
        channelCount = max(Int(fileFormat.mChannelsPerFrame), 1)

        var length: Int64 = 0
        var lengthSize = UInt32(MemoryLayout<Int64>.size)
        let lengthStatus = ExtAudioFileGetProperty(
            audioFile,
            kExtAudioFileProperty_FileLengthFrames,
            &lengthSize,
            &length
        )
        guard lengthStatus == noErr else {
            throw AnalyzerError.audioLengthFailed(lengthStatus)
        }
        frameCount = max(length, 0)

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(channelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )

        let clientFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let clientStatus = ExtAudioFileSetProperty(
            audioFile,
            kExtAudioFileProperty_ClientDataFormat,
            clientFormatSize,
            &clientFormat
        )
        guard clientStatus == noErr else {
            throw AnalyzerError.audioFormatFailed(clientStatus)
        }
    }

    deinit {
        ExtAudioFileDispose(audioFile)
    }

    func readMonoSamples(at position: Int64, frameCount requestedFrameCount: Int, outputFrameCount: Int) -> [Float]? {
        guard requestedFrameCount > 0, outputFrameCount > 0, frameCount > 0 else {
            return nil
        }

        let maxStartFrame = max(frameCount - 1, 0)
        let safePosition = min(max(position, 0), maxStartFrame)
        let remainingFrames = frameCount - safePosition
        let framesToRead = min(requestedFrameCount, Int(remainingFrames))
        guard framesToRead > 0 else {
            return nil
        }

        guard seekOrAdvance(to: safePosition) else {
            return nil
        }

        guard let read = readInterleavedFrames(maxFrameCount: framesToRead) else {
            return nil
        }

        let interleavedSamples = read.samples
        let decodedFrames = min(read.frameCount, outputFrameCount)
        var mono = [Float](repeating: 0, count: outputFrameCount)
        for frame in 0..<decodedFrames {
            let sampleIndex = frame * channelCount
            if channelCount == 1 {
                mono[frame] = interleavedSamples[sampleIndex]
            } else {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += interleavedSamples[sampleIndex + channel]
                }
                mono[frame] = sum / Float(channelCount)
            }
        }

        return mono
    }

    private func seekOrAdvance(to framePosition: Int64) -> Bool {
        guard framePosition != currentFramePosition else {
            return true
        }

        let seekStatus = ExtAudioFileSeek(audioFile, framePosition)
        if seekStatus == noErr {
            currentFramePosition = framePosition
            return true
        }

        guard framePosition > currentFramePosition else {
            return false
        }

        return discardFrames(Int(framePosition - currentFramePosition))
    }

    private func discardFrames(_ frameCount: Int) -> Bool {
        guard frameCount > 0 else {
            return true
        }

        var remaining = frameCount
        while remaining > 0 {
            let chunkFrameCount = min(remaining, 16_384)
            guard let read = readInterleavedFrames(maxFrameCount: chunkFrameCount),
                  read.frameCount > 0
            else {
                return false
            }
            remaining -= read.frameCount
        }

        return true
    }

    private func readInterleavedFrames(maxFrameCount: Int) -> (samples: [Float], frameCount: Int)? {
        guard maxFrameCount > 0 else {
            return nil
        }

        let sampleCount = maxFrameCount * channelCount
        var interleavedSamples = [Float](repeating: 0, count: sampleCount)
        var framesRead = UInt32(maxFrameCount)
        let byteCount = UInt32(sampleCount * MemoryLayout<Float>.size)

        let readStatus = interleavedSamples.withUnsafeMutableBufferPointer { sampleBuffer -> OSStatus in
            guard let baseAddress = sampleBuffer.baseAddress else {
                return kAudio_ParamError
            }

            let audioBuffer = AudioBuffer(
                mNumberChannels: UInt32(channelCount),
                mDataByteSize: byteCount,
                mData: baseAddress
            )
            var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
            return ExtAudioFileRead(audioFile, &framesRead, &bufferList)
        }

        guard readStatus == noErr, framesRead > 0 else {
            return nil
        }

        let decodedFrameCount = Int(framesRead)
        currentFramePosition += Int64(decodedFrameCount)

        if decodedFrameCount < maxFrameCount {
            interleavedSamples.removeSubrange((decodedFrameCount * channelCount)..<interleavedSamples.count)
        }

        return (interleavedSamples, decodedFrameCount)
    }
}

private struct Classification {
    let cutoffKhz: Double
    let verdict: SpectrumVerdict
    let confidence: Double
    let diagnosis: String
    let highBandEnergy: Double
    let evidence: SpectrumEvidence
}

private enum AnalyzerError: LocalizedError {
    case emptyFile
    case fftSetupFailed
    case unreadablePCM
    case audioOpenFailed(OSStatus)
    case audioFormatFailed(OSStatus)
    case audioLengthFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "Audio file has no readable PCM frames."
        case .fftSetupFailed:
            return "Unable to create Accelerate FFT setup."
        case .unreadablePCM:
            return "Unable to read PCM samples. The file may be protected, corrupt, or unsupported by the macOS audio decoder."
        case .audioOpenFailed(let status):
            return "Unable to open audio file (\(status))."
        case .audioFormatFailed(let status):
            return "Unable to prepare audio format (\(status))."
        case .audioLengthFailed(let status):
            return "Unable to read audio duration (\(status))."
        }
    }
}
