import SwiftUI

private enum SpectrogramSmoothing: String, CaseIterable, Identifiable {
    case off
    case low
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .low:
            return "Low"
        case .high:
            return "High"
        }
    }
}

private final class SpectrogramRasterCache {
    static let shared = SpectrogramRasterCache()

    private let cache = NSCache<NSString, SpectrogramRasterCacheEntry>()

    private init() {
        cache.countLimit = 96
        cache.totalCostLimit = 96 * 256 * 720 * 4
    }

    func image(for key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func insert(_ image: CGImage, for key: String) {
        let cost = image.bytesPerRow * image.height
        cache.setObject(SpectrogramRasterCacheEntry(image: image), forKey: key as NSString, cost: cost)
    }
}

private final class SpectrogramRasterCacheEntry {
    let image: CGImage

    init(image: CGImage) {
        self.image = image
    }
}

enum SpectrogramPreviewCache {
    static func key(
        for result: SpectrumResult,
        smoothingRaw: String,
        contrast: Double,
        noiseGate: Double
    ) -> String {
        [
            result.id.uuidString,
            "\(result.spectralFrames.count)x\(result.spectralFrames.first?.count ?? 0)",
            smoothingRaw,
            String(format: "%.2f", contrast),
            String(format: "%.2f", noiseGate)
        ].joined(separator: "|")
    }

    static func image(
        for result: SpectrumResult,
        smoothingRaw: String,
        contrast: Double,
        noiseGate: Double
    ) -> CGImage? {
        SpectrogramRasterCache.shared.image(
            for: key(for: result, smoothingRaw: smoothingRaw, contrast: contrast, noiseGate: noiseGate)
        )
    }

    @discardableResult
    static func prewarm(
        result: SpectrumResult,
        smoothingRaw: String,
        contrast: Double,
        noiseGate: Double,
        priority: TaskPriority = .utility
    ) async -> CGImage? {
        let key = key(for: result, smoothingRaw: smoothingRaw, contrast: contrast, noiseGate: noiseGate)
        if let cachedImage = SpectrogramRasterCache.shared.image(for: key) {
            return cachedImage
        }

        let frames = result.spectralFrames
        guard let firstFrame = frames.first, !frames.isEmpty, !firstFrame.isEmpty else {
            return nil
        }

        let renderTask = Task.detached(priority: priority) {
            SpectrogramRasterizer.makeImage(
                frames: frames,
                smoothingRaw: smoothingRaw,
                contrast: contrast,
                noiseGate: noiseGate
            )
        }

        let image = await withTaskCancellationHandler {
            await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }

        guard !Task.isCancelled else {
            return nil
        }

        if let image {
            SpectrogramRasterCache.shared.insert(image, for: key)
        }
        return image
    }
}

struct SpectrogramView: View {
    let result: SpectrumResult
    @AppStorage("spectrogramContrast") private var contrast = 1.0
    @AppStorage("spectrogramNoiseGate") private var noiseGate = 0.10
    @AppStorage("spectrogramSmoothing") private var smoothingRaw = SpectrogramSmoothing.low.rawValue
    @State private var showingAdvanced = false
    @State private var rasterImage: CGImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GeometryReader { proxy in
                Canvas { context, size in
                    let plotRect = plotRect(in: size)

                    drawBackground(context: context, size: size, plotRect: plotRect)
                    drawSpectrogram(context: context, plotRect: plotRect)
                    drawGridAndAxes(context: context, plotRect: plotRect)
                    drawCutoffMarker(context: context, plotRect: plotRect)
                    drawLegend(context: context, plotRect: plotRect)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }

            Button {
                showingAdvanced.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Advanced graph settings")
            .padding(.top, 6)
            .padding(.trailing, 7)
            .popover(isPresented: $showingAdvanced) {
                advancedControls
            }
        }
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Spectrogram")
        .task(id: rasterKey) {
            if let cachedImage = SpectrogramPreviewCache.image(
                for: result,
                smoothingRaw: smoothingRaw,
                contrast: contrast,
                noiseGate: noiseGate
            ) {
                rasterImage = cachedImage
                return
            }

            rasterImage = nil
            let smoothing = smoothingRaw
            let contrast = contrast
            let noiseGate = noiseGate
            let image = await SpectrogramPreviewCache.prewarm(
                result: result,
                smoothingRaw: smoothing,
                contrast: contrast,
                noiseGate: noiseGate,
                priority: .userInitiated
            )

            guard !Task.isCancelled else { return }
            rasterImage = image
        }
    }

