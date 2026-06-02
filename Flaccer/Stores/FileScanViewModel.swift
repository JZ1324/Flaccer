import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FileScanViewModel: ObservableObject {
    @Published var results: [SpectrumResult] = []
    @Published var scanItems: [ScanItem] = []
    @Published var selectedResultID: SpectrumResult.ID?
    @Published var filter: SpectrumVerdict = .all {
        didSet {
            reconcileSelection()
        }
    }
    @Published var trashRequest: TrashRequest?
    @Published var isPreparingScan = false
    @Published var isScanning = false
    @Published var hasFirstResultReady = false
    @Published var progressCompleted = 0
    @Published var progressTotal = 0
    @Published var currentActivity = "Ready"
    @Published var errorMessage: String?
    @Published var watchFolder: URL?
    @Published var isWatching = false

    @Published var applyFinderTags: Bool {
        didSet {
            UserDefaults.standard.set(applyFinderTags, forKey: Defaults.applyFinderTags)
        }
    }

    @Published var concurrencyLimit: Int {
        didSet {
            concurrencyLimit = min(max(concurrencyLimit, 1), 100)
            UserDefaults.standard.set(concurrencyLimit, forKey: Defaults.concurrencyLimit)
        }
    }

    private let watchService = WatchFolderService()
    private var pendingAnalysisFiles: [URL] = []
    private var isProcessingAnalysisQueue = false
    private var pendingTagResults: [SpectrumResult] = []
    private var isProcessingTagQueue = false
    private var pendingSpectrogramPaths: Set<String> = []
    private var scanItemIndexByPath: [String: Int] = [:]
    private var resultIndexByPath: [String: Int] = [:]
    private var nextScanSequence = 0

    init() {
        if !UserDefaults.standard.bool(forKey: Defaults.applyFinderTagsEnabledByDefault) {
            applyFinderTags = true
            UserDefaults.standard.set(true, forKey: Defaults.applyFinderTags)
            UserDefaults.standard.set(true, forKey: Defaults.applyFinderTagsEnabledByDefault)
        } else if UserDefaults.standard.object(forKey: Defaults.applyFinderTags) == nil {
            applyFinderTags = true
            UserDefaults.standard.set(true, forKey: Defaults.applyFinderTags)
        } else {
            applyFinderTags = UserDefaults.standard.bool(forKey: Defaults.applyFinderTags)
        }

        let balancedDefaultLimit = min(max(ProcessInfo.processInfo.activeProcessorCount / 3, 2), 4)
        let storedLimit = UserDefaults.standard.integer(forKey: Defaults.concurrencyLimit)
        let shouldMoveToBalancedDefault =
            storedLimit == 0 ||
            !UserDefaults.standard.bool(forKey: Defaults.concurrencyFastDefaultMigrated) && storedLimit <= 8 ||
            !UserDefaults.standard.bool(forKey: Defaults.concurrencyBalancedDefaultMigrated) && storedLimit > 8

        if shouldMoveToBalancedDefault {
            concurrencyLimit = balancedDefaultLimit
            UserDefaults.standard.set(balancedDefaultLimit, forKey: Defaults.concurrencyLimit)
            UserDefaults.standard.set(true, forKey: Defaults.concurrencyFastDefaultMigrated)
            UserDefaults.standard.set(true, forKey: Defaults.concurrencyBalancedDefaultMigrated)
        } else {
            concurrencyLimit = min(max(storedLimit, 1), 100)
        }
    }

    var filteredResults: [SpectrumResult] {
        filteredScanItems.compactMap(\.result)
    }

    var filteredScanSections: [ScanItemSection] {
        let items = filteredScanItems
        guard !items.isEmpty else {
            return []
        }

        var sections: [ScanItemSection] = []
        for item in items {
            let section = sectionDescriptor(for: item)
            if sections.last?.id == section.id {
                var previous = sections.removeLast()
                previous.items.append(item)
                sections.append(previous)
            } else {
                sections.append(ScanItemSection(id: section.id, title: section.title, items: [item]))
            }
        }
        return sections
    }

    var filteredScanItems: [ScanItem] {
        let visibleItems: [ScanItem]
        if filter == .all {
            visibleItems = scanItems
        } else {
            visibleItems = scanItems.filter { $0.result?.verdict == filter }
        }
        return visibleItems.sorted(by: scanItemSort)
    }

    var showsWorkSurface: Bool {
        !scanItems.isEmpty
    }

    var selectedResult: SpectrumResult? {
        let visibleResults = filteredResults
        guard !visibleResults.isEmpty else { return nil }
        guard let selectedResultID else { return visibleResults.first }
        return visibleResults.first { $0.id == selectedResultID } ?? visibleResults.first
    }

    var actionTargetResults: [SpectrumResult] {
        if filter != .all {
            return filteredResults
        }
        return selectedResult.map { [$0] } ?? []
    }

    var actionTargetCount: Int {
        actionTargetResults.count
    }

    var progressFraction: Double {
        guard progressTotal > 0 else { return 0 }
        return Double(progressCompleted) / Double(progressTotal)
    }

    var losslessCount: Int { count(for: .lossless) }
    var mediumCount: Int { count(for: .medium) }
    var fakeCount: Int { count(for: .fake) }
    var errorCount: Int { count(for: .error) }

    func count(for verdict: SpectrumVerdict) -> Int {
        verdict == .all ? scanItems.count : results.filter { $0.verdict == verdict }.count
    }

    func selectNextResult() {
        selectResult(offset: 1)
    }

    func selectPreviousResult() {
        selectResult(offset: -1)
    }

    func ensureSpectrogram(for result: SpectrumResult, prewarmRaster: Bool = false) {
        guard result.verdict != .error else { return }

        if result.hasSpectrogram {
            if prewarmRaster {
                Task {
                    await prewarmFirstSpectrogram(for: result)
                }
            }
            return
        }

        let key = pathKey(for: result)
        guard !pendingSpectrogramPaths.contains(key) else {
            return
        }

        pendingSpectrogramPaths.insert(key)
        Task {
            defer {
                pendingSpectrogramPaths.remove(key)
            }

            do {
                let frames = try await AudioAnalyzer.spectrogramFrames(url: result.url)
                guard !Task.isCancelled else { return }
                guard let updatedResult = updateSpectrogramFrames(frames, forPathKey: key) else {
                    return
                }

                if prewarmRaster {
                    await prewarmFirstSpectrogram(for: updatedResult)
                }
            } catch {
                if selectedResultID == result.id {
                    currentActivity = "Could not render graph for \(result.fileName)"
                }
            }
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose Audio Files or Folders"
        panel.message = "Choose audio files, folders, M3U playlists, or Rekordbox XML."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        if panel.runModal() == .OK {
            scan(urls: panel.urls)
        }
    }

    func handleDrop(providers: [NSItemProvider]) {
        guard !providers.isEmpty else {
            return
        }

        isScanning = true
        isPreparingScan = true
        currentActivity = "Preparing files"
        if scanItems.isEmpty {
            hasFirstResultReady = false
        }

        Task {
            let urls = await droppedURLs(from: providers)
            guard !urls.isEmpty else {
                isPreparingScan = false
                if progressCompleted >= progressTotal {
                    isScanning = false
                }
                currentActivity = progressTotal > 0 ? currentActivity : "Ready"
                return
            }
            scan(urls: urls)
        }
    }

    func scan(urls: [URL]) {
        guard !urls.isEmpty else {
            return
        }

        isScanning = true
        isPreparingScan = true
        currentActivity = "Preparing files"
        if scanItems.isEmpty {
            hasFirstResultReady = false
        }
        autoWatchFolderIfAvailable(from: urls)

        Task {
            let files = await Task.detached(priority: .userInitiated) {
                AudioFileDiscovery.audioFiles(from: urls)
            }.value

            guard !Task.isCancelled else { return }

            isPreparingScan = false
            guard !files.isEmpty else {
                if progressCompleted >= progressTotal {
                    isScanning = false
                }
                errorMessage = "No supported audio files found."
                currentActivity = progressTotal > 0 ? currentActivity : "Ready"
                return
            }

            let queuedFiles = queue(files: files)
            guard !queuedFiles.isEmpty else {
                if progressCompleted >= progressTotal {
                    isScanning = false
                }
                currentActivity = progressTotal > 0 ? currentActivity : "Ready"
                return
            }

            progressTotal += queuedFiles.count
            pendingAnalysisFiles.append(contentsOf: queuedFiles)
            currentActivity = "Queued \(queuedFiles.count) file\(queuedFiles.count == 1 ? "" : "s")"
            await processQueuedFiles()
        }
    }

    func revealSelectedInFinder() {
        revealActionTargetsInFinder()
    }

    func copySelectedPath() {
        copyActionTargetPaths()
    }

    func revealActionTargetsInFinder() {
        revealInFinder(actionTargetResults)
    }

    func copyActionTargetPaths() {
        copyPaths(actionTargetResults)
    }

    func revealInFinder(_ targets: [SpectrumResult]) {
        let urls = targets.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copyPaths(_ targets: [SpectrumResult]) {
        let paths = targets.map { $0.url.path }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        currentActivity = paths.count == 1 ? "Copied path" : "Copied \(paths.count) paths"
    }

    func moveSelectedToTrash() {
        requestMoveActionTargetsToTrash()
    }

    func requestMoveActionTargetsToTrash() {
        requestMoveToTrash(actionTargetResults)
    }

    func requestMoveToTrash(_ targets: [SpectrumResult]) {
        guard !targets.isEmpty else { return }
        trashRequest = TrashRequest(results: targets)
    }

    func confirmMoveRequestedToTrash() {
        guard let trashRequest else { return }
        let targets = trashRequest.results
        self.trashRequest = nil
        moveToTrash(targets)
    }

    func cancelTrashRequest() {
        trashRequest = nil
    }

    private func moveToTrash(_ targets: [SpectrumResult]) {
        guard !targets.isEmpty else { return }
        var movedIDs: Set<SpectrumResult.ID> = []
        var movedPaths: Set<String> = []

        for result in targets {
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: result.url, resultingItemURL: &trashedURL)
                movedIDs.insert(result.id)
                movedPaths.insert(pathKey(for: result))
            } catch {
                errorMessage = "Could not move \(result.fileName) to Trash: \(error.localizedDescription)"
            }
        }

        guard !movedIDs.isEmpty else { return }
        results.removeAll { movedIDs.contains($0.id) || movedPaths.contains(pathKey(for: $0)) }
        scanItems.removeAll { movedPaths.contains($0.id) }
        rebuildIndexes()
        selectedResultID = filteredResults.first?.id
        hasFirstResultReady = !results.isEmpty
        currentActivity = movedIDs.count == 1 ? "Moved to Trash" : "Moved \(movedIDs.count) files to Trash"
    }

    func exportActionTargetsCSV() {
        let targets = actionTargetResults
        guard !targets.isEmpty else { return }
        export(results: targets, defaultName: targets.count == 1 ? "flaccer-result.csv" : "flaccer-selected-results.csv")
    }

    func exportCSV() {
        guard !results.isEmpty else { return }
        export(results: results, defaultName: "flaccer-results.csv")
    }

    private func export(results exportResults: [SpectrumResult], defaultName: String) {
        guard !exportResults.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Export Flaccer Results"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try CSVExportService.write(results: exportResults, to: url)
                currentActivity = "Exported CSV"
            } catch {
                errorMessage = "Could not export CSV: \(error.localizedDescription)"
            }
        }
    }

    private func selectResult(offset: Int) {
        let visible = filteredResults
        guard !visible.isEmpty else { return }
        guard let selectedResultID,
              let currentIndex = visible.firstIndex(where: { $0.id == selectedResultID })
        else {
            self.selectedResultID = visible.first?.id
            return
        }

        let nextIndex = (currentIndex + offset + visible.count) % visible.count
        self.selectedResultID = visible[nextIndex].id
    }

    private func reconcileSelection() {
        if let selectedResultID, filteredResults.contains(where: { $0.id == selectedResultID }) {
            return
        }

        selectedResultID = filteredResults.first?.id
    }

    private func pathKey(for result: SpectrumResult) -> String {
        result.url.standardizedFileURL.path
    }

    private func pathKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func scanItemSort(_ lhs: ScanItem, _ rhs: ScanItem) -> Bool {
        let lhsGroup = groupPriority(for: lhs)
        let rhsGroup = groupPriority(for: rhs)
        if lhsGroup != rhsGroup {
            return lhsGroup < rhsGroup
        }
        return lhs.sequence < rhs.sequence
    }

    private func groupPriority(for item: ScanItem) -> Int {
        guard let result = item.result else {
            switch item.status {
            case .analyzing:
                return 4
            case .queued:
                return 5
            case .done:
                return 6
            }
        }

        switch result.verdict {
        case .fake:
            return 0
        case .medium:
            return 1
        case .lossless:
            return 2
        case .error:
            return 3
        case .all:
            return 6
        }
    }

    private func sectionDescriptor(for item: ScanItem) -> (id: String, title: String) {
        guard let result = item.result else {
            switch item.status {
            case .analyzing:
                return ("analyzing", "Analyzing")
            case .queued:
                return ("queued", "Queued")
            case .done:
                return ("done", "Done")
            }
        }

        switch result.verdict {
        case .fake:
            return ("fake", "Fake")
        case .medium:
            return ("medium", "Medium")
        case .lossless:
            return ("lossless", "Lossless")
        case .error:
            return ("error", "Error")
        case .all:
            return ("all", "All")
        }
    }

    private func prewarmFirstSpectrogram(for result: SpectrumResult) async {
        let defaults = UserDefaults.standard
        let smoothing = defaults.string(forKey: Defaults.spectrogramSmoothing) ?? "low"
        let contrast = defaults.object(forKey: Defaults.spectrogramContrast) == nil ? 1.0 : defaults.double(forKey: Defaults.spectrogramContrast)
        let noiseGate = defaults.object(forKey: Defaults.spectrogramNoiseGate) == nil ? 0.10 : defaults.double(forKey: Defaults.spectrogramNoiseGate)

        _ = await SpectrogramPreviewCache.prewarm(
            result: result,
            smoothingRaw: smoothing,
            contrast: contrast,
            noiseGate: noiseGate,
            priority: .userInitiated
        )
    }

    func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Watch Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        if panel.runModal() == .OK, let folder = panel.url {
            startWatching(folder: folder)
        }
    }

    func stopWatching() {
        watchService.stop()
        watchFolder = nil
        isWatching = false
        currentActivity = "Stopped watching folder"
    }

    private func startWatching(folder: URL) {
        watchService.start(folder: folder) { [weak self] newFiles in
            guard let self else { return }
            self.scan(urls: newFiles)
        }
        watchFolder = folder
        isWatching = true
        currentActivity = "Watching \(folder.lastPathComponent)"
    }

    private func processQueuedFiles() async {
        guard !isProcessingAnalysisQueue else {
            return
        }

        isProcessingAnalysisQueue = true
        defer {
            isProcessingAnalysisQueue = false
        }

        if !hasFirstResultReady, results.isEmpty, let firstFile = pendingAnalysisFiles.first {
            pendingAnalysisFiles.removeFirst()
            mark(files: [firstFile], status: .analyzing)
            let result = await AudioAnalyzer.analyze(url: firstFile)
            applyAnalyzedResults([result], prewarmFirstResult: true)
        }

        while !pendingAnalysisFiles.isEmpty {
            let batch = nextAnalysisBatch()
            mark(files: batch, status: .analyzing)

            await withTaskGroup(of: SpectrumResult.self) { group in
                for file in batch {
                    group.addTask {
                        await AudioAnalyzer.analyze(url: file)
                    }
                }

                var bufferedResults: [SpectrumResult] = []
                bufferedResults.reserveCapacity(24)

                for await result in group {
                    bufferedResults.append(result)
                    if bufferedResults.count >= 24 {
                        applyAnalyzedResults(bufferedResults)
                        bufferedResults.removeAll(keepingCapacity: true)
                    }
                }

                applyAnalyzedResults(bufferedResults)
            }
        }

        if progressCompleted >= progressTotal {
            isScanning = false
            currentActivity = "Scan complete"
        }
    }

    private func applyAnalyzedResults(_ analyzedResults: [SpectrumResult], prewarmFirstResult: Bool = false) {
        guard !analyzedResults.isEmpty else {
            return
        }

        let shouldRevealFirstResult = !hasFirstResultReady && results.isEmpty
        upsert(analyzedResults)
        progressCompleted += analyzedResults.count
        if let lastResult = analyzedResults.last {
            currentActivity = "Analyzed \(lastResult.fileName)"
        }

        if applyFinderTags {
            enqueueFinderTags(for: analyzedResults)
        }

        if shouldRevealFirstResult || prewarmFirstResult, let firstResult = analyzedResults.first {
            hasFirstResultReady = true
            Task {
                ensureSpectrogram(for: firstResult, prewarmRaster: true)
            }
        }
    }

    private func upsert(_ analyzedResults: [SpectrumResult]) {
        var updatedScanItems = scanItems
        var updatedResults = results
        var updatedSelectedResultID = selectedResultID

        for result in analyzedResults {
            let key = pathKey(for: result)
            var finalResult = result
            if let resultIndex = resultIndexByPath[key],
               !result.hasSpectrogram,
               updatedResults[resultIndex].hasSpectrogram {
                finalResult = result.replacingSpectralFrames(updatedResults[resultIndex].spectralFrames)
            }

            if let itemIndex = scanItemIndexByPath[key] {
                updatedScanItems[itemIndex].result = finalResult
                updatedScanItems[itemIndex].status = .done
            } else {
                let item = ScanItem(url: finalResult.url, sequence: nextScanSequence, result: finalResult, status: .done)
                scanItemIndexByPath[key] = updatedScanItems.count
                updatedScanItems.append(item)
                nextScanSequence += 1
            }

            if let resultIndex = resultIndexByPath[key] {
                let replacedID = updatedResults[resultIndex].id
                updatedResults[resultIndex] = finalResult
                if updatedSelectedResultID == replacedID {
                    updatedSelectedResultID = finalResult.id
                }
            } else {
                resultIndexByPath[key] = updatedResults.count
                updatedResults.append(finalResult)
            }

            if updatedSelectedResultID == nil {
                updatedSelectedResultID = finalResult.id
            }
        }

        scanItems = updatedScanItems
        results = updatedResults
        selectedResultID = updatedSelectedResultID
        reconcileSelection()
    }

    private func updateSpectrogramFrames(_ frames: [[Float]], forPathKey key: String) -> SpectrumResult? {
        guard !frames.isEmpty,
              let resultIndex = resultIndexByPath[key]
        else {
            return nil
        }

        let updatedResult = results[resultIndex].replacingSpectralFrames(frames)
        var updatedResults = results
        updatedResults[resultIndex] = updatedResult
        results = updatedResults

        if let itemIndex = scanItemIndexByPath[key] {
            var updatedScanItems = scanItems
            updatedScanItems[itemIndex].result = updatedResult
            scanItems = updatedScanItems
        }

        return updatedResult
    }

    private func enqueueFinderTags(for results: [SpectrumResult]) {
        pendingTagResults.append(contentsOf: results)
        guard !isProcessingTagQueue else {
            return
        }

        Task {
            await processFinderTagQueue()
        }
    }

    private func processFinderTagQueue() async {
        guard !isProcessingTagQueue else {
            return
        }

        isProcessingTagQueue = true
        defer {
            isProcessingTagQueue = false
        }

        while !pendingTagResults.isEmpty {
            let batchSize = min(8, pendingTagResults.count)
            let batch = Array(pendingTagResults.prefix(batchSize))
            pendingTagResults.removeFirst(batchSize)

            await withTaskGroup(of: String?.self) { group in
                for result in batch {
                    group.addTask(priority: .utility) {
                        do {
                            try FinderTagService.applyTag(for: result)
                            return nil
                        } catch {
                            return "Could not tag \(result.fileName): \(error.localizedDescription)"
                        }
                    }
                }

                for await tagError in group {
                    if let tagError {
                        errorMessage = tagError
                    }
                }
            }
        }
    }

    private func queue(files: [URL]) -> [URL] {
        var queued: [URL] = []
        var updatedScanItems = scanItems

        for file in files {
            let key = pathKey(for: file)
            guard scanItemIndexByPath[key] == nil else { continue }
            let item = ScanItem(url: file, sequence: nextScanSequence)
            scanItemIndexByPath[key] = updatedScanItems.count
            updatedScanItems.append(item)
            queued.append(item.url)
            nextScanSequence += 1
        }

        if !queued.isEmpty {
            scanItems = updatedScanItems
        }

        return queued
    }

    private func mark(files: [URL], status: ScanItemStatus) {
        guard !files.isEmpty else {
            return
        }

        var updatedScanItems = scanItems
        var changed = false

        for file in files {
            let key = pathKey(for: file)
            guard let index = scanItemIndexByPath[key] else {
                continue
            }
            updatedScanItems[index].status = status
            changed = true
        }

        if changed {
            scanItems = updatedScanItems
        }
    }

    private func rebuildIndexes() {
        scanItemIndexByPath = Dictionary(uniqueKeysWithValues: scanItems.enumerated().map { index, item in
            (item.id, index)
        })
        resultIndexByPath = Dictionary(uniqueKeysWithValues: results.enumerated().map { index, result in
            (pathKey(for: result), index)
        })
        nextScanSequence = (scanItems.map(\.sequence).max() ?? -1) + 1
    }

    private func nextAnalysisBatch() -> [URL] {
        let workerCount = min(max(concurrencyLimit, 1), 100, pendingAnalysisFiles.count)
        let batch = Array(pendingAnalysisFiles.prefix(workerCount))
        pendingAnalysisFiles.removeFirst(batch.count)
        return batch
    }

    private func mark(file: URL, status: ScanItemStatus) {
        mark(files: [file], status: status)
    }

    private func autoWatchFolderIfAvailable(from urls: [URL]) {
        guard let folder = firstDirectory(in: urls) else {
            return
        }
        startWatching(folder: folder)
    }

    private func firstDirectory(in urls: [URL]) -> URL? {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                continue
            }
            return url.standardizedFileURL
        }
        return nil
    }

    private func droppedURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                  let url = await droppedURL(from: provider)
            else {
                continue
            }
            urls.append(url)
        }

        return urls
    }

    private func droppedURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

struct TrashRequest: Identifiable {
    let id = UUID()
    let results: [SpectrumResult]
}

private enum Defaults {
    static let applyFinderTags = "applyFinderTags"
    static let applyFinderTagsEnabledByDefault = "applyFinderTagsEnabledByDefault"
    static let concurrencyLimit = "concurrencyLimit"
    static let concurrencyFastDefaultMigrated = "concurrencyFastDefaultMigrated"
    static let concurrencyBalancedDefaultMigrated = "concurrencyBalancedDefaultMigrated"
    static let spectrogramContrast = "spectrogramContrast"
    static let spectrogramNoiseGate = "spectrogramNoiseGate"
    static let spectrogramSmoothing = "spectrogramSmoothing"
}
