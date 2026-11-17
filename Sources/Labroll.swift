import Foundation

/// Labroll naming, without any UI (port of Labroll Utility):
///
///   clips of one card, in shooting order   GX010001.MP4, GX020001.MP4, GX010002.MP4
///   renamed LABROLL C### _YYYYMMDD _CAMID   A001C001_20261102_GOPRO.MP4, A001C002_..., A001C003_...
///
/// Cards without a reel ID are named after their labroll (A001_GOPRO), so card and clips match.
enum Labroll {

    static let clipExtensions: Set<String> = ["mp4", "mov", "mxf"]
    static let skippedFolders: Set<String> = ["__MACOSX", "Trash", "System Volume Information"]

    // MARK: - Clips

    /// Clips below the given folders (or the files themselves), each folder in shooting order.
    /// Hidden and empty files skipped, MXF too when `ignoreMXF`.
    static func clips(in urls: [URL], ignoreMXF: Bool) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        var loose: [URL] = []

        func accept(_ url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            guard clipExtensions.contains(ext), !(ignoreMXF && ext == "mxf"),
                  !url.lastPathComponent.hasPrefix(".") else { return false }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size > 0
        }

        func walk(_ folder: URL) {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
            var files: [URL] = []
            var folders: [URL] = []
            for name in names.sorted() where !name.hasPrefix(".") {
                let url = folder.appendingPathComponent(name)
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    if !skippedFolders.contains(name) { folders.append(url) }
                } else if accept(url) {
                    files.append(url)
                }
            }
            found += inShootingOrder(files)
            folders.forEach(walk)
        }

        for url in urls {
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue { walk(url) } else if accept(url) { loose.append(url) }
        }
        return found + inShootingOrder(loose)
    }

    /// Sorted by recording date, then GoPro clip number and chapter (GX010001, GX020001, GX010002).
    static func inShootingOrder(_ urls: [URL]) -> [URL] {
        let keyed = urls.map { url -> (URL, Date, Int, Int) in
            let (clip, chapter) = goProNumbers(url.lastPathComponent)
            return (url, recordingDate(url) ?? .distantFuture, clip, chapter)
        }
        return keyed.sorted {
            ($0.1, $0.2, $0.3, $0.0.lastPathComponent) < ($1.1, $1.2, $1.3, $1.0.lastPathComponent)
        }.map(\.0)
    }

    private static let goProPattern = try! Regex("^G[HSPX]([0-9]{2})([0-9]{4})")

    /// GX010042.MP4 -> clip 42, chapter 1. (0, 0) for other cameras.
    static func goProNumbers(_ name: String) -> (clip: Int, chapter: Int) {
        guard let match = try? goProPattern.prefixMatch(in: name),
              let chapter = match.output[1].substring.flatMap({ Int($0) }),
              let clip = match.output[2].substring.flatMap({ Int($0) }) else { return (0, 0) }
        return (clip, chapter)
    }

    /// Creation time in the MP4 / MOV header (mvhd), else the file creation date.
    static func recordingDate(_ url: URL) -> Date? {
        if let date = movieHeaderDate(url) { return date }
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// moov/mvhd creation_time: seconds since 1904-01-01 UTC. Nil for MXF, damaged files or a zero date.
    static func movieHeaderDate(_ url: URL) -> Date? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return nil }

        func read(_ offset: UInt64, _ count: Int) -> [UInt8]? {
            guard (try? file.seek(toOffset: offset)) != nil,
                  let data = try? file.read(upToCount: count), data.count == count else { return nil }
            return [UInt8](data)
        }
        func number(_ bytes: ArraySlice<UInt8>) -> UInt64 { bytes.reduce(0) { $0 << 8 | UInt64($1) } }

        /// Child boxes of [start, end): type, body offset, end offset.
        func boxes(_ start: UInt64, _ end: UInt64) -> [(String, UInt64, UInt64)] {
            var result: [(String, UInt64, UInt64)] = []
            var offset = start
            while offset + 8 <= end, let head = read(offset, 8), result.count < 1000 {
                var boxSize = number(head[0..<4])
                let type = String(decoding: head[4..<8], as: UTF8.self)
                var header: UInt64 = 8
                if boxSize == 1 {
                    guard let large = read(offset + 8, 8) else { break }
                    boxSize = number(large[0...])
                    header = 16
                } else if boxSize == 0 {
                    boxSize = end - offset
                }
                guard boxSize >= header, offset + boxSize <= end else { break }
                result.append((type, offset + header, offset + boxSize))
                offset += boxSize
            }
            return result
        }

        guard let moov = boxes(0, size).first(where: { $0.0 == "moov" }),
              let mvhd = boxes(moov.1, moov.2).first(where: { $0.0 == "mvhd" }),
              let version = read(mvhd.1, 1)?.first,
              let raw = read(mvhd.1 + 4, version == 1 ? 8 : 4) else { return nil }
        let seconds = number(raw[0...])
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds) - 2_082_844_800)
    }

    // MARK: - Names

    /// A001C001_20261102_GOPRO.MP4 (extension kept as on the card), with the default scheme.
    static func clipName(labroll: String, index: Int, date: Date, camID: String, extension ext: String) -> String {
        NameScheme.clipDefault.clipName(.init(labroll: labroll, clip: index, date: date, cam: camID), extension: ext)
    }

    /// A001 -> A002, B099 -> B100. Unchanged when there is no number.
    static func next(_ labroll: String) -> String {
        guard let match = try? Regex("^([A-Za-z]*)([0-9]+)").prefixMatch(in: labroll),
              let prefix = match.output[1].substring,
              let number = match.output[2].substring.flatMap({ Int($0) }) else { return labroll }
        return "\(prefix)\(String(format: "%03d", number + 1))"
    }

    /// Labroll at the start of a card name: A003 in A003_X7K2, nil for GOPRO_1.
    static func leading(_ name: String) -> String? {
        (try? Regex("^[A-Za-z]+[0-9]+").prefixMatch(in: name)).flatMap { $0.map { String(name[$0.range]) } }
    }

    /// Card name LABROLL_YYYYMMDD_CAMERA with the default scheme, parts dropped until it fits the label limit:
    /// A001_20261102_GOPRO -> A001_261102_GOPRO -> A001_GOPRO -> A001.
    static func cardName(labroll: String, camera: String, date: Date, maxLength: Int) -> String {
        NameScheme.cardDefault.cardName(.init(labroll: labroll, date: date, cam: camera), maxLength: maxLength)
    }

    static func day(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    // MARK: - Files

    enum Failure: LocalizedError {
        case exists(String)
        case cancelled
        case mismatch(String, String)

        var errorDescription: String? {
            switch self {
            case .exists(let name): return "\(name) already exists"
            case .cancelled: return "Cancelled"
            case .mismatch(let a, let b): return "Checksum mismatch after copy (\(a) / \(b))"
            }
        }
    }

    /// Copy, then read the copy back from disk and compare xxHash64. Returns the checksum.
    /// A cancelled or mismatching copy is deleted. Never overwrites.
    static func copyVerified(_ source: URL, to destination: URL,
                             progress: (Int) -> Void, cancelled: () -> Bool) throws -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { throw Failure.exists(destination.lastPathComponent) }
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        var keep = false
        defer { if !keep { try? fm.removeItem(at: destination) } }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        var sourceHash = XXHash64()
        do {
            while true {
                if cancelled() { throw Failure.cancelled }
                let chunk = try autoreleasepool { try input.read(upToCount: 8 << 20) } ?? Data()
                if chunk.isEmpty { break }
                sourceHash.update(chunk)
                try output.write(contentsOf: chunk)
                progress(chunk.count)
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            throw error
        }

        let copyHash = try hashFromDisk(destination, cancelled: cancelled)
        let expected = sourceHash.hexDigest()
        guard copyHash == expected else { throw Failure.mismatch(expected, copyHash) }

        if let dates = try? fm.attributesOfItem(atPath: source.path) {
            let kept = dates.filter { $0.key == .creationDate || $0.key == .modificationDate }
            try? fm.setAttributes(kept, ofItemAtPath: destination.path)
        }
        keep = true
        return copyHash
    }

    /// xxHash64 of a file, read past the system cache so a copy is checked on the disk itself.
    static func hashFromDisk(_ url: URL, cancelled: () -> Bool = { false }) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        _ = fcntl(file.fileDescriptor, F_NOCACHE, 1)
        var hash = XXHash64()
        while true {
            if cancelled() { throw Failure.cancelled }
            let chunk = try autoreleasepool { try file.read(upToCount: 8 << 20) } ?? Data()
            if chunk.isEmpty { break }
            hash.update(chunk)
        }
        return hash.hexDigest()
    }

    /// Rename in place. Never overwrites.
    static func renameInPlace(_ source: URL, to name: String) throws -> URL {
        let target = source.deletingLastPathComponent().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { throw Failure.exists(name) }
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }

    /// Log in Labroll Utility's format: one line per clip, old --> new | hash.
    static func logText(start: Date, end: Date, source: String, lines: [(old: String, new: String, hash: String)]) -> String {
        let utc = ISO8601DateFormatter()
        var text = "### CREATING LABROLL\nStarting at \(utc.string(from: start))\nSource: \(source)\n\n"
        for (i, line) in lines.enumerated() {
            text += "[#\(String(format: "%02d", i + 1))] \(line.old) --> \(line.new) | hash: \(line.hash)\n"
        }
        return text + "\n### END OF OPERATION at \(utc.string(from: end))\n"
    }
}
