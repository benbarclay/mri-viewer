import Foundation
import simd

public struct KitOptions: Equatable {
    /// Print deep structures (basal ganglia/thalamus, hippocampus/amygdala, ventricles) as separate pieces.
    public var deepStructures = false
    /// Include the head shell (split horizontally) that the brain nests inside.
    public var head = true
    /// Include eyeballs as separate pieces sitting in front-opening sockets of the head.
    public var eyes = true
    /// Gap between the brain and the head cavity (mm), so the pieces drop in after printing.
    public var cavityClearanceMM: Float = 1.0
    /// Minimum head wall around the cavity (mm): the outer surface is pushed out where it's thinner.
    public var minWallMM: Float = 2.0
    /// Log eye-search candidates (positions relative to the brain) for troubleshooting.
    public var verbose = false
    /// Gap between neighbouring brain parts and between the two head halves (mm).
    public var partGapMM: Float = 0.2
    /// Height (patient S, mm) of the horizontal head cut; nil = level of the brain's widest cross-section.
    public var headSplitMM: Double? = nil
    /// Gaussian smoothing of the intensity before surfacing (mm).
    public var smoothMM: Double = 1.0
    public var taubinIterations = 10
    /// Brain/CSF intensity threshold for the outer brain surface; nil = automatic.
    public var threshold: Float? = nil
    public init() {}
}

public struct KitPart {
    public let name: String
    public let group: String          // "brain", "head" or "eye"
    public let color: SIMD3<Float>
    public var mesh: Mesh
    public var report: MeshReport
}

public struct KitResult {
    public var parts: [KitPart]
    public var log: [String]
    public var splitHeightMM: Double?
    public var eyes: [EyeballEstimate]
    /// Volume where two brain parts overlap (should be ≈ 0).
    public var overlapML: Double
    /// Cavity volume that cannot be reached by a straight vertical lift (lower bowl, upper cap).
    public var undercutML: (lower: Double, upper: Double)?
}

