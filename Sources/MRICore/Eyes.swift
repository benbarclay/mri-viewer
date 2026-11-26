import Foundation
import simd

public struct EyeballEstimate: CustomStringConvertible {
    public let center: SIMD3<Double>   // patient LPS mm
    public let radius: Double          // mm
    public let score: Double           // shell-minus-core contrast in threshold units

    public var description: String {
        String(format: "%@ eye: radius %.1f mm, score %.2f", center.x > 0 ? "left" : "right", radius, score)
    }
}

/// Finds the two eyeballs on a T1 image: dark round vitreous (≈ 22–26 mm across) surrounded by bright
/// orbital fat, in front of and below the frontal lobes. Template matching on a coarse grid, then a
/// local region-grow to measure each globe.
public enum EyeFinder {
    public static func find(_ v: Volume, smoothed s: [Float], head: [UInt8], brain: [UInt8],
                            darkThreshold t: Float, verbose: Bool = false, log: inout [String]) -> [EyeballEstimate] {
        let g = Grid(v)
        // Brain extent in patient coordinates (anterior = −y in LPS).
        var yFront = Double.greatestFiniteMagnitude, zLo = Double.greatestFiniteMagnitude, zHi = -Double.greatestFiniteMagnitude
        var xMid = 0.0, n = 0.0
        for z in Swift.stride(from: 0, to: v.nz, by: 2) { for y in Swift.stride(from: 0, to: v.ny, by: 2) { for x in Swift.stride(from: 0, to: v.nx, by: 2)
            where brain[g.index(x, y, z)] != 0 {
            let p = v.patient(SIMD3(Double(x), Double(y), Double(z)))
            yFront = min(yFront, p.y); zLo = min(zLo, p.z); zHi = max(zHi, p.z); xMid += p.x; n += 1
        } } }
        guard n > 0 else { log.append("eyes: no brain mask"); return [] }
        xMid /= n
        // Is there a face at all? Eyes sit in front of the brain; scans are often defaced for anonymity.
        var faceDepth = 0.0
        for z in Swift.stride(from: 0, to: v.nz, by: 2) { for y in Swift.stride(from: 0, to: v.ny, by: 2) { for x in Swift.stride(from: 0, to: v.nx, by: 2)
            where head[g.index(x, y, z)] != 0 {
            let p = v.patient(SIMD3(Double(x), Double(y), Double(z)))
            if p.z < zLo + 70 && abs(p.x - xMid) < 50 { faceDepth = max(faceDepth, yFront - p.y) }
        } } }
        if faceDepth < 25 {
            log.append(String(format: "eyes: head reaches only %.0f mm in front of the brain at eye level — the face is missing (defaced or outside the field of view)", faceDepth))
            return []
        }

        // Sphere sample offsets (voxel units), sub-sampled for speed.
        func offsets(_ r0: Double, _ r1: Double, step: Int) -> [SIMD3<Int>] {
            var out: [SIMD3<Int>] = []
            let rx = Int(ceil(r1 / v.spacing.x)), ry = Int(ceil(r1 / v.spacing.y)), rz = Int(ceil(r1 / v.spacing.z))
            for dz in Swift.stride(from: -rz, through: rz, by: step) { for dy in Swift.stride(from: -ry, through: ry, by: step) { for dx in Swift.stride(from: -rx, through: rx, by: step) {
                let r = simd_length(SIMD3(Double(dx) * v.spacing.x, Double(dy) * v.spacing.y, Double(dz) * v.spacing.z))
                if r >= r0 && r <= r1 { out.append(SIMD3(dx, dy, dz)) }
            } } }
            return out
        }
        let core = offsets(0, 8, step: 2), shell = offsets(13.5, 17, step: 2)
        func mean(_ c: SIMD3<Int>, _ offs: [SIMD3<Int>]) -> Double? {
            var acc = 0.0, k = 0
            for o in offs {
                let p = c &+ o
                guard p.x >= 0, p.y >= 0, p.z >= 0, p.x < v.nx, p.y < v.ny, p.z < v.nz else { return nil }
                acc += Double(s[g.index(p.x, p.y, p.z)]); k += 1
            }
            return k > 0 ? acc / Double(k) : nil
        }

        struct Cand { let c: SIMD3<Int>; let p: SIMD3<Double>; let score: Double }
        var cands: [Cand] = []
        let step = max(1, Int((2.0 / v.spacing.x).rounded()))
        for z in Swift.stride(from: 0, to: v.nz, by: step) { for y in Swift.stride(from: 0, to: v.ny, by: step) { for x in Swift.stride(from: 0, to: v.nx, by: step) {
            let i = g.index(x, y, z)
            guard head[i] != 0, brain[i] == 0, s[i] < t else { continue }
            let p = v.patient(SIMD3(Double(x), Double(y), Double(z)))
            guard p.y > yFront - 40, p.y < yFront + 15, p.z > zLo, p.z < zHi - 40, abs(p.x - xMid) > 20, abs(p.x - xMid) < 45 else { continue }
            let c = SIMD3(x, y, z)
            guard let mc = mean(c, core), mc < Double(t) * 0.8, let ms = mean(c, shell) else { continue }
            cands.append(Cand(c: c, p: p, score: (ms - mc) / Double(t)))
        } } }
        cands.sort { $0.score > $1.score }
        guard let first = cands.first else { log.append("eyes: no candidates found"); return [] }
        if verbose {
            // Positions relative to the brain (x from midline, y behind the frontal pole, z above brain bottom).
            var shown: [SIMD3<Double>] = []
            for c in cands where shown.allSatisfy({ simd_length($0 - c.p) > 8 }) {
                shown.append(c.p)
                log.append(String(format: "eye candidate: x %+.0f y %+.0f z %+.0f mm  score %.2f", c.p.x - xMid, c.p.y - yFront, c.p.z - zLo, c.score))
                if shown.count == 12 { break }
            }
        }
        // Best partner on the other side, roughly mirror-symmetric.
        let partner = cands.first { c in
            let dx = abs(c.p.x - first.p.x)
            return (c.p.x - xMid) * (first.p.x - xMid) < 0 && dx > 45 && dx < 80 && abs(c.p.y - first.p.y) < 12 && abs(c.p.z - first.p.z) < 12
        }
        var out: [EyeballEstimate] = []
        for cand in [first, partner].compactMap({ $0 }) {
            guard let mc = mean(cand.c, core), let ms = mean(cand.c, shell) else { continue }
            let cut = Float((mc + ms) / 2)
            // Region-grow the dark globe within 15 mm of the candidate.
            let r15 = 15.0
            var seen = Set<Int>(), stack = [g.index(cand.c.x, cand.c.y, cand.c.z)]
            var sum = SIMD3<Double>.zero, count = 0.0
            seen.insert(stack[0])
            while let i = stack.popLast() {
                let x = i % g.nx, y = (i / g.nx) % g.ny, z = i / (g.nx * g.ny)
                let p = v.patient(SIMD3(Double(x), Double(y), Double(z)))
                sum += p; count += 1
                for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                    let nx = x + dx, ny = y + dy, nz = z + dz
                    guard nx >= 0, ny >= 0, nz >= 0, nx < g.nx, ny < g.ny, nz < g.nz else { continue }
                    let j = g.index(nx, ny, nz)
                    if seen.contains(j) || s[j] >= cut { continue }
                    if simd_length(v.patient(SIMD3(Double(nx), Double(ny), Double(nz))) - cand.p) > r15 { continue }
                    seen.insert(j); stack.append(j)
                }
            }
            let vol = count * g.voxelVolume
            let r = pow(3 * vol / (4 * .pi), 1.0 / 3)
            let e = EyeballEstimate(center: sum / max(1, count), radius: min(14, max(9, r)), score: cand.score)
            log.append(e.description + String(format: " (region %.1f mL)", vol / 1000))
            out.append(e)
        }
        guard out.count == 2 else { log.append("eyes: found \(out.count) (expected 2)"); return [] }
        let sep = simd_length(out[0].center - out[1].center)
        log.append(String(format: "eyes: centre separation %.1f mm, height difference %.1f mm", sep, abs(out[0].center.z - out[1].center.z)))
        // Plausibility: adult globes ≈ 22–27 mm across, centres ≈ 55–75 mm apart, clear vitreous/fat contrast.
        let ok = (50 ... 78).contains(sep) && out.allSatisfy { $0.score > 0.6 && (9.5 ... 14).contains($0.radius) }
        if !ok { log.append("eyes: rejected as implausible (separation, size or contrast out of range)"); return [] }
        return out
    }
}
