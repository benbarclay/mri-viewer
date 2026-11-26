import Compression
import Foundation
import simd

/// NIfTI-1 export and label-map import (NIfTI-1 / FreeSurfer MGH/MGZ), used to exchange volumes with
/// segmentation tools such as FastSurfer. Headers carry geometry only — no patient metadata.
public enum NIfTI {
    /// Voxel → RAS (mm) affine of a volume (DICOM is LPS; NIfTI/FreeSurfer are RAS).
    public static func rasAffine(_ v: Volume) -> simd_double4x4 {
        let flip = SIMD3<Double>(-1, -1, 1)
        let c0 = v.axes[0] * v.spacing.x * flip, c1 = v.axes[1] * v.spacing.y * flip, c2 = v.axes[2] * v.spacing.z * flip
        let o = v.origin * flip
        return simd_double4x4(columns: (SIMD4(c0, 0), SIMD4(c1, 0), SIMD4(c2, 0), SIMD4(o, 1)))
    }

    /// Writes a float32 NIfTI-1 (.nii) file with matching qform and sform.
    public static func write(_ v: Volume, to url: URL) throws {
        var h = Data(count: 352)
        func i32(_ off: Int, _ x: Int32) { var y = x.littleEndian; h.replaceSubrange(off ..< off + 4, with: Data(bytes: &y, count: 4)) }
        func i16(_ off: Int, _ x: Int16) { var y = x.littleEndian; h.replaceSubrange(off ..< off + 2, with: Data(bytes: &y, count: 2)) }
        func f32(_ off: Int, _ x: Double) { var y = Float(x).bitPattern.littleEndian; h.replaceSubrange(off ..< off + 4, with: Data(bytes: &y, count: 4)) }
        i32(0, 348)
        for (k, d) in [3, v.nx, v.ny, v.nz, 1, 1, 1, 1].enumerated() { i16(40 + 2 * k, Int16(d)) }
        i16(70, 16)   // DT_FLOAT32
        i16(72, 32)
        let a = rasAffine(v)
        // Rotation part (unit columns) for the quaternion.
        var r = simd_double3x3(columns: (simd_normalize(SIMD3(a.columns.0.x, a.columns.0.y, a.columns.0.z)),
                                         simd_normalize(SIMD3(a.columns.1.x, a.columns.1.y, a.columns.1.z)),
                                         simd_normalize(SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z))))
        var qfac = 1.0
        if simd_determinant(r) < 0 { qfac = -1; r.columns.2 = -r.columns.2 }
        for (k, p) in [qfac, v.spacing.x, v.spacing.y, v.spacing.z, 1, 1, 1, 1].enumerated() { f32(76 + 4 * k, p) }
        f32(108, 352) // vox_offset
        f32(112, 1)   // scl_slope
        h[123] = 2    // xyzt_units: mm
        let descrip = Array("mri-viewer export".utf8)
        h.replaceSubrange(148 ..< 148 + descrip.count, with: descrip)
        i16(252, 1); i16(254, 1) // qform_code, sform_code = scanner
        let q = simd_quatd(r)
        let qq = q.real < 0 ? -q.vector : q.vector // NIfTI requires a >= 0
        f32(256, qq.x); f32(260, qq.y); f32(264, qq.z)
        f32(268, a.columns.3.x); f32(272, a.columns.3.y); f32(276, a.columns.3.z)
        for row in 0 ..< 3 {
            for col in 0 ..< 4 { f32(280 + 16 * row + 4 * col, a[col][row]) }
        }
        h.replaceSubrange(344 ..< 348, with: Array("n+1\0".utf8))
        var out = h
        out.reserveCapacity(352 + v.count * 4)
        v.data.withUnsafeBufferPointer { buf in
            buf.withMemoryRebound(to: UInt8.self) { out.append($0.baseAddress!, count: v.count * 4) }
        }
        try out.write(to: url, options: .atomic)
    }
}

/// An integer label map (e.g. FreeSurfer aseg/aparc) with its voxel → RAS affine.
public struct LabelVolume {
    public let dims: [Int]
    public let affine: simd_double4x4      // voxel (i,j,k) → RAS mm
    public let labels: [Int32]

    public init(dims: [Int], affine: simd_double4x4, labels: [Int32]) {
        self.dims = dims; self.affine = affine; self.labels = labels
    }