/// Builds a multi-part, interlocking print: anatomical brain parts from a label map, a hollow head
/// split horizontally whose cavity matches the brain (+ clearance), and optional eyeballs.
///
/// Every part is the zero level set of a field built with min/max (intersection/union) of:
/// the intensity-guided brain surface, per-part signed distances from the label map, the head
/// surface, the brain cavity, eye spheres and the cut plane. All parts share one coordinate frame
/// (RAS mm), so importing every STL into a slicer shows the assembled model.
public enum PrintKit {
    public static func build(_ v: Volume, labels: [Int32], options o: KitOptions, progress: ((String) -> Void)? = nil) -> KitResult {
        precondition(labels.count == v.count)
        var log: [String] = []
        func step(_ s: String) { log.append(s); progress?(s) }
        let t0 = Date()
        let g = Grid(v)
        let s = Filters.gaussian(v.data, g, sigmaMM: o.smoothMM)
        let auto = ModelBuilder.autoThresholds(v, smoothed: s)
        let tBrain = o.threshold ?? auto.brain
        step(String(format: "thresholds: brain %.1f, head %.1f", tBrain, auto.head))

        // 1. Brain mask from the labels; fill ventricles; trim the cord.
        var brain = labels.map { Anatomy.isBrain($0) ? UInt8(1) : 0 }
        brain = Filters.fillHoles(Filters.largestComponent(brain, g), g)
        if let cut = ModelBuilder.trimInferiorTail(&brain, v, fraction: 0.05) {
            brain = Filters.largestComponent(brain, g)
            step(String(format: "brain from labels: %.0f mL (cord trimmed below S %.0f mm)", ml(brain, g), cut))
        } else {
            step(String(format: "brain from labels: %.0f mL", ml(brain, g)))
        }

        // 2. Assign every brain voxel to a part (labelled voxels directly, the rest by growing).
        let specs = Anatomy.parts(deep: o.deepStructures)
        let partOf = assignParts(labels, brain: brain, g, deep: o.deepStructures, specs: specs)
        // 3. Outer brain surface: intensity edge near the label boundary.
        let outer = Fields.guided(intensity: s, threshold: tBrain, mask: brain, g, contrast: tBrain)
        let gap = o.partGapMM

        var parts: [KitPart] = []
        var positive = [UInt8](repeating: 0, count: g.count) // overlap accounting
        var overlapVoxels = 0
        for spec in specs {
            let mask = partOf.map { $0 == Int8(spec.id) ? UInt8(1) : 0 }
            let n = Filters.count(mask)
            guard n * 2000 > Filters.count(brain) else { step("\(spec.name): too small, skipped"); continue }
            guard let crop = Crop(mask, g, margin: 6) else { continue }
            let cm = crop.extract(mask), cg = crop.grid
            let sd = Fields.smoothMaskField(cm, cg)
            let co = crop.extract(outer)
            var field = [Float](repeating: 0, count: cg.count)
            for i in 0 ..< cg.count { field[i] = min(co[i], sd[i] - gap / 2) }
            // Overlap check at voxel centres.
            crop.forEach { local, global in
                if field[local] > 0 { if positive[global] != 0 { overlapVoxels += 1 } else { positive[global] = 1 } }
            }
            var mesh = surface(field, cg, crop: crop, v, keepFraction: o.deepStructures && spec.id == 15 ? 0.02 : 0.05, taubin: o.taubinIterations)
            let r = MeshReport.analyze(mesh)
            MeshOps.removeDegenerate(&mesh)
            parts.append(KitPart(name: spec.name, group: "brain", color: spec.color, mesh: mesh, report: r))
            step(String(format: "%@: %.0f mL, %d triangles, watertight %@", spec.name, r.volumeMM3 / 1000, r.triangles, r.isWatertight ? "yes" : "NO"))
        }
        let overlapML = Double(overlapVoxels) * g.voxelVolume / 1000
        step(String(format: "brain parts overlap: %.2f mL", overlapML))

        var eyes: [EyeballEstimate] = []
        var split: Double?
        var undercut: (Double, Double)?
        if o.head {
            // 4. Head: solid skin surface minus the brain cavity (+ eye sockets), cut horizontally.
            var hlog: [String] = []
            var ho = ModelOptions(); ho.mode = .head
            let headMask = ModelBuilder.segment(v, smoothed: s, options: ho, threshold: auto.head, log: &hlog)
            let headField = Fields.guided(intensity: s, threshold: auto.head, mask: headMask, g, contrast: auto.head, maskBlurMM: 1.5)
            step(String(format: "head: %.0f mL", ml(headMask, g)))
            let solid = outer.map { $0 > 0 ? UInt8(1) : 0 }
            let cavity = Fields.offset(Fields.smoothMaskField(solid, g), by: o.cavityClearanceMM + Float(0.5 * min(g.sx, g.sy, g.sz)))

            var shell = [Float](repeating: 0, count: g.count)
            var thickened = 0
            for i in 0 ..< g.count {
                // Outer surface = skin, pushed outward where it would leave less than minWall around the cavity.
                let outerSkin = max(headField[i], cavity[i] + o.minWallMM)
                if headField[i] <= 0 && outerSkin > 0 { thickened += 1 }
                shell[i] = min(outerSkin, -cavity[i])
            }
            step(String(format: "head wall thickened to ≥ %.1f mm: %.1f mL added", o.minWallMM, Double(thickened) * g.voxelVolume / 1000))

            if o.eyes {
                var elog: [String] = []
                eyes = EyeFinder.find(v, smoothed: s, head: headMask, brain: brain, darkThreshold: tBrain, verbose: o.verbose, log: &elog)
                elog.forEach(step)
                if eyes.count == 2 {
                    let anterior = SIMD3<Double>(0, -1, 0) // LPS
                    let clr = Double(o.cavityClearanceMM) * 0.5 + 0.3 // eyes need less play than the brain
                    for z in 0 ..< v.nz { for y in 0 ..< v.ny { for x in 0 ..< v.nx {
                        let p = v.patient(SIMD3(Double(x), Double(y), Double(z)))
                        var socket = -Double.greatestFiniteMagnitude
                        for e in eyes {
                            let d = p - e.center
                            let sphere = e.radius + clr - simd_length(d)
                            let along = simd_dot(d, anterior)
                            let lateral = simd_length(d - anterior * along)
                            let channel = min(e.radius + clr - lateral, along) // open to the front
                            socket = max(socket, max(sphere, channel))
                        }
                        let i = v.index(x, y, z)
                        shell[i] = min(shell[i], Float(-socket))
                    } } }
                    for (k, e) in eyes.enumerated() {
                        if let part = eyePart(e, v, name: e.center.x > 0 ? "eye-left" : "eye-right", taubin: o.taubinIterations) {
                            parts.append(part)
                            step(String(format: "%@: %.1f mL, watertight %@", part.name, part.report.volumeMM3 / 1000, part.report.isWatertight ? "yes" : "NO"))
                        }
                        _ = k
                    }
                } else {
                    step("eyes: skipped (no confident pair found)")
                }
            }

            // Split height: the brain's widest axial cross-section, so the brain lifts out of the bowl.
            let zc = o.headSplitMM ?? widestLevel(solid, v)
            split = zc
            step(String(format: "head split at S %.1f mm", zc))
            undercut = undercutVolumes(cavity: cavity, v, splitZ: zc)
            if let u = undercut { step(String(format: "cavity undercuts (not reachable by a straight lift): bowl %.1f mL, cap %.1f mL", u.0, u.1)) }
            for (name, sign) in [("head-top", 1.0), ("head-bottom", -1.0)] {
                var f = [Float](repeating: 0, count: g.count)
                for z in 0 ..< v.nz { for y in 0 ..< v.ny { for x in 0 ..< v.nx {
                    let i = v.index(x, y, z)
                    let h = v.patient(SIMD3(Double(x), Double(y), Double(z))).z
                    f[i] = min(shell[i], Float(sign * (h - zc)) - gap / 2)
                } } }
                guard let crop = Crop(f.map { $0 > 0 ? 1 : 0 }, g, margin: 3) else { continue }
                let mesh = surface(crop.extract(f), crop.grid, crop: crop, v, keepFraction: 0.05, taubin: o.taubinIterations)
                let r = MeshReport.analyze(mesh)
                parts.append(KitPart(name: name, group: "head", color: [0.93, 0.80, 0.72], mesh: mesh, report: r))
                step(String(format: "%@: %.0f mL, %d triangles, watertight %@", name, r.volumeMM3 / 1000, r.triangles, r.isWatertight ? "yes" : "NO"))
            }
            let wall = minimumWall(headMask: headMask, cavity: cavity, g)
            step(String(format: "head wall around cavity before thickening: min %.1f mm, 5th percentile %.1f mm", wall.min, wall.p5))
        }

        // Common frame for every part: RAS, assembly centred in x/y and sitting on z = 0.
        for i in parts.indices { MeshOps.lpsToPrintFrame(&parts[i].mesh) }
        if let b = parts.compactMap({ MeshOps.bounds($0.mesh) }).reduce(nil as (min: SIMD3<Float>, max: SIMD3<Float>)?, { acc, b in
            guard let a = acc else { return b }
            return (simd_min(a.min, b.min), simd_max(a.max, b.max))
        }) {
            let shift = SIMD3<Float>(-(b.min.x + b.max.x) / 2, -(b.min.y + b.max.y) / 2, -b.min.z)
            for i in parts.indices { for k in parts[i].mesh.vertices.indices { parts[i].mesh.vertices[k] += shift } }
        }
        step(String(format: "kit: %d parts in %.1f s", parts.count, Date().timeIntervalSince(t0)))
        return KitResult(parts: parts, log: log, splitHeightMM: split, eyes: eyes, overlapML: overlapML,
                         undercutML: undercut.map { (lower: $0.0, upper: $0.1) })
    }

