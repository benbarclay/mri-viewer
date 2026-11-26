import Foundation
import simd

/// A synthetic, fully made-up "head" used for tests, demos and screenshots. Contains no patient data.
///
/// Geometry (DICOM patient LPS, mm, centred at the origin): skin/fat shell, dark skull, CSF layer,
/// grey-matter brain with sinusoidal "gyri", white-matter core, two ventricles, a neck cylinder, and a
/// bright orientation marker in the patient's LEFT-ANTERIOR-SUPERIOR brain.
public enum Phantom {
    public enum Plane: String, CaseIterable { case axial, coronal, sagittal, oblique }
    public enum Encoding { case explicitLE, implicitLE, jpeg2000Lossless }

    public static let headAxes = SIMD3<Double>(75, 95, 90)   // LR, AP, SI semi-axes
    public static let markerCenter = SIMD3<Double>(30, -40, 30)
    public static let markerRadius = 6.0
    /// Eyeballs (dark vitreous) inside balls of bright orbital fat, in front of/below the frontal lobes.
    public static let eyeCenters = [SIMD3<Double>(32, -76, -40), SIMD3<Double>(-32, -76, -40)]
    public static let eyeRadius = 11.0
    public static let orbitRadius = 15.0

    static func ellipsoid(_ p: SIMD3<Double>, _ scale: Double) -> Double {
        let q = p / (headAxes * scale)
        return simd_length_squared(q)
    }

    /// Brain surface factor including gyri modulation (inside brain when ellipsoid(p, factor) <= 1).
    static func brainScale(_ p: SIMD3<Double>) -> Double {
        let r = simd_length(p) + 1e-9
        let theta = acos(p.z / r), phi = atan2(p.y, p.x)
        return 0.85 + 0.025 * sin(9 * theta) * sin(7 * phi)
    }

    public static func isBrain(_ p: SIMD3<Double>) -> Bool { p.z > -45 && ellipsoid(p, brainScale(p)) <= 1 }

    /// Noise-free intensity at a patient-space point.
    public static func intensity(_ p: SIMD3<Double>) -> Float {
        if simd_length(p - markerCenter) <= markerRadius { return 1200 }
        for c in eyeCenters {
            let d = simd_length(p - c)
            if d <= eyeRadius { return 100 }
            if d <= orbitRadius { return 900 }
        }
        // Nose: makes the face reach well in front of the brain, as on a scan that isn't defaced.
        if simd_length_squared((p - SIMD3<Double>(0, -95, -50)) / SIMD3<Double>(9, 14, 20)) <= 1 { return 500 }
        let inHead = ellipsoid(p, 1.0) <= 1
        let inNeck = p.z < -40 && (p.x * p.x / (45 * 45) + p.y * p.y / (50 * 50)) <= 1
        if !inHead && !inNeck { return 0 }
        if inNeck && !inHead { return 450 }
        if ellipsoid(p, 0.94) > 1 { return 900 }          // scalp fat
        if ellipsoid(p, 0.88) > 1 { return 40 }           // skull
        if !isBrain(p) { return 120 }                     // CSF
        for c in [SIMD3<Double>(-12, 0, 10), SIMD3<Double>(12, 0, 10)] {
            let q = (p - c) / SIMD3<Double>(6, 22, 9)
            if simd_length_squared(q) <= 1 { return 120 } // ventricles
        }
        if ellipsoid(p, 0.68) <= 1 { return 800 }         // white matter
        return 520                                        // grey matter
    }

    /// FreeSurfer-style label (aparc.DKTatlas+aseg numbering) for a point, mimicking FastSurfer output:
    /// cortical lobe parcels on the brain rim, cerebral white matter inside, ventricles, cerebellum, brainstem.
    public static func label(_ p: SIMD3<Double>) -> Int32 {
        guard isBrain(p), simd_length(p - markerCenter) > markerRadius || true else { return 0 }
        let left = p.x > 0 // LPS: +x = patient left
        if p.z < -25 && p.y > 35 { return left ? 8 : 47 }            // cerebellum cortex
        if abs(p.x) < 12 && p.z < -20 && p.y > -10 && p.y < 35 { return 16 } // brainstem
        for c in [SIMD3<Double>(-12, 0, 10), SIMD3<Double>(12, 0, 10)] {
            if simd_length_squared((p - c) / SIMD3<Double>(6, 22, 9)) <= 1 { return c.x > 0 ? 4 : 43 }
        }
        if ellipsoid(p, 0.68) <= 1 { return left ? 2 : 41 }          // white matter
        let base: Int32 = left ? 1000 : 2000
        if p.y < -25 { return base + 28 }                             // superior frontal
        if p.y > 45 { return base + 11 }                              // lateral occipital
        if p.z < 0 && abs(p.x) > 30 { return base + 30 }              // superior temporal
        return base + 29                                              // superior parietal
    }

    struct Geometry {
        let row: SIMD3<Double>, col: SIMD3<Double>, normal: SIMD3<Double>
        let rows: Int, cols: Int, slices: Int
        let pixel: Double, gap: Double
    }

