import Foundation
import simd

/// What part of the scan to turn into a printable solid.
public enum ModelMode: String, CaseIterable, Identifiable {
    /// Skull-stripped brain: threshold → erode → largest component → dilate back → fill cavities.
    case brain
    /// Outer skin surface of the head (solid).
    case head
    /// Raw iso-surface of the intensity at the threshold (no segmentation).
    case iso

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .brain: return "Brain"
        case .head: return "Head (skin)"
        case .iso: return "Iso-surface"
        }
    }
}

public struct ModelOptions: Equatable {
    public var mode: ModelMode = .brain
    /// Intensity threshold; nil = automatic (see `ModelBuilder.autoThreshold`).
    public var threshold: Float? = nil
    /// Brain mode: erosion radius (mm) used to cut thin connections between brain and scalp.
    public var erodeMM: Double = 4
    /// Gaussian pre-smoothing of the intensity (mm).
    public var smoothMM: Double = 1.0
    /// Taubin smoothing iterations on the final mesh.
    public var taubinIterations: Int = 10
    /// Integer downsampling factor (1 = full resolution).
    public var downsample: Int = 1
    /// Fill enclosed cavities (ventricles, sinuses) so the print is solid.
    public var fillCavities: Bool = true
    /// Keep only the largest connected mesh piece.
    public var largestOnly: Bool = true
    /// Brain mode: cut off the thin inferior tail (spinal cord) where the axial cross-section is below
    /// this fraction of the largest cross-section. Also gives the print a flat base. 0 disables.
    public var trimTailFraction: Double = 0.05
    public init() {}
}

public struct ModelResult {
    public var mesh: Mesh
    public var report: MeshReport
    public var threshold: Float
    /// Segmented volume before meshing (mL); nil in iso mode.
    public var maskVolumeML: Double?
    /// Binary segmentation on the (possibly downsampled) grid of `volume`; nil in iso mode.
    public var mask: [UInt8]?
    /// The volume the model was built from (after downsampling).
    public var volume: Volume
    public var log: [String]
}

public enum ModelBuilder {
    /// Fraction of the white-matter peak used as the brain/CSF boundary on T1-weighted images
    /// (typical T1 contrast: WM 1.0, GM ≈ 0.6–0.7, CSF ≈ 0.2–0.3).
    public static var brainFractionOfWM: Float = 0.45

    /// Automatic (head, brain) thresholds; see `autoThresholds`.
    public static func autoThreshold(_ v: Volume, mode: ModelMode, smoothMM: Double = 1.0) -> (head: Float, brain: Float) {
        let a = autoThresholds(v, smoothed: Filters.gaussian(v.data, Grid(v), sigmaMM: smoothMM))
        return (a.head, a.brain)
    }

    public struct AutoThresholds { public let head: Float, whiteMatter: Float, brain: Float, coreML: Double }

    /// Head: Otsu (air vs tissue). White matter: 75th percentile of intensities deep inside the head
    /// (≥ 25 mm from the skin, which in an adult head is inside the brain and dominated by white matter).
    /// Brain/CSF boundary: `brainFractionOfWM` × white matter.
    public static func autoThresholds(_ v: Volume, smoothed s: [Float]) -> AutoThresholds {
        let g = Grid(v)
        let head = Filters.otsu(s)
        let headMask = Filters.fillHoles(Filters.largestComponent(Filters.threshold(s, head), g), g)
        var core: [UInt8] = []
        for depth in [25.0, 18.0, 12.0] {
            core = Filters.erode(headMask, g, radiusMM: depth)
            if Filters.count(core) * 50 > Filters.count(headMask) { break } // need ≥ 2% of the head
        }
        var values: [Float] = []
        for i in 0 ..< g.count where core[i] != 0 { values.append(s[i]) }
        guard !values.isEmpty else { return AutoThresholds(head: head, whiteMatter: head, brain: head, coreML: 0) }
        values.sort()
        let wm = values[Int(Double(values.count - 1) * 0.75)]
        return AutoThresholds(head: head, whiteMatter: wm, brain: max(head, wm * brainFractionOfWM),
                              coreML: Double(values.count) * g.voxelVolume / 1000)
    }

