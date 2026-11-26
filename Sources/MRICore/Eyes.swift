import Foundation
import simd

public struct EyeballEstimate: CustomStringConvertible {
    public let center: SIMD3<Double>   // patient LPS mm
    public let radius: Double          // mm
    public let score: Double           // surround-minus-core contrast in threshold units
    public let fitRMS: Double          // sphere-fit residual (mm)

    public var description: String {
        String(format: "%@ eye: centre LPS (%.0f, %.0f, %.0f), radius %.1f mm, contrast %.2f, sphere-fit rms %.2f mm",
               center.x > 0 ? "left" : "right", center.x, center.y, center.z, radius, score, fitRMS)
    }
}

/// Finds the eyeballs on a T1 image: dark round vitreous (≈ 22–26 mm across) cupped by brighter orbital
/// fat and bone behind and around it, below the frontal lobes.
///
/// Lessons from real data baked in here:
/// - The head mask is not used: vitreous is dark and the eyelids are thin, so a skin mask stops at the
///   retrobulbar fat and leaves the globes "outside".
/// - Contrast and the sphere fit only look backwards and sideways, never through the front of the eye
///   (that's air/eyelid, which would dilute the contrast and pull the fit forwards).
/// - Don't assume adult anatomy: in children the globes are smaller, the centres can be < 50 mm apart and
///   sit behind the frontal pole, and the face barely protrudes in front of the brain.
public enum EyeFinder {
    nonisolated(unsafe) static var fitFailure = ""
    static let anterior = SIMD3<Double>(0, -1, 0) // LPS

