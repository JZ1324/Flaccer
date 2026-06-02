import Foundation

final class WatchFolderService {
    private let queue = DispatchQueue(label: "app.flaccer.watch-folder", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var watchedFolder: URL?
    private var knownPaths = Set<String>()
    private var pendingFiles: [String: PendingFile] = [:]

    var isRunning: Bool {
        timer != nil
    }

    func start(folder: URL, interval: TimeInterval = 1.5, onNewFiles: @escaping ([URL]) -> Void) {
        stop()

        watchedFolder = folder
        knownPaths = Set(AudioFileDiscovery.audioFiles(from: folder).map(\.standardizedFileURL.path))

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, let folder = self.watchedFolder else { return }

            let currentFiles = AudioFileDiscovery.audioFiles(from: folder)
            let currentPaths = Set(currentFiles.map(\.standardizedFileURL.path))
            self.knownPaths = self.knownPaths.intersection(currentPaths)

            var readyFiles: [URL] = []
            for file in currentFiles {
                let path = file.standardizedFileURL.path
                guard !self.knownPaths.contains(path) else { continue }

                let size = self.fileSize(file)
                if var pending = self.pendingFiles[path] {
                    if pending.size == size {
                        pending.stablePolls += 1
                    } else {
                        pending.size = size
                        pending.stablePolls = 0
                    }

                    if pending.stablePolls >= 1 {
                        readyFiles.append(file)
                        self.knownPaths.insert(path)
                        self.pendingFiles.removeValue(forKey: path)
                    } else {
                        self.pendingFiles[path] = pending
                    }
                } else {
                    self.pendingFiles[path] = PendingFile(url: file, size: size, stablePolls: 0)
                }
            }

            self.pendingFiles = self.pendingFiles.filter { currentPaths.contains($0.key) }

            guard !readyFiles.isEmpty else { return }
            DispatchQueue.main.async {
                onNewFiles(readyFiles.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        watchedFolder = nil
        knownPaths.removeAll()
        pendingFiles.removeAll()
    }

    private func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private struct PendingFile {
        let url: URL
        var size: Int64
        var stablePolls: Int
    }
}
