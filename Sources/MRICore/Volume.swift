import Foundation
import simd

/// A 3D scalar volume in voxel order x (column), y (row), z (slice), with its patient-space geometry (DICOM LPS, mm).
public final class Volume {
    public let nx: Int, ny: Int, nz: Int
    public let spacing: SIMD3<Double>          // mm per voxel along x, y, z
    public let origin: SIMD3<Double>           // patient position of voxel (0,0,0)
    public let axes: [SIMD3<Double>]           // unit direction of voxel x, y, z in patient space
    public var data: [Float]
    /// Free-form notes about the assembly (irregular spacing etc.). Never contains patient data.
    public var warnings: [String] = []

    public init(nx: Int, ny: Int, nz: Int, spacing: SIMD3<Double>, origin: SIMD3<Double>, axes: [SIMD3<Double>], data: [Float]) {
        precondition(data.count == nx * ny * nz)
        self.nx = nx; self.ny = ny; self.nz = nz
        self.spacing = spacing; self.origin = origin; self.axes = axes; self.data = data
    }

    public var count: Int { nx * ny * nz }
    public var dims: [Int] { [nx, ny, nz] }
    @inline(__always) public func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * ny + y) * nx + x }
    @inline(__always) public func value(_ x: Int, _ y: Int, _ z: Int) -> Float { data[index(x, y, z)] }

    public var voxelVolumeMM3: Double { spacing.x * spacing.y * spacing.z }

    /// Patient-space position (mm) of a (possibly fractional) voxel coordinate.
    public func patient(_ v: SIMD3<Double>) -> SIMD3<Double> {
        origin + axes[0] * (v.x * spacing.x) + axes[1] * (v.y * spacing.y) + axes[2] * (v.z * spacing.z)
    }

    /// Voxel coordinate of a patient-space position.
    public func voxel(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let d = p - origin
        return SIMD3(simd_dot(d, axes[0]) / spacing.x, simd_dot(d, axes[1]) / spacing.y, simd_dot(d, axes[2]) / spacing.z)
    }

    /// Sign of the voxel→patient affine determinant (+1 right-handed).
    public var handedness: Double { simd_dot(simd_cross(axes[0], axes[1]), axes[2]) >= 0 ? 1 : -1 }

    public func copy(with newData: [Float]) -> Volume {
        let v = Volume(nx: nx, ny: ny, nz: nz, spacing: spacing, origin: origin, axes: axes, data: newData)
        v.warnings = warnings
        return v
    }

    // MARK: statistics

    public struct Stats { public let min: Float, max: Float, mean: Double }
    public func stats() -> Stats {
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude, sum = 0.0
        for v in data { lo = Swift.min(lo, v); hi = Swift.max(hi, v); sum += Double(v) }
        return Stats(min: lo, max: hi, mean: sum / Double(Swift.max(1, data.count)))
    }

    /// Approximate percentile (0...100) via a 4096-bin histogram.
    public func percentile(_ p: Double) -> Float { percentiles([p])[0] }

    public func percentiles(_ ps: [Double]) -> [Float] {
        let s = stats()
        guard s.max > s.min else { return ps.map { _ in s.min } }
        let bins = 4096
        var hist = [Int](repeating: 0, count: bins)
        let scale = Float(bins - 1) / (s.max - s.min)
        for v in data { hist[Int((v - s.min) * scale)] += 1 }
        return ps.map { p in
            let target = Int(Double(data.count) * p / 100)
            var acc = 0
            for (i, h) in hist.enumerated() {
                acc += h
                if acc > target { return s.min + Float(i) / scale }
            }
            return s.max
        }
    }
}

public enum VolumeLoader {
    /// Decodes every slice of a series and assembles a volume. `progress` receives (done, total).
    public static func load(_ series: SeriesInfo, progress: ((Int, Int) -> Void)? = nil) throws -> Volume {
        let slices = series.slices
        guard !slices.isEmpty else { throw DICOMError.missingElement("slices") }
        let nx = series.columns, ny = series.rows, nz = slices.count
        let plane = nx * ny
        var data = [Float](repeating: 0, count: plane * nz)
        var firstError: Error?
        let lock = NSLock()
        var done = 0
        data.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: nz) { k in
                do {
                    let f = try DICOMFile(url: slices[k].url)
                    guard let px = try PixelDecoder.decodeFrames(f).first, px.count == plane else {
                        throw DICOMError.decodeFailed("slice size mismatch")
                    }
                    let slope = Float(f.double(.rescaleSlope) ?? 1)
                    let intercept = Float(f.double(.rescaleIntercept) ?? 0)
                    let dst = base + k * plane
                    for i in 0 ..< plane { dst[i] = px[i] * slope + intercept }
                } catch {
                    lock.lock(); if firstError == nil { firstError = error }; lock.unlock()
                }
                lock.lock(); done += 1; let d = done; lock.unlock()
                if d % 10 == 0 || d == nz { progress?(d, nz) }
            }
        }
        if let e = firstError { throw e }

        // Geometry: slice spacing from the sorted positions projected on the normal.
        let n = series.normal
        var warnings: [String] = []
        var dz = series.sliceThickness ?? 1
        if nz > 1 {
            var gaps: [Double] = []
            for k in 1 ..< nz { gaps.append(simd_dot(slices[k].position - slices[k - 1].position, n)) }
            let sorted = gaps.sorted()
            dz = sorted[sorted.count / 2]
            if let lo = sorted.first, let hi = sorted.last, hi - lo > 0.01 * max(dz, 1e-6) + 1e-3 {
                warnings.append(String(format: "irregular slice spacing %.3f–%.3f mm (using median %.3f)", lo, hi, dz))
            }
        }
        if dz <= 0 { dz = 1; warnings.append("non-positive slice spacing; assumed 1 mm") }
        let spacing = SIMD3(series.pixelSpacing.y, series.pixelSpacing.x, dz) // x = column spacing, y = row spacing
        let v = Volume(nx: nx, ny: ny, nz: nz, spacing: spacing, origin: slices[0].position,
                       axes: [series.rowDirection, series.columnDirection, n], data: data)
        v.warnings = warnings
        return v
    }
}
