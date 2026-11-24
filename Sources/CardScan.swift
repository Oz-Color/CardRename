import Foundation

/// Card naming rules, without any UI: what name a mounted card should get.
///
///   Reel-ID cameras (name taken from the clips, any subfolder):
///     Sony XDCAM / ARRI / Canon / DJI Ronin   D902C001_260916JN.MXF      -> D902
///     RED                                     A001_C001_0916AB_001.R3D   -> A001
///     Blackmagic                              A001_09161234_C001.braw    -> A001
///   Cameras without a reel ID (Sony C0001.MP4, DJI, GoPro, Lumix, DCIM...):
///     MODEL_YYMMDD from the oldest clip, e.g. FX3_260916, DJI_260916.
enum CardScan {

    static let mediaExtensions: Set<String> = [
        "mxf", "mp4", "mov", "braw", "r3d", "ari", "arx", "crm", "mts", "m2ts", "avi", "mkv", "insv", "360",
    ]
    static let cardFolders = ["XDROOT", "PRIVATE", "DCIM", "CONTENTS", "CLIPS001"]
    static let maxDepth = 5

    enum Proposal: Equatable {
        case reel(String)                    // one reel ID found, ready to use
        case noReel(suggestion: String)      // clips without reel ID, suggested MODEL_YYMMDD
        case multipleReels([String])         // mixed card, never renamed
        case noClips
        case unreadable                      // macOS refused access to the card
    }

    // MARK: - Analysis

    static func analyze(root: URL, maxLength: Int) -> Proposal {
        guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil else { return .unreadable }

        let files = mediaFiles(in: root)
        if files.isEmpty { return .noClips }

        let reels = reelIDs(in: files.map { $0.lastPathComponent })
        switch reels.count {
        case 1:  return .reel(cleanName(reels[0], maxLength: maxLength))
        case 0:  break
        default: return .multipleReels(reels)
        }

        let tag = cameraTag(root: root, files: files)
        let date = oldestDate(of: files) ?? ""
        return .noReel(suggestion: cleanName("\(tag)_\(date)", maxLength: maxLength))
    }