    static func geometry(_ plane: Plane) -> Geometry {
        switch plane {
        case .axial:
            return Geometry(row: [1, 0, 0], col: [0, 1, 0], normal: [0, 0, 1], rows: 112, cols: 96, slices: 96, pixel: 2, gap: 2)
        case .coronal:
            return Geometry(row: [1, 0, 0], col: [0, 0, -1], normal: [0, 1, 0], rows: 96, cols: 96, slices: 110, pixel: 2, gap: 2)
        case .sagittal:
            return Geometry(row: [0, 1, 0], col: [0, 0, -1], normal: [-1, 0, 0], rows: 96, cols: 112, slices: 84, pixel: 2, gap: 2)
        case .oblique:
            let a = 15.0 * .pi / 180
            let row = SIMD3<Double>(1, 0, 0)
            let col = SIMD3<Double>(0, cos(a), sin(a))
            return Geometry(row: row, col: col, normal: simd_cross(row, col), rows: 112, cols: 96, slices: 96, pixel: 2, gap: 2)
        }
    }

    /// Writes one DICOM file per slice into `dir` (created if needed). Returns the slice count.
    @discardableResult
    /// `partialVolume` averages 3×3×3 sub-samples per voxel, so tissue edges blend like a real scan
    /// (needed to test sub-voxel surface placement); off by default so voxels equal `intensity(_:)` exactly.
    public static func write(to dir: URL, plane: Plane, encoding: Encoding = .explicitLE, noise: Float = 15,
                             partialVolume: Bool = false) throws -> Int {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let g = geometry(plane)
        let center = SIMD3<Double>(0, 0, -10)
        let seriesUID = "2.25.1000\(Plane.allCases.firstIndex(of: plane)!)"
        var rng = SplitMix(seed: 42)
        for k in 0 ..< g.slices {
            let ipp = center - g.row * (Double(g.cols) / 2 * g.pixel) - g.col * (Double(g.rows) / 2 * g.pixel)
                + g.normal * ((Double(k) - Double(g.slices) / 2) * g.gap)
            var px = [UInt16](repeating: 0, count: g.rows * g.cols)
            for r in 0 ..< g.rows { for c in 0 ..< g.cols {
                let p = ipp + g.row * (Double(c) * g.pixel) + g.col * (Double(r) * g.pixel)
                var v: Float
                if partialVolume {
                    var acc: Float = 0
                    for a in [-1.0, 0, 1] { for b in [-1.0, 0, 1] { for cc in [-1.0, 0, 1] {
                        acc += intensity(p + (g.row * a + g.col * b + g.normal * cc) * (g.pixel / 3))
                    } } }
                    v = acc / 27
                } else {
                    v = intensity(p)
                }
                if v > 0 { v += noise * Float(rng.nextGaussian()) }
                px[r * g.cols + c] = UInt16(clamping: Int(max(0, v).rounded()))
            } }
            // Instance numbers run backwards and files are named out of order to exercise geometric sorting.
            let instance = g.slices - k
            var e = DICOMWriter(encoding: encoding)
            e.add(Tag(0x0008, 0x0016), "UI", "1.2.840.10008.5.1.4.1.1.4")
            e.add(Tag(0x0008, 0x0018), "UI", "\(seriesUID).\(instance)")
            e.add(.modality, "CS", "MR")
            e.add(.seriesDescription, "LO", "PHANTOM synthetic T1 (\(plane.rawValue))")
            e.addUndefinedSequence(Tag(0x0008, 0x1140), items: [[(Tag(0x0008, 0x1150), "UI", "1.2.840.10008.5.1.4.1.1.4")]])
            e.add(Tag(0x0010, 0x0010), "PN", "PHANTOM^SYNTHETIC")   // fake identifiers: tests assert these never leak
            e.add(Tag(0x0010, 0x0020), "LO", "PHANTOM-ID-0001")
            e.add(.sliceThickness, "DS", fmt(g.gap))
            e.add(.studyInstanceUID, "UI", "2.25.999")
            e.add(.seriesInstanceUID, "UI", seriesUID)
            e.add(.seriesNumber, "IS", "1")
            e.add(.instanceNumber, "IS", "\(instance)")
            e.add(.imagePositionPatient, "DS", [ipp.x, ipp.y, ipp.z].map(fmt).joined(separator: "\\"))
            e.add(.imageOrientationPatient, "DS", [g.row.x, g.row.y, g.row.z, g.col.x, g.col.y, g.col.z].map(fmt).joined(separator: "\\"))
            e.addUS(.samplesPerPixel, 1)
            e.add(.photometricInterpretation, "CS", "MONOCHROME2")
            e.addUS(.rows, g.rows)
            e.addUS(.columns, g.cols)
            e.add(.pixelSpacing, "DS", "\(fmt(g.pixel))\\\(fmt(g.pixel))")
            e.addUS(.bitsAllocated, 16)
            e.addUS(.bitsStored, 12)
            e.addUS(Tag(0x0028, 0x0102), 11)
            e.addUS(.pixelRepresentation, 0)
            e.add(.rescaleIntercept, "DS", "0")
            e.add(.rescaleSlope, "DS", "1")
            if encoding == .jpeg2000Lossless {
                let cs = try JPEG2000.encodeLossless(px.map { Int32($0) }, width: g.cols, height: g.rows, precision: 12)
                e.addEncapsulated(.pixelData, fragments: [cs])
            } else {
                var bytes = Data(capacity: px.count * 2)
                for v in px { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
                e.addBinary(.pixelData, "OW", bytes)
            }
            let name = String(format: "IM%04d", (k * 37) % g.slices) // scrambled file order
            try e.fileData().write(to: dir.appendingPathComponent(name))
        }
        return g.slices
    }

    static func fmt(_ d: Double) -> String {
        let s = String(format: "%.6f", d)
        let trimmed = s.contains(".") ? s.replacingOccurrences(of: "0+$", with: "", options: .regularExpression).replacingOccurrences(of: "\\.$", with: "", options: .regularExpression) : s
        return trimmed == "-0" ? "0" : trimmed
    }
}

/// Deterministic RNG so phantoms are reproducible.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func nextGaussian() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

/// Minimal DICOM Part 10 writer (little endian, uncompressed) for synthetic test data.
struct DICOMWriter {
    let encoding: Phantom.Encoding
    var body = Data()
    init(encoding: Phantom.Encoding) { self.encoding = encoding }