    private var rasterKey: String {
        SpectrogramPreviewCache.key(
            for: result,
            smoothingRaw: smoothingRaw,
            contrast: contrast,
            noiseGate: noiseGate
        )
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Graph")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Contrast")
                    Spacer()
                    Text(String(format: "%.2f", contrast))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium))
                Slider(value: $contrast, in: 0.65...1.60, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Noise Gate")
                    Spacer()
                    Text(String(format: "%.2f", noiseGate))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium))
                Slider(value: $noiseGate, in: 0.00...0.30, step: 0.01)
            }

            Picker("Smoothing", selection: $smoothingRaw) {
                ForEach(SpectrogramSmoothing.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Spacer()
                Button("Reset") {
                    contrast = 1.0
                    noiseGate = 0.10
                    smoothingRaw = SpectrogramSmoothing.low.rawValue
                }
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func plotRect(in size: CGSize) -> CGRect {
        let leftInset: CGFloat = size.width < 620 ? 46 : 52
        let topInset: CGFloat = 32
        let rightInset: CGFloat = 42
        let bottomInset: CGFloat = 18

        return CGRect(
            x: leftInset,
            y: topInset,
            width: max(size.width - leftInset - rightInset, 10),
            height: max(size.height - topInset - bottomInset, 10)
        )
    }

    private func drawBackground(context: GraphicsContext, size: CGSize, plotRect: CGRect) {
        let outerRect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        context.fill(Path(roundedRect: outerRect, cornerRadius: 12), with: .color(Color(red: 0.018, green: 0.018, blue: 0.020)))
        context.stroke(Path(roundedRect: outerRect, cornerRadius: 12), with: .color(Color.white.opacity(0.12)), lineWidth: 1)
        context.fill(Path(roundedRect: plotRect, cornerRadius: 7), with: .color(.black))
        context.stroke(Path(roundedRect: plotRect, cornerRadius: 7), with: .color(Color.white.opacity(0.10)), lineWidth: 0.8)
    }

    private func drawSpectrogram(context: GraphicsContext, plotRect: CGRect) {
        guard let firstFrame = result.spectralFrames.first, !result.spectralFrames.isEmpty, !firstFrame.isEmpty else {
            context.draw(
                Text(result.verdict == .error ? "No spectrum data" : "Loading spectrum")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55)),
                at: CGPoint(x: plotRect.midX, y: plotRect.midY)
            )
            return
        }

        guard let rasterImage else {
            context.draw(
                Text("Rendering spectrum")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45)),
                at: CGPoint(x: plotRect.midX, y: plotRect.midY)
            )
            return
        }

        var clippedContext = context
        clippedContext.clip(to: Path(roundedRect: plotRect, cornerRadius: 7))
        clippedContext.draw(Image(decorative: rasterImage, scale: 1), in: plotRect)
    }

    private func drawLegend(context: GraphicsContext, plotRect: CGRect) {
        let width: CGFloat = 76
        let height: CGFloat = 5
        let rect = CGRect(
            x: plotRect.maxX - width - 12,
            y: plotRect.minY + 12,
            width: width,
            height: height
        )
        let steps = 38

        context.fill(
            Path(roundedRect: rect.insetBy(dx: -5, dy: -4), cornerRadius: 5),
            with: .color(Color.black.opacity(0.48))
        )

        for index in 0..<steps {
            let fraction = Double(index) / Double(steps - 1)
            let stepRect = CGRect(
                x: rect.minX + rect.width * CGFloat(index) / CGFloat(steps),
                y: rect.minY,
                width: rect.width / CGFloat(steps) + 0.5,
                height: rect.height
            )
            context.fill(Path(stepRect), with: .color(color(for: fraction)))
        }

        context.draw(
            Text("low")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.44)),
            at: CGPoint(x: rect.minX, y: rect.maxY + 7),
            anchor: .leading
        )
        context.draw(
            Text("peak")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.54)),
            at: CGPoint(x: rect.maxX, y: rect.maxY + 7),
            anchor: .trailing
        )
    }

    private func drawGridAndAxes(context: GraphicsContext, plotRect: CGRect) {
        let axisColor = Color.white.opacity(0.58)
        let gridColor = Color.white.opacity(0.055)
        let tickColor = Color.white.opacity(0.26)

        for frequency in frequencyTicks(width: plotRect.width) {
            let y = yPosition(for: frequency, in: plotRect)
            var grid = Path()
            grid.move(to: CGPoint(x: plotRect.minX, y: y))
            grid.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            context.stroke(grid, with: .color(gridColor), lineWidth: 0.7)

            var tick = Path()
            tick.move(to: CGPoint(x: plotRect.minX - 9, y: y))
            tick.addLine(to: CGPoint(x: plotRect.minX - 3, y: y))
            context.stroke(tick, with: .color(tickColor), lineWidth: 0.7)

            context.draw(
                Text(label(forFrequency: frequency))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(axisColor),
                at: CGPoint(x: plotRect.minX - 12, y: y),
                anchor: .trailing
            )
        }

        let ticks = timeTicks(width: plotRect.width)
        for tick in ticks {
            let x = plotRect.minX + plotRect.width * tick.fraction
            var path = Path()
            path.move(to: CGPoint(x: x, y: plotRect.minY - 9))
            path.addLine(to: CGPoint(x: x, y: plotRect.minY))
            context.stroke(path, with: .color(tickColor), lineWidth: 0.7)

            context.draw(
                Text(tick.label)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(axisColor),
                at: CGPoint(x: x, y: plotRect.minY - 15),
                anchor: tick.labelAnchor
            )
        }
    }

    private func drawCutoffMarker(context: GraphicsContext, plotRect: CGRect) {
        guard let cutoffKhz = result.cutoffKhz, result.nyquistKhz > 0 else { return }
        let y = yPosition(for: cutoffKhz, in: plotRect)

        var path = Path()
        path.move(to: CGPoint(x: plotRect.minX, y: y))
        path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
        context.stroke(
            path,
            with: .color(.white.opacity(0.62)),
            style: StrokeStyle(lineWidth: 1, dash: [6, 5])
        )

        let label = result.cutoffText
        let labelY = min(max(y - 11, plotRect.minY + 12), plotRect.maxY - 12)
        let labelX = cutoffKhz >= result.nyquistKhz * 0.72 ? plotRect.minX + 10 : plotRect.maxX - 10
        let labelAnchor: UnitPoint = cutoffKhz >= result.nyquistKhz * 0.72 ? .leading : .trailing
        let labelOrigin = CGPoint(x: labelX, y: labelY)
        let labelWidth = max(CGFloat(label.count) * 7.8 + 12, 62)
        let labelRectX = labelAnchor == .leading ? labelOrigin.x - 6 : labelOrigin.x - labelWidth + 6
        let labelRect = CGRect(x: labelRectX, y: labelOrigin.y - 10, width: labelWidth, height: 20)
        context.fill(
            Path(roundedRect: labelRect, cornerRadius: 6),
            with: .color(Color.black.opacity(0.68))
        )

        context.draw(
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white),
            at: labelOrigin,
            anchor: labelAnchor
        )
    }

    private func yPosition(for frequencyKhz: Double, in plotRect: CGRect) -> CGFloat {
        guard result.nyquistKhz > 0 else { return plotRect.maxY }
        let fraction = min(max(frequencyKhz / result.nyquistKhz, 0), 1)
        return plotRect.maxY - plotRect.height * CGFloat(fraction)
    }

    private func frequencyTicks(width: CGFloat) -> [Double] {
        let nyquist = result.nyquistKhz
        guard nyquist > 0 else { return [0] }

        let roundedTop = (nyquist * 10).rounded(.down) / 10
        let baseValues = width < 560 ? [0, 10, 20] : [0, 5, 10, 15, 20]
        let base = baseValues.filter { Double($0) < roundedTop - 0.25 }.map(Double.init)
        return (base + [roundedTop]).sorted()
    }

    private func label(forFrequency frequency: Double) -> String {
        if abs(frequency.rounded() - frequency) < 0.05 {
            return "\(Int(frequency.rounded()))"
        }
        return String(format: "%.1f", frequency)
    }

    private func timeTicks(width: CGFloat) -> [(fraction: CGFloat, label: String, labelAnchor: UnitPoint)] {
        let duration = max(result.duration, 1)
        let maxLabels = max(3, min(9, Int(width / 92)))
        let interval = [30, 60, 90, 120, 180, 300, 600].first { duration / Double($0) <= Double(maxLabels - 1) } ?? 900
        let tickCount = max(1, Int(duration / Double(interval)))
        var ticks = (0...tickCount).map { index in
            let seconds = min(Double(index) * Double(interval), duration)
            return timeTick(seconds: seconds, duration: duration)
        }

        if let last = ticks.last, last.fraction < 0.94 {
            ticks.append(timeTick(seconds: duration, duration: duration))
        }

        return ticks
    }

    private func timeTick(seconds: Double, duration: Double) -> (fraction: CGFloat, label: String, labelAnchor: UnitPoint) {
        let fraction = CGFloat(seconds / duration)
        let anchor: UnitPoint
        if fraction < 0.04 {
            anchor = .leading
        } else if fraction > 0.96 {
            anchor = .trailing
        } else {
            anchor = .center
        }
        return (fraction, timeLabel(seconds: seconds), anchor)
    }

    private func timeLabel(seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }

    private func color(for intensity: Double) -> Color {
        let color = SpectrogramRasterizer.heatColor(for: intensity)
        return Color(
            red: Double(color.red) / 255,
            green: Double(color.green) / 255,
            blue: Double(color.blue) / 255,
            opacity: Double(color.alpha) / 255
        )
    }
}