    // MARK: helpers

    /// Part id per voxel (0 = not brain) — what the kit will cut; used for the app's region overlay.
    public static func regions(_ v: Volume, labels: [Int32], deep: Bool) -> [Int8] {
        let g = Grid(v)
        var brain = labels.map { Anatomy.isBrain($0) ? UInt8(1) : 0 }
        brain = Filters.fillHoles(Filters.largestComponent(brain, g), g)
        _ = ModelBuilder.trimInferiorTail(&brain, v, fraction: 0.05)
        return assignParts(labels, brain: Filters.largestComponent(brain, g), g, deep: deep, specs: Anatomy.parts(deep: deep))
    }

    static func ml(_ m: [UInt8], _ g: Grid) -> Double { Double(Filters.count(m)) * g.voxelVolume / 1000 }

    /// Labelled voxels take their part directly; the rest of the brain (white matter etc.) is grown
    /// outward from them breadth-first, never crossing into the other hemisphere.
    static func assignParts(_ labels: [Int32], brain: [UInt8], _ g: Grid, deep: Bool, specs: [PartSpec]) -> [Int8] {
        var part = [Int8](repeating: 0, count: g.count)
        var hemi = [Int8](repeating: 0, count: g.count)
        let partHemi = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, Int8($0.hemisphere)) })
        var frontier: [Int] = []
        for i in 0 ..< g.count where brain[i] != 0 {
            hemi[i] = Int8(Anatomy.hemisphere(of: labels[i]))
            let p = Anatomy.part(for: labels[i], deep: deep)
            if p > 0 { part[i] = Int8(p); frontier.append(i) }
        }
        let sxy = g.nx * g.ny
        for constrained in [true, false] {
            var queue = constrained ? frontier : (0 ..< g.count).filter { part[$0] != 0 }
            var head = 0
            while head < queue.count {
                let i = queue[head]; head += 1
                let p = part[i]
                let ph = partHemi[Int(p)] ?? 0
                let x = i % g.nx, y = (i / g.nx) % g.ny, z = i / sxy
                for j in [x > 0 ? i - 1 : -1, x < g.nx - 1 ? i + 1 : -1, y > 0 ? i - g.nx : -1, y < g.ny - 1 ? i + g.nx : -1,
                          z > 0 ? i - sxy : -1, z < g.nz - 1 ? i + sxy : -1] where j >= 0 {
                    guard brain[j] != 0, part[j] == 0 else { continue }
                    if constrained && hemi[j] != 0 && hemi[j] != ph { continue }
                    part[j] = p
                    queue.append(j)
                }
            }
        }
        return part
    }

    static func surface(_ field: [Float], _ cg: Grid, crop: Crop, _ v: Volume, keepFraction: Double, taubin: Int) -> Mesh {
        let off = SIMD3<Double>(Double(crop.x0), Double(crop.y0), Double(crop.z0))
        var m = Isosurface.extract(field, cg, iso: 0, toPatient: { v.patient($0 + off) }, flipWinding: v.handedness < 0)
        MeshOps.dropSmallComponents(&m, fraction: keepFraction)
        MeshOps.taubinSmooth(&m, iterations: taubin)
        return m
    }

    static func eyePart(_ e: EyeballEstimate, _ v: Volume, name: String, taubin: Int) -> KitPart? {
        // Analytic sphere on a fine local grid (0.4 mm) — eyeballs are near-spherical.
        let h = 0.4, r = e.radius
        let n = Int(ceil(2 * (r + 2) / h)) + 1
        let g = Grid(nx: n, ny: n, nz: n, sx: h, sy: h, sz: h)
        var f = [Float](repeating: 0, count: g.count)
        let c0 = e.center - SIMD3(repeating: r + 2)
        for z in 0 ..< n { for y in 0 ..< n { for x in 0 ..< n {
            let p = c0 + SIMD3(Double(x), Double(y), Double(z)) * h
            f[g.index(x, y, z)] = Float(r - simd_length(p - e.center))
        } } }
        var m = Isosurface.extract(f, g, iso: 0, toPatient: { c0 + $0 * h })
        MeshOps.taubinSmooth(&m, iterations: taubin)
        return KitPart(name: name, group: "eye", color: [0.96, 0.96, 0.94], mesh: m, report: MeshReport.analyze(m))
    }

    /// Patient S height (mm) of the largest axial cross-section of a mask.
    static func widestLevel(_ m: [UInt8], _ v: Volume) -> Double {
        var area: [Int: Int] = [:]
        for z in 0 ..< v.nz { for y in 0 ..< v.ny { for x in 0 ..< v.nx where m[v.index(x, y, z)] != 0 {
            area[Int(v.patient(SIMD3(Double(x), Double(y), Double(z))).z.rounded()), default: 0] += 1
        } } }
        // Smooth over ±3 mm so a single noisy level doesn't win.
        let keys = area.keys.sorted()
        var best = 0.0, bestK = keys.first ?? 0
        for k in keys {
            let s = (-3 ... 3).reduce(0.0) { $0 + Double(area[k + $1] ?? 0) }
            if s > best { best = s; bestK = k }
        }
        return Double(bestK)
    }

    /// Cavity voxels that a straight vertical lift cannot reach (lower bowl: from above; cap: from below).
    static func undercutVolumes(cavity: [Float], _ v: Volume, splitZ: Double) -> (Double, Double) {
        let f = AnatomicalFrame(v)
        let vert = f.voxelAxis[2], up = f.sign[2] // voxel axis pointing superior and its direction
        let dims = v.dims
        let others = [0, 1, 2].filter { $0 != vert }
        var lower = 0, upper = 0
        for a in 0 ..< dims[others[0]] { for b in 0 ..< dims[others[1]] {
            var c = [0, 0, 0]
            c[others[0]] = a; c[others[1]] = b
            // Walk the column from top to bottom in patient terms.
            let order = up > 0 ? Array((0 ..< dims[vert]).reversed()) : Array(0 ..< dims[vert])
            var cells: [(z: Double, inCavity: Bool)] = []
            for k in order {
                c[vert] = k
                let i = v.index(c[0], c[1], c[2])
                cells.append((v.patient(SIMD3(Double(c[0]), Double(c[1]), Double(c[2]))).z, cavity[i] > 0))
            }
            // Bowl: below the cut, reachable while every cell from the cut down is cavity.
            var open = true
            for cell in cells where cell.z < splitZ {
                if !cell.inCavity { open = false } else if !open { lower += 1 }
            }
            open = true
            for cell in cells.reversed() where cell.z >= splitZ {
                if !cell.inCavity { open = false } else if !open { upper += 1 }
            }
        } }
        let vv = v.voxelVolumeMM3 / 1000
        return (Double(lower) * vv, Double(upper) * vv)
    }

    /// Thickness of head material around the cavity, sampled on the cavity boundary.
    static func minimumWall(headMask: [UInt8], cavity: [Float], _ g: Grid) -> (min: Double, p5: Double) {
        let sd = Fields.signedDistance(headMask, g)
        var samples: [Float] = []
        for i in 0 ..< g.count where abs(cavity[i]) < Float(0.5 * g.sx) { samples.append(sd[i]) }
        guard !samples.isEmpty else { return (0, 0) }
        samples.sort()
        return (Double(samples[0]), Double(samples[samples.count / 20]))
    }
}