    public static func read(_ url: URL) throws -> LabelVolume {
        var bytes = [UInt8](try Data(contentsOf: url))
        if bytes.count > 2 && bytes[0] == 0x1F && bytes[1] == 0x8B { bytes = try Gzip.decompress(bytes) }
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".mgz") || name.hasSuffix(".mgh") { return try readMGH(bytes) }
        return try readNIfTI(bytes)
    }

    /// Nearest-neighbour resampling of the labels onto a volume's grid (0 outside the label map).
    public func resampled(onto v: Volume) -> [Int32] {
        let inv = affine.inverse
        let toRAS = NIfTI.rasAffine(v)
        let m = inv * toRAS // target voxel → label voxel
        var out = [Int32](repeating: 0, count: v.count)
        let (nx, ny, nz) = (dims[0], dims[1], dims[2])
        out.withUnsafeMutableBufferPointer { dst in
            DispatchQueue.concurrentPerform(iterations: v.nz) { z in
                for y in 0 ..< v.ny { for x in 0 ..< v.nx {
                    let p = m * SIMD4(Double(x), Double(y), Double(z), 1)
                    let i = Int(p.x.rounded()), j = Int(p.y.rounded()), k = Int(p.z.rounded())
                    if i >= 0, j >= 0, k >= 0, i < nx, j < ny, k < nz {
                        dst[v.index(x, y, z)] = labels[(k * ny + j) * nx + i]
                    }
                } }
            }
        }
        return out
    }

    static func be32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
    static func beF(_ b: [UInt8], _ o: Int) -> Double { Double(Float(bitPattern: be32(b, o))) }

    static func readMGH(_ b: [UInt8]) throws -> LabelVolume {
        guard b.count >= 284 else { throw DICOMError.truncated(at: b.count) }
        let w = Int(be32(b, 4)), h = Int(be32(b, 8)), d = Int(be32(b, 12)), type = Int(be32(b, 20))
        let good = Int(Int16(bitPattern: UInt16(b[28]) << 8 | UInt16(b[29])))
        var sp = SIMD3<Double>(1, 1, 1)
        var xr = SIMD3<Double>(-1, 0, 0), yr = SIMD3<Double>(0, 0, -1), zr = SIMD3<Double>(0, 1, 0), c = SIMD3<Double>(0, 0, 0)
        if good > 0 {
            sp = SIMD3(beF(b, 30), beF(b, 34), beF(b, 38))
            xr = SIMD3(beF(b, 42), beF(b, 46), beF(b, 50))
            yr = SIMD3(beF(b, 54), beF(b, 58), beF(b, 62))
            zr = SIMD3(beF(b, 66), beF(b, 70), beF(b, 74))
            c = SIMD3(beF(b, 78), beF(b, 82), beF(b, 86))
        }
        let c0 = xr * sp.x, c1 = yr * sp.y, c2 = zr * sp.z
        let half = SIMD3(Double(w), Double(h), Double(d)) / 2
        let p0 = c - (c0 * half.x + c1 * half.y + c2 * half.z)
        let aff = simd_double4x4(columns: (SIMD4(c0, 0), SIMD4(c1, 0), SIMD4(c2, 0), SIMD4(p0, 1)))
        let n = w * h * d
        var labels = [Int32](repeating: 0, count: n)
        let o = 284
        switch type {
        case 0: guard b.count >= o + n else { throw DICOMError.truncated(at: b.count) }
            for i in 0 ..< n { labels[i] = Int32(b[o + i]) }
        case 4: guard b.count >= o + 2 * n else { throw DICOMError.truncated(at: b.count) }
            for i in 0 ..< n { labels[i] = Int32(Int16(bitPattern: UInt16(b[o + 2 * i]) << 8 | UInt16(b[o + 2 * i + 1]))) }
        case 1: guard b.count >= o + 4 * n else { throw DICOMError.truncated(at: b.count) }
            for i in 0 ..< n { labels[i] = Int32(bitPattern: be32(b, o + 4 * i)) }
        case 3: guard b.count >= o + 4 * n else { throw DICOMError.truncated(at: b.count) }
            for i in 0 ..< n { labels[i] = Int32(Float(bitPattern: be32(b, o + 4 * i)).rounded()) }
        default: throw DICOMError.unsupported("MGH data type \(type)")
        }
        return LabelVolume(dims: [w, h, d], affine: aff, labels: labels)
    }

    static func readNIfTI(_ b: [UInt8]) throws -> LabelVolume {
        guard b.count >= 352 else { throw DICOMError.truncated(at: b.count) }
        func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(b[o]) | UInt16(b[o + 1]) << 8)) }
        func f32(_ o: Int) -> Double { Double(Float(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)) }
        guard i16(0) == 348 else { throw DICOMError.unsupported("not little-endian NIfTI-1") }
        let dims = [i16(42), i16(44), i16(46)]
        let type = i16(70), off = Int(f32(108))
        var aff = matrix_identity_double4x4
        if i16(254) > 0 {
            for row in 0 ..< 3 { for col in 0 ..< 4 { aff[col][row] = f32(280 + 16 * row + 4 * col) } }
        } else {
            aff = simd_double4x4(diagonal: SIMD4(f32(80), f32(84), f32(88), 1))
        }
        let n = dims[0] * dims[1] * dims[2]
        var labels = [Int32](repeating: 0, count: n)
        let slope = f32(112) == 0 ? 1 : f32(112), inter = f32(116)
        func put(_ i: Int, _ v: Double) { labels[i] = Int32((v * slope + inter).rounded()) }
        switch type {
        case 2: for i in 0 ..< n { put(i, Double(b[off + i])) }
        case 4: for i in 0 ..< n { put(i, Double(i16(off + 2 * i))) }
        case 512: for i in 0 ..< n { put(i, Double(UInt16(b[off + 2 * i]) | UInt16(b[off + 2 * i + 1]) << 8)) }
        case 8: for i in 0 ..< n { let o = off + 4 * i; put(i, Double(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24))) }
        case 16: for i in 0 ..< n { put(i, f32(off + 4 * i)) }
        default: throw DICOMError.unsupported("NIfTI datatype \(type)")
        }
        return LabelVolume(dims: dims, affine: aff, labels: labels)
    }
}

enum Gzip {
    static func decompress(_ b: [UInt8]) throws -> [UInt8] {
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw DICOMError.unsupported("not gzip") }
        let flags = b[3]
        var p = 10
        if flags & 4 != 0 { p += 2 + Int(b[p]) | Int(b[p + 1]) << 8 }
        if flags & 8 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }
        if flags & 16 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }
        if flags & 2 != 0 { p += 2 }
        let n = b.count
        let isize = Int(UInt32(b[n - 4]) | UInt32(b[n - 3]) << 8 | UInt32(b[n - 2]) << 16 | UInt32(b[n - 1]) << 24)
        var out = [UInt8](repeating: 0, count: max(isize, 1))
        let written = b.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress! + p, n - p - 8, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == isize else { throw DICOMError.decodeFailed("gzip: got \(written) of \(isize) bytes") }
        return out
    }
}
