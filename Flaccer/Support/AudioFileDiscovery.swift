import Foundation

enum AudioFileDiscovery {
    static let supportedExtensions: Set<String> = ["flac", "wav", "wave", "aif", "aiff", "alac", "m4a", "mp3", "aac", "caf"]
    static let supportedPlaylistExtensions: Set<String> = ["m3u", "m3u8", "xml"]

    static func isSupportedAudioURL(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func isSupportedImportURL(_ url: URL) -> Bool {
        isSupportedAudioURL(url) || supportedPlaylistExtensions.contains(url.pathExtension.lowercased())
    }

    static func audioFiles(from urls: [URL]) -> [URL] {
        var discovered: [URL] = []
        for url in urls {
            discovered.append(contentsOf: audioFiles(from: url))
        }
        return uniquedPreservingOrder(discovered)
    }

    static func audioFiles(from url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }

        if !isDirectory.boolValue {
            if isSupportedAudioURL(url) {
                return [url.standardizedFileURL]
            }
            return playlistAudioFiles(from: url)
        }

        var discovered: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        for case let fileURL as URL in enumerator {
            if isSupportedAudioURL(fileURL) {
                discovered.append(fileURL.standardizedFileURL)
            } else if supportedPlaylistExtensions.contains(fileURL.pathExtension.lowercased()) {
                discovered.append(contentsOf: playlistAudioFiles(from: fileURL))
            }
        }

        return uniquedPreservingOrder(discovered.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
    }

    private static func playlistAudioFiles(from url: URL) -> [URL] {
        switch url.pathExtension.lowercased() {
        case "m3u", "m3u8":
            return m3uAudioFiles(from: url)
        case "xml":
            return rekordboxAudioFiles(from: url)
        default:
            return []
        }
    }

    private static func m3uAudioFiles(from url: URL) -> [URL] {
        guard let text = readPlaylistText(from: url) else {
            return []
        }

        let baseURL = url.deletingLastPathComponent()
        let files = text
            .components(separatedBy: .newlines)
            .compactMap { line -> URL? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                    return nil
                }
                return fileURL(fromPlaylistEntry: trimmed, relativeTo: baseURL)
            }
            .filter { isSupportedAudioURL($0) }

        return uniquedPreservingOrder(files)
    }

    private static func rekordboxAudioFiles(from url: URL) -> [URL] {
        guard let parser = XMLParser(contentsOf: url) else {
            return []
        }

        let collector = RekordboxTrackLocationCollector(baseURL: url.deletingLastPathComponent())
        parser.delegate = collector
        guard parser.parse() else {
            return []
        }

        return uniquedPreservingOrder(collector.urls.filter { isSupportedAudioURL($0) })
    }

    private static func readPlaylistText(from url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    private static func fileURL(fromPlaylistEntry entry: String, relativeTo baseURL: URL) -> URL? {
        if entry.hasPrefix("file://") {
            let encodedEntry = entry.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? entry
            if let url = URL(string: entry), url.isFileURL {
                return url.standardizedFileURL
            }
            if let url = URL(string: encodedEntry), url.isFileURL {
                return url.standardizedFileURL
            }
        }

        if entry.hasPrefix("~/") {
            let expandedPath = NSString(string: entry).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }

        if entry.hasPrefix("/") {
            return URL(fileURLWithPath: entry).standardizedFileURL
        }

        return baseURL.appendingPathComponent(entry).standardizedFileURL
    }

    private static func uniquedPreservingOrder(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []

        for url in urls {
            let standardizedURL = url.standardizedFileURL
            guard seen.insert(standardizedURL.path).inserted else {
                continue
            }
            output.append(standardizedURL)
        }

        return output
    }
}

private final class RekordboxTrackLocationCollector: NSObject, XMLParserDelegate {
    let baseURL: URL
    private(set) var urls: [URL] = []

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.localizedCaseInsensitiveContains("track"),
              let location = attributeDict.first(where: { $0.key.localizedCaseInsensitiveCompare("Location") == .orderedSame })?.value,
              let url = AudioFileDiscovery.fileURLFromRekordboxLocation(location, relativeTo: baseURL)
        else {
            return
        }

        urls.append(url)
    }
}

private extension AudioFileDiscovery {
    static func fileURLFromRekordboxLocation(_ location: String, relativeTo baseURL: URL) -> URL? {
        let decoded = location.removingPercentEncoding ?? location
        return fileURL(fromPlaylistEntry: decoded, relativeTo: baseURL)
    }
}