    /// Binary segmentation mask for the given mode (1 = inside). Not used in iso mode.
    public static func segment(_ v: Volume, smoothed: [Float], options o: ModelOptions, threshold t: Float, log: inout [String]) -> [UInt8] {
        let g = Grid(v)
        var m = Filters.threshold(smoothed, t)
        log.append("threshold \(t): \(pct(m)) of voxels above")
        switch o.mode {
        case .head:
            // The skin is a thin shell around dark skull/CSF: seal small openings (closing), fill the
            // inside, then keep the largest piece. Without the fill the brain would win as "largest".
            if o.fillCavities {
                let r = 3.0
                m = Filters.erode(Filters.fillHoles(Filters.dilate(m, g, radiusMM: r), g), g, radiusMM: r)
                m = Filters.fillHoles(m, g)
                // Per axial slice as well: handles a head clipped by the top/bottom of the field of view.
                m = Filters.fillHoles2D(m, g, axis: AnatomicalFrame(v).voxelAxis[2])
                log.append("closed \(r) mm + filled: \(ml(m, g)) mL")
            }
            m = Filters.largestComponent(m, g)
            log.append("largest component: \(ml(m, g)) mL")
        case .brain:
            let eroded = Filters.erode(m, g, radiusMM: o.erodeMM)
            let (labels, sizes) = Filters.components(eroded, g)
            let ranked = sizes.indices.dropFirst().sorted { sizes[$0] > sizes[$1] }
            let top = ranked.prefix(3).map { String(format: "%.0f", Double(sizes[$0]) * g.voxelVolume / 1000) }
            log.append("eroded \(o.erodeMM) mm: \(sizes.count - 1) components, largest (mL): \(top.joined(separator: ", "))")
            guard let best = ranked.first else { return [UInt8](repeating: 0, count: g.count) }
            let core = labels.map { $0 == Int32(best) ? UInt8(1) : 0 }
            // Grow back by the erosion radius (+ half a voxel), but never beyond the thresholded tissue.
            let grown = Filters.dilate(core, g, radiusMM: o.erodeMM + 0.5 * min(g.sx, g.sy, g.sz))
            m = Filters.largestComponent(Filters.and(grown, m), g)
            log.append("dilated back within threshold: \(ml(m, g)) mL")
            if o.fillCavities { m = Filters.fillHoles(m, g); log.append("filled cavities: \(ml(m, g)) mL") }
            if o.trimTailFraction > 0, let cut = trimInferiorTail(&m, v, fraction: o.trimTailFraction) {
                m = Filters.largestComponent(m, g)
                log.append(String(format: "trimmed tail below S %.0f mm: %@ mL", cut, ml(m, g)))
            }
        case .iso:
            break
        }
        return m
    }

    public static func build(_ input: Volume, options o: ModelOptions, progress: ((String) -> Void)? = nil) -> ModelResult {
        var log: [String] = []
        func step(_ s: String) { log.append(s); progress?(s) }
        let t0 = Date()
        let v = Filters.downsample(input, factor: max(1, o.downsample))
        let g = Grid(v)
        step("volume \(v.nx)x\(v.ny)x\(v.nz) @ " + String(format: "%.2f mm", v.spacing.x))
        let smoothed = Filters.gaussian(v.data, g, sigmaMM: o.smoothMM)
        var t = o.threshold ?? 0
        if o.threshold == nil {
            let a = autoThresholds(v, smoothed: smoothed)
            t = o.mode == .brain ? a.brain : a.head
            step(String(format: "auto threshold %.1f (head %.1f, white matter %.1f from %.0f mL deep core)", t, a.head, a.whiteMatter, a.coreML))
        }

        let field: [Float]
        let iso: Float
        var maskML: Double?
        var finalMask: [UInt8]?
        if o.mode == .iso {
            field = smoothed
            iso = t
        } else {
            var segLog: [String] = []
            let m = segment(v, smoothed: smoothed, options: o, threshold: t, log: &segLog)
            segLog.forEach(step)
            maskML = Double(Filters.count(m)) * g.voxelVolume / 1000
            finalMask = m
            // Light blur of the binary mask gives a smooth sub-voxel surface at 0.5.
            field = Filters.gaussian(m.map { Float($0) }, g, sigmaMM: 0.6 * min(g.sx, g.sy, g.sz))
            iso = 0.5
        }
        step("extracting surface")
        var mesh = Isosurface.extract(field, g, iso: iso, toPatient: { v.patient($0) }, flipWinding: v.handedness < 0)
        step("surface: \(mesh.triangleCount) triangles")
        if o.largestOnly {
            MeshOps.keepLargestComponent(&mesh)
            step("largest piece: \(mesh.triangleCount) triangles")
        }
        MeshOps.taubinSmooth(&mesh, iterations: o.taubinIterations)
        MeshOps.lpsToPrintFrame(&mesh)
        MeshOps.placeOnBuildPlate(&mesh)
        let report = MeshReport.analyze(mesh)
        step(String(format: "done in %.1f s", Date().timeIntervalSince(t0)))
        return ModelResult(mesh: mesh, report: report, threshold: t, maskVolumeML: maskML, mask: finalMask, volume: v, log: log)
    }

    /// Removes mask voxels below the lowest 1 mm axial band whose area reaches `fraction` of the
    /// maximum band area. Returns the cut height (patient S, mm) or nil when nothing was cut.
    static func trimInferiorTail(_ m: inout [UInt8], _ v: Volume, fraction: Double) -> Double? {
        var heights = [Float](repeating: 0, count: v.count)
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for z in 0 ..< v.nz { for y in 0 ..< v.ny { for x in 0 ..< v.nx {
            let i = v.index(x, y, z)
            let h = v.patient(SIMD3(Double(x), Double(y), Double(z))).z
            heights[i] = Float(h)
            if m[i] != 0 { lo = min(lo, h); hi = max(hi, h) }
        } } }
        guard hi > lo else { return nil }
        let bands = Int(hi - lo) + 1
        var area = [Double](repeating: 0, count: bands)
        for i in 0 ..< v.count where m[i] != 0 { area[min(bands - 1, Int(Double(heights[i]) - lo))] += 1 }
        let target = (area.max() ?? 0) * fraction
        guard let first = area.firstIndex(where: { $0 >= target }), first > 0 else { return nil }
        let cut = lo + Double(first)
        for i in 0 ..< v.count where m[i] != 0 && Double(heights[i]) < cut { m[i] = 0 }
        return cut
    }

    static func pct(_ m: [UInt8]) -> String { String(format: "%.1f%%", 100 * Double(Filters.count(m)) / Double(max(1, m.count))) }
    static func ml(_ m: [UInt8], _ g: Grid) -> String { String(format: "%.0f", Double(Filters.count(m)) * g.voxelVolume / 1000) }
}
