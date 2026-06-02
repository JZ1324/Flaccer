import Darwin
import Foundation

enum FinderTagService {
    static func applyTag(for result: SpectrumResult) throws {
        guard result.verdict != .all else { return }

        var tags = try rawTags(for: result.url)
        tags.removeAll { tag in
            let name = visibleTagName(from: tag)
            return name.hasPrefix("Flaccer") || colorIndex(from: tag) != nil || defaultColorTagNames.contains(name)
        }
        tags.append(tagEntry(for: result.verdict))
        try writeRawTags(tags, to: result.url)
    }

    private static let userTagsAttribute = "com.apple.metadata:_kMDItemUserTags"
    private static let defaultColorTagNames: Set<String> = ["Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]

    private static func tagEntry(for verdict: SpectrumVerdict) -> String {
        let tag = coloredTag(for: verdict)
        return "\(tag.name)\n\(tag.colorIndex)"
    }

    private static func coloredTag(for verdict: SpectrumVerdict) -> (name: String, colorIndex: Int) {
        switch verdict {
        case .lossless:
            return ("Green", 2)
        case .medium:
            return ("Yellow", 5)
        case .fake:
            return ("Red", 6)
        case .error:
            return ("Gray", 1)
        case .all:
            return ("", 0)
        }
    }

    private static func rawTags(for url: URL) throws -> [String] {
        if let data = try extendedAttributeData(named: userTagsAttribute, from: url),
           let tags = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] {
            return tags
        }

        let resourceTags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        return resourceTags
    }

    private static func writeRawTags(_ tags: [String], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        try withFileSystemPath(for: url) { path in
            let result = data.withUnsafeBytes { buffer in
                setxattr(path, userTagsAttribute, buffer.baseAddress, data.count, 0, 0)
            }

            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func extendedAttributeData(named name: String, from url: URL) throws -> Data? {
        try withFileSystemPath(for: url) { path in
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length >= 0 else {
                if errno == ENOATTR {
                    return nil
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            var data = Data(count: length)
            let readLength = data.withUnsafeMutableBytes { buffer in
                getxattr(path, name, buffer.baseAddress, length, 0, 0)
            }

            guard readLength >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return data
        }
    }

    private static func visibleTagName(from rawTag: String) -> String {
        rawTag.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? rawTag
    }

    private static func colorIndex(from rawTag: String) -> Int? {
        let parts = rawTag.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let colorIndex = Int(parts[1]),
              (1...7).contains(colorIndex)
        else {
            return nil
        }
        return colorIndex
    }

    private static func withFileSystemPath<T>(for url: URL, _ body: (UnsafePointer<CChar>) throws -> T) throws -> T {
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw POSIXError(.ENOENT)
            }
            return try body(path)
        }
    }
}