    /// Video files below `root`, hidden folders and ._ files skipped.
    static func mediaFiles(in root: URL, maxDepth: Int = maxDepth, limit: Int = .max) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true })
        else { return [] }

        var found: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if walker.level >= maxDepth { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true,
                  mediaExtensions.contains(url.pathExtension.lowercased()) else { continue }
            found.append(url)
            if found.count >= limit { break }
        }
        return found
    }

    private static let reelPatterns = [
        try! Regex("^([A-Z0-9]{4})C[0-9]{3,4}_"),       // Sony XDCAM, ARRI, Canon, DJI Ronin
        try! Regex("^([A-Z]_[0-9]{4})C[0-9]{3}"),       // ARRI Alexa 35 / Mini LF (A_0001C001)
        try! Regex("^([A-Z][0-9]{3})_[A-Z][0-9]{3}_"),  // RED, any camera letter (A003_C001, B003_B012)
        try! Regex("^([A-Z][0-9]{3})_[0-9]{8}_C[0-9]{3}"), // Blackmagic
    ]

    /// Unique reel IDs found in clip names, sorted.
    static func reelIDs(in names: [String]) -> [String] {
        var reels = Set<String>()
        for name in names {
            let upper = name.uppercased()
            for pattern in reelPatterns {
                if let match = try? pattern.prefixMatch(in: upper),
                   let reel = match.output[1].substring {
                    reels.insert(String(reel))
                    break
                }
            }
        }
        return reels.sorted()
    }

    // MARK: - Camera letter (A, B, C... -> "A CAM")

    private static let letterPatterns = [
        try! Regex("^([A-Z])[0-9]{3}C[0-9]{3,4}"),            // A001C001 (Sony, ARRI, Canon, Ronin)
        try! Regex("^([A-Z])_[0-9]{4}C[0-9]{3}"),             // A_0001C001 (ARRI Alexa 35)
        try! Regex("^([A-Z])[0-9]{3}_"),                      // A003_C001 (RED), A007_0916... (Blackmagic)
        try! Regex("(?:^|[^A-Z0-9])([A-Z])[ _-]?CAM(?:[^A-Z]|$)"),  // A_CAM_0001, ACAM001, CLIP-B-CAM
        try! Regex("(?:^|[^A-Z0-9])CAM(?:ERA)?[ _-]?([A-Z])(?:[^A-Z]|$)"),  // CAM_A_0001, CAMERA-B, CAMC001
    ]

    /// Camera letter of one clip name, nil when the name carries none (GX010001, C0001, DJI_0001...).
    static func cameraLetter(in name: String) -> Character? {
        let stem = (name as NSString).deletingPathExtension.uppercased()
        for pattern in letterPatterns {
            if let match = try? pattern.firstMatch(in: stem), let letter = match.output[1].substring?.first {
                return letter
            }
        }
        return nil
    }

    /// The camera letter most clips carry (CAM_A_0008, CAM_A_0009, CAM_B_0024 -> A).
    /// nil when no clip has one, or when two letters tie for first place.
    static func dominantCameraLetter(in names: [String]) -> Character? {
        var counts: [Character: Int] = [:]
        for name in names { if let letter = cameraLetter(in: name) { counts[letter, default: 0] += 1 } }
        let ranked = counts.sorted { $0.value > $1.value }
        guard let top = ranked.first else { return nil }
        if ranked.count > 1 && ranked[1].value == top.value { return nil }
        return top.key
    }

    // MARK: - Clip and reel numbers, gaps

    private static let clipNumberPatterns = [
        try! Regex("^[A-Z][0-9]{3}C([0-9]{3,4})"),                    // A001C003
        try! Regex("^[A-Z]_[0-9]{4}C([0-9]{3})"),                     // A_0001C003 (Alexa 35)
        try! Regex("^[A-Z][0-9]{3}_[A-Z]([0-9]{3})_"),                // B003_B012 (RED)
        try! Regex("^[A-Z][0-9]{3}_[0-9]{8}_C([0-9]{3})"),            // A007_09161234_C003 (Blackmagic)
        try! Regex("(?:^|[^A-Z0-9])CAM(?:ERA)?[ _-]?[A-Z][ _-]?([0-9]{2,})"),  // CAM_E_0013 (Sony)
        try! Regex("(?:^|[^A-Z0-9])[A-Z][ _-]?CAM[ _-]?([0-9]{2,})"),          // A_CAM_0013
    ]

    /// Clip number of one clip name: 3 in A001C003, 13 in CAM_E_0013. nil when none.
    static func clipNumber(in name: String) -> Int? {
        let stem = (name as NSString).deletingPathExtension.uppercased()
        for pattern in clipNumberPatterns {
            if let match = try? pattern.firstMatch(in: stem), let digits = match.output[1].substring { return Int(digits) }
        }
        return nil
    }

    /// Clip numbers of the clips of camera `letter` (proxies and spanned files counted once).
    static func clipNumbers(in names: [String], letter: String) -> [Int] {
        Set(names.filter { cameraLetter(in: $0).map(String.init) == letter }.compactMap(clipNumber(in:))).sorted()
    }

    /// Camera letter and number of a reel ID: A005 -> (A, 5), A_0001 -> (A, 1).
    static func reelNumber(_ reel: String) -> (letter: String, number: Int)? {
        guard let match = try? Regex("^([A-Z])_?([0-9]+)$").wholeMatch(in: reel.uppercased()),
              let letter = match.output[1].substring, let digits = match.output[2].substring,
              let number = Int(digits) else { return nil }
        return (String(letter), number)
    }

    /// What looks missing from camera `letter`:
    /// - `reel` beyond `nextReel` (the reel expected after the last card of that camera);
    /// - clip numbers skipped on the card;
    /// - without a reel (CAM_E_0013, numbered across cards), a first clip beyond `lastClip` + 1.
    static func gaps(letter: String, reel: Int?, nextReel: Int?, clips: [Int], lastClip: Int?) -> [String] {
        func span(_ from: Int, _ to: Int, _ format: (Int) -> String) -> String {
            from == to ? format(from) : "\(format(from)) to \(format(to))"
        }
        let reelName = { (n: Int) in letter + String(format: "%03d", n) }
        let clipName = { (n: Int) in String(format: "%03d", n) }
        var result: [String] = []
        if let reel, let nextReel, reel > nextReel {
            result.append("Reel\(reel - 1 > nextReel ? "s" : "") \(span(nextReel, reel - 1, reelName)) missing: the last card of camera \(letter) was \(reelName(nextReel - 1)), this one is \(reelName(reel)).")
        }
        if reel == nil, let lastClip, let first = clips.first, first > lastClip + 1 {
            result.append("Clip\(first - 1 > lastClip + 1 ? "s" : "") \(span(lastClip + 1, first - 1, clipName)) missing: the last card of camera \(letter) ended at clip \(clipName(lastClip)), this one starts at \(clipName(first)).")
        }
        var missing: [String] = []
        for (a, b) in zip(clips, clips.dropFirst()) where b > a + 1 { missing.append(span(a + 1, b - 1, clipName)) }
        if !missing.isEmpty {
            let shown = missing.prefix(5).joined(separator: ", ") + (missing.count > 5 ? "…" : "")
            result.append("Clip\(missing.count == 1 && !missing[0].contains(" to ") ? "" : "s") \(shown) missing on this card.")
        }
        return result
    }

    /// Short camera tag for cards without a reel ID.
    static func cameraTag(root: URL, files: [URL]) -> String {
        let fm = FileManager.default

        // Sony XAVC S / XAVC HS: model in the clip XML (<Device ... modelName="ILME-FX3">)
        let m4 = root.appendingPathComponent("PRIVATE/M4ROOT")
        if fm.fileExists(atPath: m4.path) {
            let clipDir = m4.appendingPathComponent("Clip")
            let xmls = (try? fm.contentsOfDirectory(at: clipDir, includingPropertiesForKeys: nil)) ?? []
            for xml in xmls where xml.pathExtension.lowercased() == "xml" {
                guard let text = try? String(contentsOf: xml, encoding: .utf8),
                      let match = try? Regex("modelName=\"([^\"]+)\"").firstMatch(in: text),
                      let model = match.output[1].substring else { continue }
                return String(model).replacing(try! Regex("^[A-Za-z]+-"), with: "")
            }
            return "SONY"
        }

        if files.contains(where: { $0.lastPathComponent.uppercased().hasPrefix("DJI_") }) { return "DJI" }
        if fm.fileExists(atPath: root.appendingPathComponent("PRIVATE/PANA_GRP").path) { return "LUMIX" }

        // DCIM/100GOPRO, DCIM/100CANON, DCIM/100_PANA... -> GOPRO, CANON, PANA
        let dcim = root.appendingPathComponent("DCIM")
        let folders = ((try? fm.contentsOfDirectory(atPath: dcim.path)) ?? []).sorted()
        for folder in folders where folder.prefix(3).allSatisfy(\.isNumber) && folder.count > 3 {
            let tag = folder.dropFirst(3).filter { $0.isLetter || $0.isNumber }
            if !tag.isEmpty && tag.uppercased() != "MEDIA" { return String(tag) }
        }

        return "CARD"
    }

    /// Date of the oldest clip, YYMMDD.
    static func oldestDate(of files: [URL]) -> String? {
        let dates = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        guard let oldest = dates.min() else { return nil }
        let format = DateFormatter()
        format.dateFormat = "yyMMdd"
        return format.string(from: oldest)
    }

    // MARK: - Volume names

    /// Keep A-Z 0-9 _ - and single inner spaces ("A CAM"), and fit the file system label limit.
    static func cleanName(_ raw: String, maxLength: Int) -> String {
        var name = String(raw.uppercased().unicodeScalars.filter {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" || $0 == " "
        }.map(Character.init))
        name = name.split(separator: " ").joined(separator: " ")
        if name.count > maxLength { name.removeAll { $0 == "_" || $0 == "-" || $0 == " " } }
        return String(name.prefix(maxLength))
    }

    /// Volume label limit for a file system type as reported by statfs.
    /// exFAT labels hold 11 characters, like FAT32: diskutil refuses a 12th.
    static func maxLabelLength(fsType: String) -> Int {
        switch fsType.lowercased() {
        case "apfs", "hfs": return 27
        default:            return 11   // exfat, msdos (FAT32) or unknown
        }
    }

    /// "UNTITLED", "UNTITLED 2", "DJI1"... for the list "UNTITLED, NO NAME, DJI".
    static func isDefaultName(_ name: String, defaults: [String]) -> Bool {
        let alternatives = defaults
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        guard !alternatives.isEmpty,
              let pattern = try? Regex("^(\(alternatives.joined(separator: "|"))) ?[0-9]{0,2}$") else { return false }
        return (try? pattern.wholeMatch(in: name.uppercased())) != nil
    }

    /// Card folders, or reel-named or camera-lettered clips near the root (RED, ARRI, Blackmagic, Ronin, CAM_E_0013).
    static func looksLikeCard(_ root: URL) -> Bool {
        let fm = FileManager.default
        if cardFolders.contains(where: { fm.fileExists(atPath: root.appendingPathComponent($0).path) }) { return true }
        let names = mediaFiles(in: root, maxDepth: 3, limit: 50).map(\.lastPathComponent)
        return !reelIDs(in: names).isEmpty || names.contains { cameraLetter(in: $0) != nil }   // or CAM_E_0013.MXF
    }
}

/// What statfs knows about a mount point.
struct VolumeInfo {
    let device: String   // /dev/disk4s1
    let fsType: String   // exfat, msdos, apfs...

    init?(path: String) {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        device = withUnsafeBytes(of: stats.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        fsType = withUnsafeBytes(of: stats.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
}
