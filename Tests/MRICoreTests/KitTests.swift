import Compression
import XCTest
import simd
@testable import MRICore

/// Print-kit, smoothing and file-format tests — synthetic phantom data only.
final class KitTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mri-kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func phantom(_ plane: Phantom.Plane = .sagittal, noise: Float = 15, partialVolume: Bool = false) throws -> Volume {
        let dir = tmp.appendingPathComponent("\(plane.rawValue)-\(partialVolume)")
        try Phantom.write(to: dir, plane: plane, noise: noise, partialVolume: partialVolume)
        return try VolumeLoader.load(try SeriesScanner.scan(directory: dir)[0])
    }

    func phantomLabels(_ v: Volume) -> [Int32] {
        var lab = [Int32](repeating: 0, count: v.count)
        for z in 0 ..< v.nz { for y in 0 ..< v.ny { for x in 0 ..< v.nx {
            lab[v.index(x, y, z)] = Phantom.label(v.patient(SIMD3(Double(x), Double(y), Double(z))))
        } } }
        return lab
    }

    func testNIfTIRoundTripPreservesGeometryAndValues() throws {
        let v = try phantom(.oblique, noise: 0)
        let url = tmp.appendingPathComponent("v.nii")
        let labels = phantomLabels(v)
        try NIfTI.write(v.copy(with: labels.map(Float.init)), to: url)
        let lv = try LabelVolume.read(url)
        XCTAssertEqual(lv.dims, v.dims)
        XCTAssertEqual(lv.resampled(onto: v), labels)
    }

    func testMGZReaderWithFreeSurferGeometry() throws {
        // 1 mm LIA "conformed" grid, like FastSurfer output, gzip-compressed.
        let n = 64
        var labels = [Int32](repeating: 0, count: n * n * n)
        for i in labels.indices { labels[i] = Int32(i % 7 == 0 ? 2 : 0) }
        var h = [UInt8](repeating: 0, count: 284)
        func be32(_ o: Int, _ v: UInt32) { for k in 0 ..< 4 { h[o + k] = UInt8((v >> (24 - 8 * UInt32(k))) & 0xFF) } }
        func beF(_ o: Int, _ f: Float) { be32(o, f.bitPattern) }
        be32(0, 1); be32(4, UInt32(n)); be32(8, UInt32(n)); be32(12, UInt32(n)); be32(16, 1); be32(20, 4)
        h[28] = 0; h[29] = 1
        for (k, f) in [1, 1, 1, -1, 0, 0, 0, 0, -1, 0, 1, 0, 5, -3, 2].enumerated() { beF(30 + 4 * k, Float(f)) }
        var body = h
        for l in labels { let s = UInt16(bitPattern: Int16(l)); body += [UInt8(s >> 8), UInt8(s & 0xFF)] }
        let url = tmp.appendingPathComponent("l.mgz")
        try gzip(body).write(to: url)
        let lv = try LabelVolume.read(url)
        XCTAssertEqual(lv.dims, [n, n, n])
        XCTAssertEqual(lv.labels, labels)
        // Centre voxel maps to c_ras; +i goes toward −R (LIA).
        let c = lv.affine * SIMD4(Double(n / 2), Double(n / 2), Double(n / 2), 1)
        XCTAssertEqual(c.x, 5, accuracy: 1e-6); XCTAssertEqual(c.y, -3, accuracy: 1e-6); XCTAssertEqual(c.z, 2, accuracy: 1e-6)
        let step = lv.affine * SIMD4(Double(n / 2 + 1), Double(n / 2), Double(n / 2), 1)
        XCTAssertEqual(step.x - c.x, -1, accuracy: 1e-6)
    }

    func gzip(_ b: [UInt8]) -> Data {
        var out = [UInt8](repeating: 0, count: b.count + 1024)
        let n = compression_encode_buffer(&out, out.count, b, b.count, nil, COMPRESSION_ZLIB)
        var d = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
        d += out[0 ..< n]
        d += [0, 0, 0, 0] // CRC (not checked)
        let s = UInt32(b.count)
        d += [UInt8(s & 0xFF), UInt8((s >> 8) & 0xFF), UInt8((s >> 16) & 0xFF), UInt8(s >> 24)]
        return d
    }

    func testIntensityGuidedSurfaceIsSmootherThanMask() throws {
        // Coarse 2 mm voxels with partial-volume edges: the mask surface is terraced, the guided one isn't.
        let v = try phantom(.axial, partialVolume: true)
        var a = ModelOptions(), b = ModelOptions()
        a.surface = .mask; b.surface = .intensity
        let ra = ModelBuilder.build(v, options: a), rb = ModelBuilder.build(v, options: b)
        XCTAssertTrue(rb.report.isWatertight)
        XCTAssertLessThan(rb.stepping, ra.stepping * 0.75, "guided \(rb.stepping) vs mask \(ra.stepping)")
        XCTAssertEqual(rb.report.volumeMM3, ra.report.volumeMM3, accuracy: ra.report.volumeMM3 * 0.05)
    }

    func testPrintKitOnPhantom() throws {
        let v = try phantom()
        let r = PrintKit.build(v, labels: phantomLabels(v), options: KitOptions())
        let names = Set(r.parts.map(\.name))
        for n in ["left-frontal", "left-parietal", "left-temporal", "left-occipital", "right-frontal", "right-parietal",
                  "right-temporal", "right-occipital", "cerebellum", "brainstem", "head-top", "head-bottom", "eye-left", "eye-right"] {
            XCTAssertTrue(names.contains(n), "missing \(n)")
        }
        for p in r.parts {
            XCTAssertTrue(p.report.isWatertight, "\(p.name): \(p.report)")
            XCTAssertGreaterThan(p.report.volumeMM3, 0, "\(p.name) inside-out")
        }
        XCTAssertLessThan(r.overlapML, 0.5)
        // Brain parts together ≈ the analytic brain (gaps and smoothing remove a little).
        let brainML = r.parts.filter { $0.group == "brain" }.reduce(0) { $0 + $1.report.volumeMM3 } / 1000
        XCTAssertEqual(brainML, 1480, accuracy: 1480 * 0.08)
        // Eyes: positions and size match the phantom.
        XCTAssertEqual(r.eyes.count, 2)
        for e in r.eyes {
            let truth = Phantom.eyeCenters.min { simd_length($0 - e.center) < simd_length($1 - e.center) }!
            XCTAssertLessThan(simd_length(truth - e.center), 2.0)
            XCTAssertEqual(e.radius, Phantom.eyeRadius, accuracy: 1.0)
        }
        // Brain must fit inside the head cavity: no brain part touches head material.
        let head = r.parts.filter { $0.group == "head" }
        XCTAssertEqual(head.count, 2)
        // Head halves are separated by the cut plane: top piece sits above bottom piece.
        let top = MeshOps.bounds(head.first { $0.name == "head-top" }!.mesh)!, bottom = MeshOps.bounds(head.first { $0.name == "head-bottom" }!.mesh)!
        // (Surface smoothing rounds the cut rims a little into the 0.2 mm gap.)
        XCTAssertGreaterThanOrEqual(top.min.z, bottom.max.z - 0.3)
    }

    func testBrainPartsDoNotIntersectHeadShell() throws {
        // Sample brain-part vertices against the shell field: every vertex must lie in the cavity.
        let v = try phantom()
        var o = KitOptions(); o.eyes = false
        let r = PrintKit.build(v, labels: phantomLabels(v), options: o)
        let brainVerts = r.parts.filter { $0.group == "brain" }.flatMap { $0.mesh.vertices }
        let headMeshes = r.parts.filter { $0.group == "head" }.map(\.mesh)
        // Point-in-mesh by ray parity along +x for a sample of brain vertices.
        var inside = 0
        let sample = stride(from: 0, to: brainVerts.count, by: max(1, brainVerts.count / 300)).map { brainVerts[$0] }
        for p in sample where headMeshes.contains(where: { contains($0, p) }) { inside += 1 }
        XCTAssertEqual(inside, 0, "\(inside) of \(sample.count) brain vertices are inside head material")
    }

    func contains(_ m: Mesh, _ p: SIMD3<Float>) -> Bool { MeshOps.contains(m, p) }

    func testEyesSitInFrontOpeningSockets() throws {
        let v = try phantom()
        let r = PrintKit.build(v, labels: phantomLabels(v), options: KitOptions())
        let eyes = r.parts.filter { $0.group == "eye" }
        XCTAssertEqual(eyes.count, 2)
        let head = r.parts.filter { $0.group == "head" }.map(\.mesh)
        for e in eyes {
            let verts = e.mesh.vertices
            let sample = stride(from: 0, to: verts.count, by: max(1, verts.count / 200)).map { verts[$0] }
            XCTAssertEqual(sample.filter { p in head.contains { contains($0, p) } }.count, 0, "\(e.name) intersects the head")
            // STL frame is RAS: anterior = +y. Nothing in front of the eye centre (the socket opens forwards).
            let b = MeshOps.bounds(e.mesh)!, c = (b.min + b.max) / 2
            XCTAssertEqual(head.map { MeshOps.rayHits($0, from: c, dir: SIMD3(0.0003, 1, 0.0002)) }.reduce(0, +), 0, "\(e.name) socket is closed in front")
        }
    }
}
