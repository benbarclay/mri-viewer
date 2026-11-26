import Foundation
import MRICore
import simd

setvbuf(stdout, nil, _IOLBF, 0)

// Privacy rule for this tool: it prints only technical acquisition parameters and aggregate
// numbers. It never prints patient/study identifiers, dates, UIDs, file paths inside the
// data folder, or pixel values.

let usage = """
mritool — inspect DICOM MRI folders and export 3D-printable meshes.

USAGE
  mritool info <dicom-dir>
      List series (technical parameters only) and volume statistics.
  mritool stl <dicom-dir> <out.stl> [options]
      Build a surface mesh and write a binary STL.
      --series N          series index from `info` (default: largest volumetric series)
      --mode M            brain | head | iso   (default: brain)
      --threshold T       intensity threshold (default: automatic)
      --erode MM          brain mode: erosion radius used to detach the brain (default 4)
      --smooth-mm S       Gaussian pre-smoothing sigma in mm (default 1.0)
      --taubin N          Taubin mesh smoothing iterations (default 10)
      --downsample F      integer voxel downsample factor (default 1)
      --keep-cavities     do not fill internal cavities (iso mode keeps them by default)
      --trim-tail F       brain mode: cut the cord where cross-section < F × max (default 0.05, 0 = off)
      --profile           print segmented cross-section area per 10 mm of height
  mritool histogram <dicom-dir> [--series N] [--smooth-mm S] [--bins B]
      Aggregate intensity histogram + automatic thresholds.
  mritool check-stl <file.stl>
      Watertightness / size / volume report for an STL.
  mritool phantom <out-dir> [--plane axial|coronal|sagittal|oblique]
      Write a synthetic (non-patient) DICOM head phantom for testing and screenshots.
  mritool verify-decode <dicom-dir> <out-dir>
      Decode every slice of the chosen series and write raw little-endian uint16 planes
      (one file per slice) to <out-dir> for comparison with an independent decoder.
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }
func positional(_ i: Int) -> String? {
    var out: [String] = []
    var skip = false
    for a in args {
        if skip { skip = false; continue }
        if a.hasPrefix("--") { skip = !["--keep-cavities", "--profile", "--load"].contains(a); continue }
        out.append(a)
    }
    return i < out.count ? out[i] : nil
}

func scanSeries(_ dir: String) -> [SeriesInfo] {
    let url = URL(fileURLWithPath: dir)
    do {
        return try SeriesScanner.scan(directory: url)
    } catch {
        fail("scan failed: \(error)")
    }
}

func pickSeries(_ all: [SeriesInfo]) -> (Int, SeriesInfo) {
    if let s = option("--series"), let n = Int(s) {
        guard all.indices.contains(n) else { fail("series index \(n) out of range 0..<\(all.count)") }
        return (n, all[n])
    }
    guard let best = all.indices.max(by: { all[$0].rows * all[$0].columns * all[$0].slices.count < all[$1].rows * all[$1].columns * all[$1].slices.count }) else {
        fail("no image series found")
    }
    return (best, all[best])
}

func fmt(_ d: Double, _ p: Int = 2) -> String { String(format: "%.\(p)f", d) }

switch command {
case "info":
    guard let dir = positional(0) else { fail(usage) }
    let t0 = Date()
    let all = scanSeries(dir)
    print("found \(all.count) image stack(s) in \(fmt(Date().timeIntervalSince(t0), 1)) s")
    print("idx  ser  mod  plane     size        slices  pixel(mm)     thick  transfer-syntax            description")
    for (i, s) in all.enumerated() {
        let line = [
            String(i).padding(toLength: 4, withPad: " ", startingAt: 0),
            String(s.seriesNumber).padding(toLength: 4, withPad: " ", startingAt: 0),
            s.modality.padding(toLength: 4, withPad: " ", startingAt: 0),
            s.acquisitionPlane.padding(toLength: 9, withPad: " ", startingAt: 0),
            "\(s.columns)x\(s.rows)".padding(toLength: 11, withPad: " ", startingAt: 0),
            String(s.slices.count).padding(toLength: 7, withPad: " ", startingAt: 0),
            "\(fmt(s.pixelSpacing.y))x\(fmt(s.pixelSpacing.x))".padding(toLength: 13, withPad: " ", startingAt: 0),
            (s.sliceThickness.map { fmt($0) } ?? "-").padding(toLength: 6, withPad: " ", startingAt: 0),
            s.transferSyntax.padding(toLength: 26, withPad: " ", startingAt: 0),
            s.description,
        ].joined(separator: " ")
        print(line)
    }
    if flag("--load") || option("--series") != nil {
        let (i, s) = pickSeries(all)
        let t1 = Date()
        do {
            let v = try VolumeLoader.load(s)
            let st = v.stats()
            let p = v.percentiles([1, 50, 99])
            print("series \(i): volume \(v.nx)x\(v.ny)x\(v.nz) voxels, spacing \(fmt(v.spacing.x, 3))x\(fmt(v.spacing.y, 3))x\(fmt(v.spacing.z, 3)) mm, loaded in \(fmt(Date().timeIntervalSince(t1), 2)) s")
            print("  extent \(fmt(Double(v.nx) * v.spacing.x, 1)) x \(fmt(Double(v.ny) * v.spacing.y, 1)) x \(fmt(Double(v.nz) * v.spacing.z, 1)) mm; handedness \(v.handedness)")
            print("  intensity min \(st.min) max \(st.max) mean \(fmt(st.mean, 1)); p1 \(p[0]) p50 \(p[1]) p99 \(p[2])")
            for w in v.warnings { print("  WARN \(w)") }
        } catch {
            fail("load failed: \(error)")
        }
    }

case "verify-decode":
    guard let dir = positional(0), let out = positional(1) else { fail(usage) }
    let all = scanSeries(dir)
    let (i, s) = pickSeries(all)
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    var manifest = ""
    for (k, sl) in s.slices.enumerated() {
        do {
            let f = try DICOMFile(url: sl.url)
            guard let px = try PixelDecoder.decodeFrames(f).first else { fail("no frame") }
            var raw = Data(capacity: px.count * 2)
            for v in px { var u = UInt16(clamping: Int(v)).littleEndian; withUnsafeBytes(of: &u) { raw.append(contentsOf: $0) } }
            let name = String(format: "%04d.u16", k)
            try raw.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
            manifest += "\(name)\t\(sl.url.path)\n"
        } catch {
            fail("slice \(k): \(error)")
        }
    }
    try? manifest.write(toFile: out + "/manifest.tsv", atomically: true, encoding: .utf8)
    print("series \(i): wrote \(s.slices.count) planes of \(s.columns)x\(s.rows) to out dir")

case "stl":
    guard let dir = positional(0), let out = positional(1) else { fail(usage) }
    let all = scanSeries(dir)
    let (i, s) = pickSeries(all)
    var o = ModelOptions()
    if let m = option("--mode") { guard let mm = ModelMode(rawValue: m) else { fail("unknown mode \(m)") }; o.mode = mm }
    if let t = option("--threshold") { o.threshold = Float(t) }
    if let e = option("--erode") { o.erodeMM = Double(e) ?? o.erodeMM }
    if let sm = option("--smooth-mm") { o.smoothMM = Double(sm) ?? o.smoothMM }
    if let tb = option("--taubin") { o.taubinIterations = Int(tb) ?? o.taubinIterations }
    if let d = option("--downsample") { o.downsample = Int(d) ?? 1 }
    if flag("--keep-cavities") { o.fillCavities = false }
    if let tr = option("--trim-tail") { o.trimTailFraction = Double(tr) ?? o.trimTailFraction }
    print("series \(i) (\(s.columns)x\(s.rows)x\(s.slices.count)), mode \(o.mode.rawValue)")
    do {
        let v = try VolumeLoader.load(s)
        let r = ModelBuilder.build(v, options: o, progress: { print("  " + $0) })
        if let ml = r.maskVolumeML { print("segmented volume: \(fmt(ml, 0)) mL") }
        if flag("--profile"), let m = r.mask {
            // Segmented cross-section area per 10 mm of patient height (aggregate numbers only).
            let vv = r.volume
            var area: [Int: Double] = [:]
            for z in 0 ..< vv.nz { for y in 0 ..< vv.ny { for x in 0 ..< vv.nx where m[vv.index(x, y, z)] != 0 {
                let p = vv.patient(SIMD3(Double(x), Double(y), Double(z)))
                area[Int(floor(p.z / 10)), default: 0] += vv.voxelVolumeMM3 / 10 / 100 // cm² averaged over the 10 mm band
            } } }
            print("height band (mm, patient S)   mean cross-section (cm²)")
            for k in area.keys.sorted(by: >) { print(String(format: "  %5d..%5d   %6.1f", k * 10, k * 10 + 10, area[k]!)) }
        }
        print(r.report)
        try STL.write(r.mesh, to: URL(fileURLWithPath: out))
        let bytes = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
        print("wrote STL: \(fmt(Double(bytes) / 1e6, 1)) MB")
    } catch {
        fail("failed: \(error)")
    }

case "histogram":
    // Aggregate intensity histogram of the smoothed volume (counts only; no spatial information).
    guard let dir = positional(0) else { fail(usage) }
    let (_, s) = pickSeries(scanSeries(dir))
    do {
        let v = try VolumeLoader.load(s)
        let g = Grid(v)
        let sm = Filters.gaussian(v.data, g, sigmaMM: Double(option("--smooth-mm") ?? "1") ?? 1)
        let a = ModelBuilder.autoThresholds(v, smoothed: sm)
        print("auto: head \(a.head)  white-matter \(a.whiteMatter)  brain \(a.brain)  (core \(fmt(a.coreML, 0)) mL)")
        let hi = sm.max() ?? 1
        let bins = Int(option("--bins") ?? "40") ?? 40
        var h = [Int](repeating: 0, count: bins)
        for x in sm { h[min(bins - 1, Int(x / hi * Float(bins)))] += 1 }
        let peak = h.dropFirst().max() ?? 1
        for (i, c) in h.enumerated() {
            let lo = Float(i) * hi / Float(bins)
            print(String(format: "%7.0f %9d ", lo, c) + String(repeating: "#", count: min(60, c * 60 / max(1, peak))))
        }
    } catch { fail("\(error)") }

case "check-stl":
    guard let path = positional(0) else { fail(usage) }
    do {
        let m = try STL.read(URL(fileURLWithPath: path))
        print(MeshReport.analyze(m))
    } catch {
        fail("read failed: \(error)")
    }

case "phantom":
    guard let out = positional(0) else { fail(usage) }
    let plane = Phantom.Plane(rawValue: option("--plane") ?? "sagittal") ?? .sagittal
    do {
        let n = try Phantom.write(to: URL(fileURLWithPath: out), plane: plane)
        print("wrote synthetic phantom: \(n) slices, \(plane.rawValue) acquisition")
    } catch {
        fail("phantom failed: \(error)")
    }

default:
    print(usage)
    exit(command == "help" || command == "--help" ? 0 : 1)
}
