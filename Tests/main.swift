import Foundation

// Naming rule tests on fake card folders. Run with ./build.sh test

let fm = FileManager.default
let base = fm.temporaryDirectory.appendingPathComponent("cardrename-tests-\(getpid())")
var failures = 0

func make(_ path: String, date: String = "2026-09-16 09:00", text: String = "") {
    let url = base.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
    let format = DateFormatter()
    format.dateFormat = "yyyy-MM-dd HH:mm"
    try! fm.setAttributes([.modificationDate: format.date(from: date)!], ofItemAtPath: url.path)
}

func check(_ name: String, _ card: String, max: Int = 15, expect: CardScan.Proposal) {
    let got = CardScan.analyze(root: base.appendingPathComponent(card), maxLength: max)
    if got == expect { print("ok    \(name)") } else { print("FAIL  \(name): got \(got), expected \(expect)"); failures += 1 }
}

func expectTrue(_ name: String, _ value: Bool) {
    if value { print("ok    \(name)") } else { print("FAIL  \(name)"); failures += 1 }
}

make("xd/XDROOT/Clip/D902C001_260916JN.MXF")
make("xd/XDROOT/Clip/D902C001_260916JNM01.XML")
make("fx3/PRIVATE/M4ROOT/Clip/C0001.MP4", date: "2026-09-15 10:30")
make("fx3/PRIVATE/M4ROOT/Clip/C0002.MP4")
make("fx3/PRIVATE/M4ROOT/Clip/C0001M01.XML", text: #"<Device manufacturer="Sony" modelName="ILME-FX3" serialNo="1"/>"#)
make("dji/DCIM/DJI_001/DJI_20260914101010_0001_D.MP4", date: "2026-09-14 10:10")
make("dji/DCIM/DJI_001/DJI_20260914101010_0001_D.LRF")
make("dji2/DCIM/100MEDIA/DJI_0001.MP4", date: "2026-09-13 12:00")
make("ronin/E003_P5M025/E003C0001_261031_P5M025.MOV")
make("ronin/E003_P5M025/E003C0002_261031_P5M025.MOV")
make("red/A003_0916AB.RDM/A003_C001_0916AB.RDC/A003_C001_0916AB_001.R3D")
make("bmd/A007_09161234_C001.braw")
make("arri/B012R1AB/B012C004_260916_R1AB/B012C004_260916_R1AB.0000001.ari")
make("gopro/DCIM/100GOPRO/GX010001.MP4")
make("mix/XDROOT/Clip/A001C001_x.MXF")
make("mix/XDROOT/Clip/A002C001_x.MXF")
try! fm.createDirectory(at: base.appendingPathComponent("empty/DCIM"), withIntermediateDirectories: true)
make("hidden/.Spotlight-V100/A009C001_x.MXF")
make("hidden/DCIM/100CANON/MVI_0001.MOV")
make("deep/1/2/3/4/5/A001C001_x.MXF")

check("Sony XDCAM reel", "xd", expect: .reel("D902"))
check("Sony FX3 C0001 naming", "fx3", expect: .noReel(suggestion: "FX3_260915"))
check("DJI new naming", "dji", expect: .noReel(suggestion: "DJI_260914"))
check("DJI old naming on FAT32", "dji2", max: 11, expect: .noReel(suggestion: "DJI_260913"))
check("DJI Ronin reel", "ronin", expect: .reel("E003"))
check("RED reel", "red", expect: .reel("A003"))
check("Blackmagic reel", "bmd", expect: .reel("A007"))
check("ARRI reel", "arri", expect: .reel("B012"))
check("GoPro on FAT32 drops the underscore", "gopro", max: 11, expect: .noReel(suggestion: "GOPRO260916"))
check("two reels", "mix", expect: .multipleReels(["A001", "A002"]))
check("empty card", "empty", expect: .noClips)
check("hidden folders skipped", "hidden", expect: .noReel(suggestion: "CANON_260916"))
check("clips deeper than 5 levels ignored", "deep", expect: .noClips)

let defaults = ["UNTITLED", " NO NAME", "NONAME", "DJI "]
for name in ["UNTITLED", "Untitled 2", "NO NAME", "NO NAME 1", "DJI", "DJI 1", "DJI2", "NONAME12"] {
    expectTrue("default name \(name)", CardScan.isDefaultName(name, defaults: defaults))
}
for name in ["D901", "E003", "UNTITLED_X", "DJI_260914", "Macintosh HD"] {
    expectTrue("not a default name \(name)", !CardScan.isDefaultName(name, defaults: defaults))
}
expectTrue("looks like card: ronin (no fixed folder)", CardScan.looksLikeCard(base.appendingPathComponent("ronin")))
expectTrue("looks like card: fx3", CardScan.looksLikeCard(base.appendingPathComponent("fx3")))
make("stick/notes/holiday.mp4")
expectTrue("not a card: USB stick with a video", !CardScan.looksLikeCard(base.appendingPathComponent("stick")))
expectTrue("label limits", CardScan.maxLabelLength(fsType: "exfat") == 11 && CardScan.maxLabelLength(fsType: "msdos") == 11)
expectTrue("statfs of /", VolumeInfo(path: "/")?.fsType == "apfs")

// MARK: - Labroll

func expectEqual<T: Equatable>(_ name: String, _ got: T, _ expected: T) {
    if got == expected { print("ok    \(name)") } else { print("FAIL  \(name): got \(got), expected \(expected)"); failures += 1 }
}

let stamp: DateFormatter = {
    let format = DateFormatter()
    format.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return format
}()

/// Minimal MP4: ftyp, mdat, then moov/mvhd with its creation time (nil: no moov at all).
func makeMP4(_ path: String, recorded: String?, created: String = "2026-09-16 09:00:00") {
    let url = base.appendingPathComponent(path)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
    var bytes: [UInt8] = be32(16) + Array("ftypisom".utf8) + be32(0) + be32(12) + Array("mdat".utf8) + [1, 2, 3, 4]
    if let recorded {
        let seconds = UInt32(stamp.date(from: recorded)!.timeIntervalSince1970 + 2_082_844_800)
        bytes += be32(28) + Array("moov".utf8) + be32(20) + Array("mvhd".utf8) + be32(0) + be32(seconds) + be32(seconds)
    }
    try! Data(bytes).write(to: url)
    try! fm.setAttributes([.creationDate: stamp.date(from: created)!], ofItemAtPath: url.path)
}

func names(_ urls: [URL]) -> [String] { urls.map { $0.path.replacingOccurrences(of: base.path + "/", with: "") } }

makeMP4("lab/gopro/DCIM/100GOPRO/GX010002.MP4", recorded: "2026-11-02 10:05:00")
makeMP4("lab/gopro/DCIM/100GOPRO/GX020001.MP4", recorded: "2026-11-02 10:02:00")
makeMP4("lab/gopro/DCIM/100GOPRO/GX010001.MP4", recorded: "2026-11-02 10:00:00")
makeMP4("lab/gopro/DCIM/100GOPRO/GH020003.MP4", recorded: "2026-11-02 11:00:00")
makeMP4("lab/gopro/DCIM/100GOPRO/GH010003.MP4", recorded: "2026-11-02 11:00:00")
makeMP4("lab/gopro/DCIM/100GOPRO/._GX010001.MP4", recorded: nil)
make("lab/gopro/DCIM/100GOPRO/GX010009.MP4")   // empty file, skipped
make("lab/gopro/DCIM/100GOPRO/GX010001.LRF", text: "x")
expectEqual("GoPro clips in shooting order, chapters kept together",
            names(Labroll.clips(in: [base.appendingPathComponent("lab/gopro")], ignoreMXF: true)),
            ["GX010001.MP4", "GX020001.MP4", "GX010002.MP4", "GH010003.MP4", "GH020003.MP4"]
                .map { "lab/gopro/DCIM/100GOPRO/\($0)" })

makeMP4("lab/dji/DJI_0002.MP4", recorded: nil, created: "2026-11-02 09:00:00")
makeMP4("lab/dji/DJI_0001.MP4", recorded: nil, created: "2026-11-02 10:00:00")
makeMP4("lab/dji/sub/DJI_0003.MOV", recorded: "2026-11-01 08:00:00")
make("lab/dji/A001C001_x.MXF", text: "mxf")
expectEqual("no header date: file creation date, subfolders after the files",
            names(Labroll.clips(in: [base.appendingPathComponent("lab/dji")], ignoreMXF: true)),
            ["lab/dji/DJI_0002.MP4", "lab/dji/DJI_0001.MP4", "lab/dji/sub/DJI_0003.MOV"])
expectTrue("MXF kept when not ignored",
           Labroll.clips(in: [base.appendingPathComponent("lab/dji")], ignoreMXF: false).count == 4)
expectEqual("loose files sorted too",
            names(Labroll.clips(in: [base.appendingPathComponent("lab/dji/DJI_0001.MP4"),
                                     base.appendingPathComponent("lab/dji/DJI_0002.MP4")], ignoreMXF: true)),
            ["lab/dji/DJI_0002.MP4", "lab/dji/DJI_0001.MP4"])
expectEqual("mvhd date", Labroll.movieHeaderDate(base.appendingPathComponent("lab/dji/sub/DJI_0003.MOV")),
            stamp.date(from: "2026-11-01 08:00:00"))

let day = stamp.date(from: "2026-11-02 12:00:00")!
expectEqual("clip name", Labroll.clipName(labroll: "A001", index: 7, date: day, camID: "GOPRO", extension: "MP4"),
            "A001C007_20261102_GOPRO.MP4")
expectEqual("clip name without cam ID", Labroll.clipName(labroll: " A001 ", index: 12, date: day, camID: " ", extension: "mov"),
            "A001C012_20261102.mov")
expectEqual("next labroll", [Labroll.next("A001"), Labroll.next("B099"), Labroll.next("A999"), Labroll.next("DAY")],
            ["A002", "B100", "A1000", "DAY"])
expectEqual("card name, APFS", Labroll.cardName(labroll: "A001", camera: "GOPRO", date: day, maxLength: 27), "A001_20261102_GOPRO")
expectEqual("card name, 15 characters", Labroll.cardName(labroll: "A001", camera: "GOPRO", date: day, maxLength: 15), "A001_GOPRO")
expectEqual("card name, 15 characters DJI", Labroll.cardName(labroll: "A001", camera: "DJI", date: day, maxLength: 15), "A001_261102_DJI")
expectEqual("card name, FAT32 DJI", Labroll.cardName(labroll: "A001", camera: "DJI", date: day, maxLength: 11), "A001_DJI")
expectEqual("card name, long camera", Labroll.cardName(labroll: "a001", camera: "very long camera", date: day, maxLength: 11), "A001")
expectEqual("card name, long labroll", Labroll.cardName(labroll: "LONGLABROLL001", camera: "X", date: day, maxLength: 11), "LONGLABROLL")

// Custom name schemes
let values = NameScheme.Values(labroll: "A001", clip: 7, date: day, cam: "GOPRO", name: "GX010001", random: "X7K2R9P4")
expectEqual("scheme: date formats and digits",
            NameScheme(template: "{date:YYMMDD}-{labroll}C{clip:4}").clipName(values, extension: "MP4"), "261102-A001C0007.MP4")
expectEqual("scheme: every date format",
            NameScheme.dateFormats.map { NameScheme.date(day, format: $0) },
            ["20261102", "261102", "2026-11-02", "021126", "02112026", "110226"])
expectEqual("scheme: original name and random",
            NameScheme(template: "{name}_{labroll}_{random:3}").clipName(values, extension: "MP4"), "GX010001_A001_X7K.MP4")
expectEqual("scheme: empty token takes its separator",
            NameScheme(template: "{cam}_{labroll}_{cam}_{clip:2}").clipName(.init(labroll: "A001", clip: 3), extension: ""), "A001_03")
expectEqual("scheme: unknown token kept", NameScheme(template: "{labroll}{came}").unknownTokens, ["{came}"])
expectEqual("scheme: unclosed brace kept once",
            NameScheme(template: "{labroll}_{cam").tokens, [.field("labroll", param: nil), .literal("_"), .literal("{cam")])
expectEqual("scheme: no slash in clip names",
            NameScheme(template: "{labroll}/{cam}:x").clipName(values, extension: "MP4"), "A001-GOPRO-x.MP4")
expectEqual("scheme: empty template falls back",
            NameScheme(template: "").clipName(values, extension: "MP4"), "A001C007_20261102_GOPRO.MP4")
let cardScheme = NameScheme(template: "{labroll}_{date:YYYYMMDD}_{cam}_{random:4}")
expectEqual("scheme: card keeps random, 15 characters", cardScheme.cardName(values, maxLength: 15), "A001_GOPRO_X7K2")
expectEqual("scheme: card keeps random, 11 characters", cardScheme.cardName(values, maxLength: 11), "A001_X7K2")
expectEqual("scheme: reel card, default scheme",
            NameScheme.cardDefault.cardName(.init(labroll: "D902", date: day), maxLength: 11), "D902_261102")
expectEqual("scheme: reel card, {labroll} alone", NameScheme(template: "{labroll}").cardName(.init(labroll: "D902", date: day), maxLength: 11), "D902")
expectEqual("scheme: card ISO date", NameScheme(template: "{date:YYYY-MM-DD}_{labroll}").cardName(values, maxLength: 27), "2026-11-02_A001")
expectTrue("scheme: random characters", NameScheme.randomCharacters().count == 8
           && NameScheme.randomCharacters(100).allSatisfy { !"01OI".contains($0) })

// Reference values from Python's xxhash (the library Labroll Utility uses).
let digits = Array("0123456789".utf8)
let vectors: [([UInt8], String)] = [
    ([], "ef46db3751d8e999"),
    (Array("a".utf8), "d24ec4f1a98c6e5b"),
    (Array("abc".utf8), "44bc2cf5ad770999"),
    (digits + digits + digits + [48], "8b80da128591b789"),
    (digits + digits + digits + [48, 49], "e5cc9f411ea110ba"),
    (Array(repeating: Array(0...255).map(UInt8.init), count: 4).flatMap { $0 } + Array("xyz".utf8), "e146cb31b65bc21a"),
]
for (bytes, hex) in vectors {
    expectEqual("xxHash64 of \(bytes.count) bytes", XXHash64.hex(Data(bytes)), hex)
    var streamed = XXHash64()
    var offset = 0
    for size in [1, 5, 31, 7, 64, 3] where offset < bytes.count {
        let end = min(bytes.count, offset + size)
        streamed.update(Data(bytes[offset..<end]))
        offset = end
    }
    if offset < bytes.count { streamed.update(Data(bytes[offset...])) }
    expectEqual("xxHash64 streamed, \(bytes.count) bytes", streamed.hexDigest(), hex)
}

let copySource = base.appendingPathComponent("lab/copy/GX010001.MP4")
try! fm.createDirectory(at: copySource.deletingLastPathComponent(), withIntermediateDirectories: true)
let payload = Data((0..<(3 << 20) + 17).map { UInt8(truncatingIfNeeded: $0 &* 31) })
try! payload.write(to: copySource)
let copyTarget = base.appendingPathComponent("lab/copy/out/A001C001_20261102.MP4")
try! fm.createDirectory(at: copyTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
var copied = 0
let copyHash = try? Labroll.copyVerified(copySource, to: copyTarget, progress: { copied += $0 }, cancelled: { false })
expectEqual("verified copy hash", copyHash, XXHash64.hex(payload))
expectTrue("copy identical, progress complete", (try? Data(contentsOf: copyTarget)) == payload && copied == payload.count)
expectTrue("copy never overwrites", (try? Labroll.copyVerified(copySource, to: copyTarget, progress: { _ in }, cancelled: { false })) == nil)
let cancelledTarget = base.appendingPathComponent("lab/copy/out/cancelled.MP4")
_ = try? Labroll.copyVerified(copySource, to: cancelledTarget, progress: { _ in }, cancelled: { true })
expectTrue("cancelled copy removed", !fm.fileExists(atPath: cancelledTarget.path))
let renamed = try? Labroll.renameInPlace(copySource, to: "A001C001_20261102_GOPRO.MP4")
expectTrue("rename in place", renamed?.lastPathComponent == "A001C001_20261102_GOPRO.MP4" && !fm.fileExists(atPath: copySource.path))
expectTrue("rename never overwrites", (try? Labroll.renameInPlace(renamed!, to: "out")) == nil)

// Update check: version order and the GitHub "latest release" answer.
expectTrue("1.10 is newer than 1.9", Updater.isNewer("1.10", than: "1.9"))
expectTrue("1.7.1 is newer than 1.7", Updater.isNewer("1.7.1", than: "1.7"))
expectTrue("1.7 is not newer than 1.7.0", !Updater.isNewer("1.7", than: "1.7.0"))
expectTrue("1.6 is not newer than 1.7", !Updater.isNewer("1.6", than: "1.7"))
let releaseJSON = #"{"tag_name":"v1.8","html_url":"https://github.com/x/y/releases/tag/v1.8","assets":[{"name":"notes.txt","browser_download_url":"https://e/notes.txt"},{"name":"CardRename.dmg","browser_download_url":"https://e/CardRename.dmg"}]}"#
expectEqual("release: version without v, DMG link", Updater.parse(Data(releaseJSON.utf8)),
            Updater.Release(version: "1.8", download: URL(string: "https://e/CardRename.dmg")!))
expectEqual("release without DMG: its page", Updater.parse(Data(#"{"tag_name":"1.9","html_url":"https://p"}"#.utf8))?.download,
            URL(string: "https://p"))
expectTrue("not a release: nil", Updater.parse(Data(#"{"message":"Not Found"}"#.utf8)) == nil)

try? fm.removeItem(at: base)
print(failures == 0 ? "\nAll tests passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