    public static func find(_ v: Volume, smoothed s: [Float], head: [UInt8], brain: [UInt8],
                            darkThreshold t: Float, verbose: Bool = false, log: inout [String]) -> [EyeballEstimate] {
        let g = Grid(v)
        var yFront = Double.greatestFiniteMagnitude, zLo = Double.greatestFiniteMagnitude
        var xMid = 0.0, n = 0.0
        for z in Swift.stride(from: 0, to: v.nz, by: 2) { for y in Swift.stride(from: 0, to: v.ny, by: 2) { for x in Swift.stride(from: 0, to: v.nx, by: 2)
            where brain[g.index(x, y, z)] != 0 {
            let p = v.patient(SIMD3(Double(x), Double(y), Double(z)))
            yFront = min(yFront, p.y); zLo = min(zLo, p.z); xMid += p.x; n += 1
        } } }
        guard n > 0 else { log.append("eyes: no brain mask"); return [] }
        xMid /= n

        // Trilinear sample of the smoothed intensity at a patient point (nil outside the grid).
        func sample(_ p: SIMD3<Double>) -> Double? {
            let q = v.voxel(p)
            let x0 = Int(floor(q.x)), y0 = Int(floor(q.y)), z0 = Int(floor(q.z))
            guard x0 >= 0, y0 >= 0, z0 >= 0, x0 + 1 < v.nx, y0 + 1 < v.ny, z0 + 1 < v.nz else { return nil }
            let fx = q.x - Double(x0), fy = q.y - Double(y0), fz = q.z - Double(z0)
            var acc = 0.0
            for dz in 0 ... 1 { for dy in 0 ... 1 { for dx in 0 ... 1 {
                let w = (dx == 1 ? fx : 1 - fx) * (dy == 1 ? fy : 1 - fy) * (dz == 1 ? fz : 1 - fz)
                acc += w * Double(s[g.index(x0 + dx, y0 + dy, z0 + dz)])
            } } }
            return acc
        }
        // Golden-spiral directions; "back" ones exclude a forward cone (through the cornea/eyelids).
        let dirs: [SIMD3<Double>] = (0 ..< 64).map { i in
            let k = (Double(i) + 0.5) / 64, phi = acos(1 - 2 * k), th = Double.pi * (1 + sqrt(5)) * Double(i)
            return SIMD3(sin(phi) * cos(th), sin(phi) * sin(th), cos(phi))
        }
        let backDirs = dirs.filter { simd_dot($0, anterior) < 0.3 }
        func mean(_ c: SIMD3<Double>, radius r: Double, _ ds: [SIMD3<Double>]) -> Double? {
            var acc = 0.0
            for d in ds { guard let x = sample(c + d * r) else { return nil }; acc += x }
            return acc / Double(ds.count)
        }
        // Globe size scales with age (adult r ≈ 12 mm, young child ≈ 9–10.5 mm), so contrast is measured
        // at several radii and the best one kept.
        func contrast(_ c: SIMD3<Double>, radius r: Double) -> (core: Double, shell: Double)? {
            guard let c0 = sample(c), let c1 = mean(c, radius: 0.35 * r, dirs), let c2 = mean(c, radius: 0.6 * r, dirs),
                  let s1 = mean(c, radius: 1.2 * r, backDirs), let s2 = mean(c, radius: 1.4 * r, backDirs) else { return nil }
            return ((c0 + c1 + c2) / 3, (s1 + s2) / 2)
        }
        let radii: [Double] = [8, 9.5, 11, 12.5]
        /// Darkest sample inside the core (≤ 0.6 r): air pockets (sinuses, airway) reach near-background values.
        func coreMin(_ c: SIMD3<Double>, radius r: Double) -> Double {
            var m = sample(c) ?? 0
            for rr in [0.35 * r, 0.6 * r] { for d in dirs { if let x = sample(c + d * rr) { m = min(m, x) } } }
            return m
        }
        // Distance (mm) from each voxel to the nearest brain voxel: eyes sit outside the skull, clear of the brain.
        let brainD2 = Filters.distanceSquared(brain, g, to: 1, outsideIsTarget: false)
        func brainDistance(_ p: SIMD3<Double>) -> Double {
            let q = v.voxel(p)
            let xi = min(v.nx - 1, max(0, Int(q.x.rounded()))), yi = min(v.ny - 1, max(0, Int(q.y.rounded()))), zi = min(v.nz - 1, max(0, Int(q.z.rounded())))
            return Double(brainD2[g.index(xi, yi, zi)]).squareRoot()
        }
        func bestContrast(_ c: SIMD3<Double>) -> (core: Double, shell: Double, radius: Double)? {
            var best: (core: Double, shell: Double, radius: Double)?
            for r in radii {
                guard let k = contrast(c, radius: r) else { continue }
                if best == nil || k.shell - k.core > best!.shell - best!.core { best = (k.core, k.shell, r) }
            }
            return best
        }

        // Only used to express probe output in scan-independent units.
        let airT = Double(ModelBuilder.airTissueThreshold(s))
        if let probe = ProcessInfo.processInfo.environment["MRI_EYE_PROBE"] {
            for item in probe.split(separator: ";") {
                let f = item.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard f.count == 3 else { continue }
                let p = SIMD3(f[0], f[1], f[2])
                for r in radii { if let k = contrast(p, radius: r) {
                    log.append(String(format: "eye probe LPS (%.0f, %.0f, %.0f) r %.1f: core %.2f min %.2f shell %.2f (×air threshold), %.1f mm from brain",
                                      p.x, p.y, p.z, r, k.core / airT, coreMin(p, radius: r) / airT, k.shell / airT, brainDistance(p)))
                } }
            }
        }
        struct Cand { let p: SIMD3<Double>; let score: Double; let radius: Double }
        var cands: [Cand] = []
        for z in Swift.stride(from: zLo, through: zLo + 80, by: 2) {
            for y in Swift.stride(from: yFront - 40, through: yFront + 35, by: 2) {
                for dx in Swift.stride(from: 16.0, through: 46, by: 2) {
                    for side in [-1.0, 1.0] {
                        let p = SIMD3(xMid + side * dx, y, z)
                        let q = v.voxel(p)
                        let xi = Int(q.x.rounded()), yi = Int(q.y.rounded()), zi = Int(q.z.rounded())
                        guard xi >= 0, yi >= 0, zi >= 0, xi < v.nx, yi < v.ny, zi < v.nz, brain[g.index(xi, yi, zi)] == 0 else { continue }
                        // Vitreous is uniform fluid: its darkest point stays close to its mean. Air pockets (sinuses,
                        // airway) and CSF clefts mixed with bone dip far below it.
                        guard let c = bestContrast(p), c.core < Double(t) * 0.6, brainDistance(p) >= c.radius + 3,
                              coreMin(p, radius: c.radius) > 0.6 * c.core else { continue }
                        cands.append(Cand(p: p, score: (c.shell - c.core) / Double(t), radius: c.radius))
                    }
                }
            }
        }
        cands.sort { $0.score > $1.score }
        if verbose {
            var shown: [SIMD3<Double>] = []
            for c in cands where shown.allSatisfy({ simd_length($0 - c.p) > 8 }) {
                shown.append(c.p)
                log.append(String(format: "eye candidate: LPS (%.0f, %.0f, %.0f)  r %.1f  contrast %.2f", c.p.x, c.p.y, c.p.z, c.radius, c.score))
                if shown.count == 10 { break }
            }
        }
        guard !cands.isEmpty else { log.append("eyes: no candidates"); return [] }
        // Mirror-symmetric pairs among the top candidates, strongest first. The single strongest spot is
        // often something else (temporal CSF, a sinus), so each pair is verified by fitting spheres to the
        // actual vitreous boundary; the first pair that fits as two plausible globes wins.
        // Non-maximum suppression first, so one large dark region can't crowd out everything else.
        var top: [Cand] = []
        for c in cands where top.allSatisfy({ simd_length($0.p - c.p) >= 6 }) {
            top.append(c)
            if top.count == 80 { break }
        }
        var pairs: [(a: Cand, b: Cand, score: Double)] = []
        for i in top.indices { for j in top.indices where j > i {
            let a = top[i], b = top[j]
            guard (a.p.x - xMid) * (b.p.x - xMid) < 0 else { continue }
            let dx = abs(a.p.x - b.p.x)
            guard dx > 38, dx < 85, abs(a.p.y - b.p.y) < 10, abs(a.p.z - b.p.z) < 10,
                  abs((a.p.x + b.p.x) / 2 - xMid) < 12 else { continue }
            pairs.append((a, b, min(a.score, b.score) - 0.01 * (abs(a.p.y - b.p.y) + abs(a.p.z - b.p.z))))
        } }
        pairs.sort { $0.score > $1.score }
        var tried: [SIMD3<Double>] = []
        for pr in pairs {
            let mid = (pr.a.p + pr.b.p) / 2
            if tried.contains(where: { simd_length($0 - mid) < 8 }) { continue }
            tried.append(mid)
            if tried.count > 25 { break }
            if verbose {
                log.append(String(format: "eye pair: LPS (%.0f, %.0f, %.0f) + (%.0f, %.0f, %.0f)  contrast %.2f",
                                  pr.a.p.x, pr.a.p.y, pr.a.p.z, pr.b.p.x, pr.b.p.y, pr.b.p.z, pr.score))
            }
            var out: [EyeballEstimate] = []
            for cand in [pr.a, pr.b] {
                guard let e = fitSphere(from: cand.p, startRadius: cand.radius, sample: sample, dirs: backDirs,
                                        darkThreshold: t, contrast: { contrast($0, radius: $1) }) else { break }
                out.append(e)
            }
            guard out.count == 2 else { if verbose { log.append("  sphere fit failed (\(fitFailure))") }; continue }
            let sep = simd_length(out[0].center - out[1].center)
            // Plausibility (children through adults): globes ≈ 16–28 mm across, centres ≈ 40–80 mm apart,
            // similar sizes, clean spherical boundary, still clear of the brain.
            let ok = (40 ... 80).contains(sep) && abs(out[0].radius - out[1].radius) < 2
                && out.allSatisfy { $0.score > 0.3 && (8 ... 14).contains($0.radius) && $0.fitRMS < 1.5 && brainDistance($0.center) >= $0.radius }
            if !ok {
                if verbose { log.append(String(format: "  rejected: separation %.1f, radii %.1f/%.1f, rms %.2f/%.2f", sep, out[0].radius, out[1].radius, out[0].fitRMS, out[1].fitRMS)) }
                continue
            }
            for e in out { log.append(e.description) }
            log.append(String(format: "eyes: centre separation %.1f mm, height difference %.1f mm", sep, abs(out[0].center.z - out[1].center.z)))
            return out
        }
        log.append("eyes: no candidate pair fits as two eyeballs")
        return []
    }