private enum SpectrogramRasterizer {
    static func makeImage(
        frames: [[Float]],
        smoothingRaw: String,
        contrast: Double,
        noiseGate: Double
    ) -> CGImage? {
        let mode = SpectrogramSmoothing(rawValue: smoothingRaw) ?? .low
        guard let smoothed = smoothedFrames(from: frames, mode: mode), !Task.isCancelled else {
            return nil
        }
        guard let firstFrame = smoothed.first, !smoothed.isEmpty, !firstFrame.isEmpty else {
            return nil
        }

        let width = smoothed.count
        let height = firstFrame.count
        let profile = displayProfile(for: smoothed, noiseGate: noiseGate)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for xIndex in smoothed.indices {
            if Task.isCancelled {
                return nil
            }
            let frame = smoothed[xIndex]
            for yIndex in frame.indices where yIndex < height {
                let intensity = displayIntensity(
                    for: frame[yIndex],
                    contrast: contrast,
                    profile: profile
                )
                let color = heatColor(for: intensity)
                let row = height - yIndex - 1
                let offset = (row * width + xIndex) * 4
                pixels[offset] = color.red
                pixels[offset + 1] = color.green
                pixels[offset + 2] = color.blue
                pixels[offset + 3] = color.alpha
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func smoothedFrames(from frames: [[Float]], mode: SpectrogramSmoothing) -> [[Float]]? {
        guard mode != .off, let firstFrame = frames.first, frames.count > 1, firstFrame.count > 1 else {
            return frames
        }

        let timeRadius = mode == .high ? 2 : 1
        let frequencyRadius = mode == .high ? 2 : 1
        let centerWeight = mode == .high ? 2.0 : 3.0
        var output = frames

        for xIndex in frames.indices {
            if Task.isCancelled {
                return nil
            }
            let frame = frames[xIndex]
            for yIndex in frame.indices {
                var total = Double(frame[yIndex]) * centerWeight
                var weight = centerWeight

                let xStart = max(frames.startIndex, xIndex - timeRadius)
                let xEnd = min(frames.endIndex - 1, xIndex + timeRadius)
                let yStart = max(frame.startIndex, yIndex - frequencyRadius)
                let yEnd = min(frame.endIndex - 1, yIndex + frequencyRadius)

                for neighborX in xStart...xEnd {
                    for neighborY in yStart...yEnd {
                        guard neighborX != xIndex || neighborY != yIndex else { continue }
                        guard neighborY < frames[neighborX].count else { continue }

                        let distance = abs(neighborX - xIndex) + abs(neighborY - yIndex)
                        let neighborWeight = distance <= 1 ? 1.0 : 0.42
                        total += Double(frames[neighborX][neighborY]) * neighborWeight
                        weight += neighborWeight
                    }
                }

                output[xIndex][yIndex] = Float(total / weight)
            }
        }

        return output
    }

    static func displayProfile(for frames: [[Float]], noiseGate: Double) -> DisplayProfile {
        var values: [Double] = []
        values.reserveCapacity(frames.count * (frames.first?.count ?? 0))

        for frame in frames {
            for value in frame {
                values.append(min(max(Double(value), 0), 1))
            }
        }

        guard !values.isEmpty else {
            return DisplayProfile(blackPoint: 0.02, whitePoint: 1.0)
        }

        let low = percentile(values, percentile: 0.10) ?? 0.02
        let high = percentile(values, percentile: 0.992) ?? 1.0
        let gate = min(max(noiseGate, 0), 0.35)
        let softGate = max(0.012, min(gate * 0.58, 0.20))
        let blackPoint = min(max(low * 0.72, softGate), 0.32)
        let whitePoint = min(max(high, blackPoint + 0.18), 1.0)

        return DisplayProfile(blackPoint: blackPoint, whitePoint: whitePoint)
    }

    static func displayIntensity(for value: Float, contrast: Double, profile: DisplayProfile) -> Double {
        let raw = min(max(Double(value), 0), 1)
        let contrastValue = min(max(contrast, 0.45), 2.0)
        let range = max(profile.whitePoint - profile.blackPoint, 0.001)
        let lifted = min(max((raw - profile.blackPoint) / range, 0), 1)
        let gamma = max(0.46, 0.82 / contrastValue)
        let shaped = pow(lifted, gamma)
        let detailLift = pow(min(max(raw / max(profile.whitePoint, 0.05), 0), 1), 0.55) * 0.12
        let combined = min(shaped * 0.94 + detailLift, 1)

        if combined < 0.92 {
            return min(max(combined * 0.96, 0), 1)
        }

        return min(0.883 + (combined - 0.92) * 1.46, 1)
    }

    static func heatColor(for intensity: Double) -> HeatColor {
        let value = min(max(intensity, 0), 1)

        switch value {
        case 0..<0.08:
            return HeatColor(red: 0, green: 0, blue: UInt8((0.018 + value * 0.42) * 255))
        case 0.08..<0.24:
            let t = (value - 0.08) / 0.16
            return HeatColor(
                red: UInt8((0.035 + t * 0.25) * 255),
                green: UInt8((0.0 + t * 0.018) * 255),
                blue: UInt8((0.12 + t * 0.40) * 255)
            )
        case 0.24..<0.46:
            let t = (value - 0.24) / 0.22
            return HeatColor(
                red: UInt8((0.28 + t * 0.56) * 255),
                green: UInt8((0.018 + t * 0.10) * 255),
                blue: UInt8((0.48 - t * 0.35) * 255)
            )
        case 0.46..<0.68:
            let t = (value - 0.46) / 0.22
            return HeatColor(
                red: UInt8((0.84 + t * 0.16) * 255),
                green: UInt8((0.12 + t * 0.30) * 255),
                blue: UInt8((0.12 - t * 0.07) * 255)
            )
        case 0.68..<0.84:
            let t = (value - 0.68) / 0.16
            return HeatColor(
                red: 255,
                green: UInt8((0.42 + t * 0.30) * 255),
                blue: UInt8((0.05 + t * 0.06) * 255)
            )
        case 0.84..<0.96:
            let t = (value - 0.84) / 0.12
            return HeatColor(
                red: 255,
                green: UInt8((0.72 + t * 0.18) * 255),
                blue: UInt8((0.12 + t * 0.34) * 255)
            )
        default:
            let t = (value - 0.96) / 0.04
            return HeatColor(
                red: 255,
                green: UInt8((0.90 + t * 0.08) * 255),
                blue: UInt8((0.46 + t * 0.34) * 255)
            )
        }
    }

    static func percentile(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(percentile, 0), 1)
        let position = clamped * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))

        if lower == upper {
            return sorted[lower]
        }

        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    struct DisplayProfile {
        let blackPoint: Double
        let whitePoint: Double
    }

    struct HeatColor {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8 = 255
    }
}
