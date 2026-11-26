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
      --surface S         intensity (smooth, default) | mask (blocky, legacy)
      --profile           print segmented cross-section area per 10 mm of height
  mritool histogram <dicom-dir> [--series N] [--smooth-mm S] [--bins B]
      Aggregate intensity histogram + automatic thresholds.
  mritool nifti <dicom-dir> <out.nii> [--series N]
      Export a series as NIfTI-1 (e.g. as FastSurfer input; see scripts/fastsurfer-segment.sh).
  mritool kit <dicom-dir> <labels.mgz|.nii> <out-dir> [options]
      Multi-part print kit from a FastSurfer label map: 8 lobes, cerebellum, brainstem,
      head shell split horizontally (brain nests inside) and eyeballs. All parts share one frame.
      --deep              deep structures as extra pieces   --no-head  --no-eyes
      --clearance MM      brain-to-cavity gap (default 1.0) --gap MM   part-to-part gap (0.2)
      --split MM          head cut height (patient S mm; default: brain's widest level)
      --min-wall MM       thicken the head where thinner than this around the cavity (2.0)
      --verbose           log eye-search candidates
  mritool face-check <dicom-dir>
      Per series: how far forward the head reaches per height (is the face/eyes present?).
  mritool check-stl <file.stl>
      Watertightness / size / volume report for an STL.
  mritool phantom <out-dir> [--plane axial|coronal|sagittal|oblique] [--sharp]
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
        if a.hasPrefix("--") { skip = !["--keep-cavities", "--profile", "--load", "--deep", "--no-head", "--no-eyes", "--verbose"].contains(a); continue }
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
    if let sf = option("--surface") { guard let v = SurfaceSource(rawValue: sf) else { fail("unknown surface \(sf)") }; o.surface = v }
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

case "nifti":
    // Export the chosen series as NIfTI-1 (float32, RAS affine) for external segmentation tools.
    guard let dir = positional(0), let out = positional(1) else { fail(usage) }
    let (i, s) = pickSeries(scanSeries(dir))
    do {
        let v = try VolumeLoader.load(s)
        try NIfTI.write(v, to: URL(fileURLWithPath: out))
        print("series \(i): wrote \(v.nx)x\(v.ny)x\(v.nz) NIfTI")
    } catch { fail("\(error)") }

case "phantom-labels":
    // Synthetic FreeSurfer-style label map for a phantom folder (stands in for FastSurfer in tests/demos).
    guard let dir = positional(0), let out = positional(1) else { fail(usage) }
    let (_, s) = pickSeries(scanSeries(dir))
    do {
        let v = try VolumeLoader.load(s)
        var lab = [Float](repeating: 0, count: v.count)
        for z in 0 ..< v.nz { for y in 0 ..< v.ny { for x in 0 ..< v.nx {
            lab[v.index(x, y, z)] = Float(Phantom.label(v.patient(SIMD3(Double(x), Double(y), Double(z)))))
        } } }
        try NIfTI.write(v.copy(with: lab), to: URL(fileURLWithPath: out))
        print("wrote phantom label map")
    } catch { fail("\(error)") }

case "kit":
    guard let dir = positional(0), let labelsPath = positional(1), let out = positional(2) else { fail(usage) }
    let (i, s) = pickSeries(scanSeries(dir))
    var o = KitOptions()
    if flag("--deep") { o.deepStructures = true }
    if flag("--no-head") { o.head = false }
    if flag("--no-eyes") { o.eyes = false }
    if let c = option("--clearance") { o.cavityClearanceMM = Float(c) ?? o.cavityClearanceMM }
    if let c = option("--gap") { o.partGapMM = Float(c) ?? o.partGapMM }
    if let c = option("--split") { o.headSplitMM = Double(c) }
    if let t = option("--threshold") { o.threshold = Float(t) }
    if let tb = option("--taubin") { o.taubinIterations = Int(tb) ?? o.taubinIterations }
    if let w = option("--min-wall") { o.minWallMM = Float(w) ?? o.minWallMM }
    if flag("--verbose") { o.verbose = true }
    do {
        let v = try VolumeLoader.load(s)
        let lv = try LabelVolume.read(URL(fileURLWithPath: labelsPath))
        let labels = lv.resampled(onto: v)
        print("series \(i): labels \(lv.dims) resampled; \(Set(labels).count) distinct labels")
        let r = PrintKit.build(v, labels: labels, options: o, progress: { print("  " + $0) })
        let outURL = URL(fileURLWithPath: out)
        try KitExport.write(r, to: outURL)
        print("wrote \(r.parts.count) STL parts + kit.txt")
        let bad = r.parts.filter { !$0.report.isWatertight }
        if !bad.isEmpty { print("WARN not watertight: \(bad.map(\.name))") }
    } catch { fail("\(error)") }

case "label-check":
    // Alignment check between a label map and this scan: overlap and centroid/extent of the brain
    // from the labels vs the intensity-based brain mask (numbers only).
    guard let dir = positional(0), let labelsPath = positional(1) else { fail(usage) }
    let (_, s) = pickSeries(scanSeries(dir))
    do {
        let v = try VolumeLoader.load(s)
        let g = Grid(v)
        let lv = try LabelVolume.read(URL(fileURLWithPath: labelsPath))
        let a = lv.resampled(onto: v).map { Anatomy.isBrain($0) ? UInt8(1) : 0 }
        let r = ModelBuilder.build(v, options: ModelOptions())
        guard let b = r.mask else { fail("no auto mask") }
        func stats(_ m: [UInt8]) -> (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>, Double) {
            var c = SIMD3<Double>.zero, lo = SIMD3<Double>(repeating: 1e9), hi = -lo, n = 0.0
            for z in Swift.stride(from: 0, to: v.nz, by: 2) { for y in Swift.stride(from: 0, to: v.ny, by: 2) { for x in Swift.stride(from: 0, to: v.nx, by: 2) where m[v.index(x, y, z)] != 0 {
                let p = v.patient(SIMD3(Double(x), Double(y), Double(z)))
                c += p; lo = simd_min(lo, p); hi = simd_max(hi, p); n += 1
            } } }
            return (c / max(1, n), lo, hi, Double(Filters.count(m)) * g.voxelVolume / 1000)
        }
        let sa = stats(a), sb = stats(b)
        let inter = Filters.count(Filters.and(a, b))
        let dice = 2 * Double(inter) / Double(Filters.count(a) + Filters.count(b))
        print(String(format: "labels brain: %.0f mL centroid LPS (%.1f, %.1f, %.1f) x %.0f..%.0f y %.0f..%.0f z %.0f..%.0f", sa.3, sa.0.x, sa.0.y, sa.0.z, sa.1.x, sa.2.x, sa.1.y, sa.2.y, sa.1.z, sa.2.z))
        print(String(format: "auto brain:   %.0f mL centroid LPS (%.1f, %.1f, %.1f) x %.0f..%.0f y %.0f..%.0f z %.0f..%.0f", sb.3, sb.0.x, sb.0.y, sb.0.z, sb.1.x, sb.2.x, sb.1.y, sb.2.y, sb.1.z, sb.2.z))
        print(String(format: "dice %.3f", dice))
        // Anatomical direction sanity: lobe centroids in patient LPS (anterior = −y, left = +x, superior = +z).
        let lab = lv.resampled(onto: v)
        for (name, ids) in [("frontal", Anatomy.frontal), ("occipital", Anatomy.occipital), ("temporal", Anatomy.temporal)] {
            for (side, base) in [("L", 1000), ("R", 2000)] {
                var c = SIMD3<Double>.zero, n = 0.0
                for z in Swift.stride(from: 0, to: v.nz, by: 2) { for y in Swift.stride(from: 0, to: v.ny, by: 2) { for x in Swift.stride(from: 0, to: v.nx, by: 2) {
                    let l = Int(lab[v.index(x, y, z)])
                    if l > base && l < base + 100 && ids.contains(l - base) { c += v.patient(SIMD3(Double(x), Double(y), Double(z))); n += 1 }
                } } }
                print(String(format: "%@ %@ centroid LPS (%.0f, %.0f, %.0f)", side, name, c.x / n, c.y / n, c.z / n))
            }
        }
        let la = lv.affine
        print(String(format: "label affine cols: (%.2f %.2f %.2f) (%.2f %.2f %.2f) (%.2f %.2f %.2f) origin (%.1f %.1f %.1f) dims %@",
                     la.columns.0.x, la.columns.0.y, la.columns.0.z, la.columns.1.x, la.columns.1.y, la.columns.1.z,
                     la.columns.2.x, la.columns.2.y, la.columns.2.z, la.columns.3.x, la.columns.3.y, la.columns.3.z, "\(lv.dims)"))
        let va = NIfTI.rasAffine(v)
        print(String(format: "scan affine cols:  (%.2f %.2f %.2f) (%.2f %.2f %.2f) (%.2f %.2f %.2f) origin (%.1f %.1f %.1f)",
                     va.columns.0.x, va.columns.0.y, va.columns.0.z, va.columns.1.x, va.columns.1.y, va.columns.1.z,
                     va.columns.2.x, va.columns.2.y, va.columns.2.z, va.columns.3.x, va.columns.3.y, va.columns.3.z))
    } catch { fail("\(error)") }

case "face-check":
    // For every series: how far forward (patient anterior) the head reaches per 10 mm height band.
    // Shows whether the face is inside the field of view (or was removed by defacing). Numbers only.
    guard let dir = positional(0) else { fail(usage) }
    let all = scanSeries(dir)
    for (i, s) in all.enumerated() {
        guard let v = try? VolumeLoader.load(s) else { continue }
        let g = Grid(v)
        let sm = Filters.gaussian(v.data, g, sigmaMM: 1)
        let t = ModelBuilder.airTissueThreshold(sm)
        let m = Filters.largestComponent(Filters.threshold(sm, t), g)
        var front: [Int: Double] = [:]
        for z in 0 ..< v.nz { for y in 0 ..< v.ny { for x in 0 ..< v.nx where m[v.index(x, y, z)] != 0 {
            let p = v.patient(SIMD3(Double(x), Double(y), Double(z)))
            let k = Int(floor(p.z / 10))
            front[k] = min(front[k] ?? 1e9, p.y)
        } } }
        let c0 = v.patient(.zero), c1 = v.patient(SIMD3(Double(v.nx - 1), Double(v.ny - 1), Double(v.nz - 1)))
        let bands = front.keys.sorted().map { "\($0 * 10):\(Int(front[$0]!))" }.joined(separator: " ")
        print("series \(i) [\(s.acquisitionPlane) \(s.description)] FOV y \(Int(min(c0.y, c1.y)))..\(Int(max(c0.y, c1.y))) z \(Int(min(c0.z, c1.z)))..\(Int(max(c0.z, c1.z)))")
        print("   anterior-most head y per height band (z:y): \(bands)")
    }

case "extent-check":
    // Tissue (above air/tissue threshold) voxel counts by distance in front of / behind the brain's
    // anterior-most / posterior-most extent, plus the true FOV (all 8 corners). Numbers only.
    guard let dir = positional(0), let labelsPath = positional(1) else { fail(usage) }
    let (_, s) = pickSeries(scanSeries(dir))
    do {
        let v = try VolumeLoader.load(s)
        let g = Grid(v)
        let sm = Filters.gaussian(v.data, g, sigmaMM: 1)
        let t = ModelBuilder.airTissueThreshold(sm)
        let lab = try LabelVolume.read(URL(fileURLWithPath: labelsPath)).resampled(onto: v)
        var lo = SIMD3<Double>(repeating: 1e9), hi = -lo
        for cx in [0, v.nx - 1] { for cy in [0, v.ny - 1] { for cz in [0, v.nz - 1] {
            let p = v.patient(SIMD3(Double(cx), Double(cy), Double(cz))); lo = simd_min(lo, p); hi = simd_max(hi, p)
        } } }
        print(String(format: "FOV LPS (8 corners): x %.0f..%.0f y %.0f..%.0f z %.0f..%.0f", lo.x, hi.x, lo.y, hi.y, lo.z, hi.z))
        var yF = 1e9, yB = -1e9
        for i in 0 ..< v.count where Anatomy.isBrain(lab[i]) {
            let z = i / (v.nx * v.ny), y = (i / v.nx) % v.ny, x = i % v.nx
            let p = v.patient(SIMD3(Double(x), Double(y), Double(z)))
            yF = min(yF, p.y); yB = max(yB, p.y)
        }
        print(String(format: "brain y %.0f..%.0f; auto tissue threshold %.0f", yF, yB, t))
        for tt in [Float(10), 15, 20, 30, 40, t] {
            var front = [Int](repeating: 0, count: 6)
            for z in 0 ..< v.nz { for y in 0 ..< v.ny { for x in 0 ..< v.nx where sm[v.index(x, y, z)] >= tt {
                let p = v.patient(SIMD3(Double(x), Double(y), Double(z)))
                if p.y < yF { front[min(5, Int((yF - p.y) / 10))] += 1 }
            } } }
            print(String(format: "threshold %3.0f: voxels in front of brain per 10 mm: ", tt) + "\(front)")
        }
    } catch { fail("\(error)") }

case "kit-check":
    // Fit checks on an exported kit folder: non-head parts must not intersect head material, and each
    // eye's socket must open to the front (STL frame is RAS, anterior = +y).
    guard let dir = positional(0) else { fail(usage) }
    do {
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".stl") }.sorted()
        let load = { (f: String) in try STL.read(URL(fileURLWithPath: dir).appendingPathComponent(f)) }
        let head = try files.filter { $0.contains("head") }.map(load)
        for f in files where !f.contains("head") {
            let m = try load(f)
            let sample = Swift.stride(from: 0, to: m.vertices.count, by: max(1, m.vertices.count / 300)).map { m.vertices[$0] }
            let inside = sample.filter { p in head.contains { MeshOps.contains($0, p) } }.count
            var line = "\(f): \(inside)/\(sample.count) sampled vertices inside head material"
            if f.contains("eye"), let b = MeshOps.bounds(m) {
                let c = (b.min + b.max) / 2
                let hits = head.map { MeshOps.rayHits($0, from: c, dir: SIMD3(0.0003, 1, 0.0002)) }.reduce(0, +)
                line += ", head surfaces in front of the eye: \(hits)"
            }
            print(line)
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
        let n = try Phantom.write(to: URL(fileURLWithPath: out), plane: plane, partialVolume: !flag("--sharp"))
        print("wrote synthetic phantom: \(n) slices, \(plane.rawValue) acquisition")
    } catch {
        fail("phantom failed: \(error)")
    }

default:
    print(usage)
    exit(command == "help" || command == "--help" ? 0 : 1)
}