    /// Casts rays backwards/sideways from `start`, finds where the dark vitreous ends, and fits a sphere
    /// to those boundary points by linear least squares (three passes: re-centre, drop outliers).
    static func fitSphere(from start: SIMD3<Double>, startRadius: Double, sample: (SIMD3<Double>) -> Double?, dirs: [SIMD3<Double>],
                          darkThreshold t: Float, contrast: (SIMD3<Double>, Double) -> (core: Double, shell: Double)?) -> EyeballEstimate? {
        var c = start
        var r = startRadius, rms = 0.0, score = 0.0
        for pass in 0 ..< 3 {
            guard let k = contrast(c, min(13, max(8, r))) else { fitFailure = "pass \(pass): sample outside grid"; return nil }
            score = (k.shell - k.core) / Double(t)
            if k.core <= 0 { fitFailure = "pass \(pass): empty core"; return nil }
            let cut = (k.core + k.shell) / 2
            var pts: [SIMD3<Double>] = []
            for d in dirs {
                var prev: Double?
                for step in 0 ..< 64 {
                    let dist = 0.4 * r + Double(step) * 0.25
                    guard let x = sample(c + d * dist) else { break }
                    if x >= cut {
                        let f = prev.map { (cut - $0) / max(1e-9, x - $0) } ?? 0
                        pts.append(c + d * (dist - 0.25 * (1 - f)))
                        break
                    }
                    prev = x
                }
            }
            if pass > 0 { pts = pts.filter { abs(simd_length($0 - c) - r) < 2.5 } }
            guard pts.count >= 10, let fit = leastSquaresSphere(pts) else {
                fitFailure = "pass \(pass): \(pts.count) boundary points"; return nil
            }
            c = fit.center; r = fit.radius
            rms = sqrt(pts.reduce(0) { $0 + pow(simd_length($1 - c) - r, 2) } / Double(pts.count))
        }
        return EyeballEstimate(center: c, radius: r, score: score, fitRMS: rms)
    }

    /// Solves 2 p·c + (r² − |c|²) = |p|² for c and r.
    static func leastSquaresSphere(_ pts: [SIMD3<Double>]) -> (center: SIMD3<Double>, radius: Double)? {
        var ata = simd_double4x4(0), atb = SIMD4<Double>.zero
        for p in pts {
            let row = SIMD4(2 * p.x, 2 * p.y, 2 * p.z, 1)
            let b = simd_length_squared(p)
            for i in 0 ..< 4 { ata[i] += row * row[i] }
            atb += row * b
        }
        guard abs(ata.determinant) > 1e-9 else { return nil }
        let x = ata.inverse * atb
        let c = SIMD3(x.x, x.y, x.z)
        let r2 = x.w + simd_length_squared(c)
        guard r2 > 0 else { return nil }
        return (c, sqrt(r2))
    }
}