/// Axis-aligned sub-region of a grid (for meshing one part without touching the whole volume).
struct Crop {
    let x0: Int, y0: Int, z0: Int
    let grid: Grid
    let full: Grid

    init?(_ mask: [UInt8], _ g: Grid, margin: Int) {
        var lo = SIMD3<Int>(Int.max, Int.max, Int.max), hi = SIMD3<Int>(-1, -1, -1)
        for z in 0 ..< g.nz { for y in 0 ..< g.ny { for x in 0 ..< g.nx where mask[g.index(x, y, z)] != 0 {
            lo = simd_min(lo, SIMD3(x, y, z)); hi = simd_max(hi, SIMD3(x, y, z))
        } } }
        guard hi.x >= 0 else { return nil }
        lo = simd_max(lo &- margin, .zero)
        hi = simd_min(hi &+ margin, SIMD3(g.nx - 1, g.ny - 1, g.nz - 1))
        x0 = lo.x; y0 = lo.y; z0 = lo.z
        grid = Grid(nx: hi.x - lo.x + 1, ny: hi.y - lo.y + 1, nz: hi.z - lo.z + 1, sx: g.sx, sy: g.sy, sz: g.sz)
        full = g
    }

    func extract<T>(_ a: [T]) -> [T] {
        var out: [T] = []
        out.reserveCapacity(grid.count)
        for z in 0 ..< grid.nz { for y in 0 ..< grid.ny {
            let base = full.index(x0, y0 + y, z0 + z)
            out.append(contentsOf: a[base ..< base + grid.nx])
        } }
        return out
    }

    func forEach(_ body: (_ local: Int, _ global: Int) -> Void) {
        var local = 0
        for z in 0 ..< grid.nz { for y in 0 ..< grid.ny {
            let base = full.index(x0, y0 + y, z0 + z)
            for x in 0 ..< grid.nx { body(local, base + x); local += 1 }
        } }
    }
}