    static let longVRs: Set<String> = ["OB", "OW", "SQ", "UN", "UT"]

    static func header(_ tag: Tag, _ vr: String, _ length: UInt32, explicit: Bool) -> Data {
        var d = Data()
        func u16(_ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { for i in 0 ..< 4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        u16(tag.group); u16(tag.element)
        if explicit {
            d.append(contentsOf: Array(vr.utf8))
            if longVRs.contains(vr) { u16(0); u32(length) } else { u16(UInt16(length)) }
        } else {
            u32(length)
        }
        return d
    }

    static func padded(_ s: String, _ vr: String) -> Data {
        var d = Data(s.utf8)
        if d.count % 2 == 1 { d.append(vr == "UI" ? 0 : 0x20) }
        return d
    }

    mutating func add(_ tag: Tag, _ vr: String, _ value: String) {
        let v = Self.padded(value, vr)
        body += Self.header(tag, vr, UInt32(v.count), explicit: explicit) + v
    }

    var explicit: Bool { encoding != .implicitLE }

    mutating func addEncapsulated(_ tag: Tag, fragments: [Data]) {
        body += Self.header(tag, "OB", 0xFFFF_FFFF, explicit: true)
        body += Self.header(Tag(0xFFFE, 0xE000), "", 0, explicit: false) // empty basic offset table
        for f in fragments {
            var frag = f
            if frag.count % 2 == 1 { frag.append(0) }
            body += Self.header(Tag(0xFFFE, 0xE000), "", UInt32(frag.count), explicit: false) + frag
        }
        body += Self.header(Tag(0xFFFE, 0xE0DD), "", 0, explicit: false)
    }

    mutating func addUS(_ tag: Tag, _ value: Int) {
        body += Self.header(tag, "US", 2, explicit: explicit) + Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func addBinary(_ tag: Tag, _ vr: String, _ value: Data) {
        body += Self.header(tag, vr, UInt32(value.count), explicit: explicit) + value
    }

    mutating func addUndefinedSequence(_ tag: Tag, items: [[(Tag, String, String)]]) {
        body += Self.header(tag, "SQ", 0xFFFF_FFFF, explicit: explicit)
        for item in items {
            body += Self.header(Tag(0xFFFE, 0xE000), "", 0xFFFF_FFFF, explicit: false)
            for (t, vr, s) in item {
                let v = Self.padded(s, vr)
                body += Self.header(t, vr, UInt32(v.count), explicit: explicit) + v
            }
            body += Self.header(Tag(0xFFFE, 0xE00D), "", 0, explicit: false)
        }
        body += Self.header(Tag(0xFFFE, 0xE0DD), "", 0, explicit: false)
    }

    func fileData() -> Data {
        let ts: String
        switch encoding {
        case .explicitLE: ts = TransferSyntax.explicitLE
        case .implicitLE: ts = TransferSyntax.implicitLE
        case .jpeg2000Lossless: ts = TransferSyntax.jpeg2000Lossless
        }
        var meta = Data()
        meta += Self.header(Tag(0x0002, 0x0001), "OB", 2, explicit: true) + Data([0, 1])
        let sop = Self.padded("1.2.840.10008.5.1.4.1.1.4", "UI")
        meta += Self.header(Tag(0x0002, 0x0002), "UI", UInt32(sop.count), explicit: true) + sop
        let tsv = Self.padded(ts, "UI")
        meta += Self.header(.transferSyntaxUID, "UI", UInt32(tsv.count), explicit: true) + tsv
        var groupLength = Self.header(Tag(0x0002, 0x0000), "UL", 4, explicit: true)
        let n = UInt32(meta.count)
        for i in 0 ..< 4 { groupLength.append(UInt8((n >> (8 * UInt32(i))) & 0xFF)) }
        var out = Data(repeating: 0, count: 128)
        out += Data("DICM".utf8)
        out += groupLength + meta + body
        return out
    }
}
