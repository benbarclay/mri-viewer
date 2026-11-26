import XCTest
import simd
@testable import MRICore

/// All tests use synthetic data only (Phantom); no real scans are needed or included.
final class MRICoreTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mri-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func loadPhantom(_ plane: Phantom.Plane, _ enc: Phantom.Encoding = .explicitLE, noise: Float = 0) throws -> Volume {
        let dir = tmp.appendingPathComponent("\(plane.rawValue)-\(enc)")
        try Phantom.write(to: dir, plane: plane, encoding: enc, noise: noise)
        let series = try SeriesScanner.scan(directory: dir)
        XCTAssertEqual(series.count, 1)
        return try VolumeLoader.load(series[0])
    }

    // MARK: DICOM + geometry

    func testRoundTripAllPlanesAndEncodings() throws {
        for plane in Phantom.Plane.allCases {
            for enc in [Phantom.Encoding.explicitLE, .implicitLE, .jpeg2000Lossless] {
                let v = try loadPhantom(plane, enc)
                // Every voxel must equal the analytic phantom at its patient position (noise = 0, lossless).
                var mismatches = 0
                for z in stride(from: 0, to: v.nz, by: 3) { for y in stride(from: 0, to: v.ny, by: 3) { for x in stride(from: 0, to: v.nx, by: 3) {
                    let p = v.patient(SIMD3(Double(x), Double(y), Double(z)))
                    if abs(v.value(x, y, z) - Phantom.intensity(p)) > 0.5 { mismatches += 1 }
                } } }
                XCTAssertEqual(mismatches, 0, "\(plane) \(enc)")
                XCTAssertTrue(v.warnings.isEmpty, "\(v.warnings)")
                XCTAssertEqual(v.handedness, 1)
            }
        }
    }

    func testSlicesSortedGeometricallyNotByInstanceOrName() throws {
        let dir = tmp.appendingPathComponent("sorted")
        try Phantom.write(to: dir, plane: .axial)
        let s = try SeriesScanner.scan(directory: dir)[0]
        let heights = s.slices.map { simd_dot($0.position, s.normal) }
        XCTAssertEqual(heights, heights.sorted())
        XCTAssertEqual(s.acquisitionPlane, "axial")
    }

    func testJPEG2000LosslessRoundTrip() throws {
        var rng = SplitMix(seed: 7)
        let w = 37, h = 23
        let px = (0 ..< w * h).map { _ in Int32(rng.next() % 4096) }
        let cs = try JPEG2000.encodeLossless(px, width: w, height: h, precision: 12)
        let img = try JPEG2000.decode(cs)
        XCTAssertEqual(img.width, w)
        XCTAssertEqual(img.height, h)
        XCTAssertEqual(img.precision, 12)
        XCTAssertEqual(img.samples, px)
    }

    // MARK: viewing orientation

    func testRadiologicalOrientationForEveryAcquisitionPlane() throws {
        // The marker sits in the patient's LEFT, ANTERIOR, SUPERIOR brain.
        for plane in Phantom.Plane.allCases {
            let v = try loadPhantom(plane)
            let r = Reslicer(v)
            let mv = v.voxel(Phantom.markerCenter)
            let cursor = [Int(mv.x.rounded()), Int(mv.y.rounded()), Int(mv.z.rounded())]
            XCTAssertGreaterThan(v.value(cursor[0], cursor[1], cursor[2]), 1100, "\(plane): marker voxel")
            for view in ViewPlane.allCases {
                let p = r.screen(for: view, cursor: cursor)
                let sl = r.slice(view, index: p.slice)
                XCTAssertGreaterThan(sl.pixels[p.y * sl.width + p.x], 1100, "\(plane)/\(view): cursor mapping")
                let rightHalf = p.x > sl.width / 2, topHalf = p.y < sl.height / 2
                switch view {
                case .axial: XCTAssertTrue(rightHalf && topHalf, "\(plane)/axial: L on screen-right, A at top")
                case .coronal: XCTAssertTrue(rightHalf && topHalf, "\(plane)/coronal: L on screen-right, S at top")
                case .sagittal: XCTAssertTrue(!rightHalf && topHalf, "\(plane)/sagittal: A on screen-left, S at top")
                }
                // Screen → voxel inverts voxel → screen.
                XCTAssertEqual(r.voxel(for: view, x: p.x, y: p.y, cursor: cursor), cursor)
            }
        }
    }

    // MARK: filters

    func testDistanceTransformMatchesBruteForce() {
        let g = Grid(nx: 9, ny: 7, nz: 5, sx: 0.7, sy: 1.1, sz: 2.0)
        var rng = SplitMix(seed: 3)
        let mask = (0 ..< g.count).map { _ in UInt8(rng.next() % 9 == 0 ? 1 : 0) }
        let d = Filters.distanceSquared(mask, g, to: 1, outsideIsTarget: false)
        for z in 0 ..< g.nz { for y in 0 ..< g.ny { for x in 0 ..< g.nx {
            var best = Double.greatestFiniteMagnitude
            for zz in 0 ..< g.nz { for yy in 0 ..< g.ny { for xx in 0 ..< g.nx where mask[g.index(xx, yy, zz)] == 1 {
                let dx = Double(x - xx) * g.sx, dy = Double(y - yy) * g.sy, dz = Double(z - zz) * g.sz
                best = min(best, dx * dx + dy * dy + dz * dz)
            } } }
            XCTAssertEqual(Double(d[g.index(x, y, z)]), best, accuracy: 1e-3)
        } } }
    }

    func testFillHolesAndComponents() {
        let g = Grid(nx: 7, ny: 7, nz: 7)
        var m = [UInt8](repeating: 0, count: g.count)
        for z in 1 ... 5 { for y in 1 ... 5 { for x in 1 ... 5 { m[g.index(x, y, z)] = 1 } } }
        m[g.index(3, 3, 3)] = 0                      // enclosed cavity
        let filled = Filters.fillHoles(m, g)
        XCTAssertEqual(Filters.count(filled), 125)
        m[g.index(0, 0, 0)] = 1                      // separate speck
        XCTAssertEqual(Filters.components(m, g).sizes.count - 1, 2)
        XCTAssertEqual(Filters.count(Filters.largestComponent(m, g)), 124)
    }

    // MARK: meshing

    func sphereField(_ n: Int, radius: Double) -> ([Float], Grid) {
        let g = Grid(nx: n, ny: n, nz: n)
        let c = Double(n - 1) / 2
        var f = [Float](repeating: 0, count: g.count)
        for z in 0 ..< n { for y in 0 ..< n { for x in 0 ..< n {
            let r = simd_length(SIMD3(Double(x) - c, Double(y) - c, Double(z) - c))
            f[g.index(x, y, z)] = Float(radius - r)
        } } }
        return (f, g)
    }

    func testSphereMeshIsWatertightAndAccurate() {
        let (f, g) = sphereField(40, radius: 15)
        let m = Isosurface.extract(f, g, iso: 0, toPatient: { $0 })
        let r = MeshReport.analyze(m)
        XCTAssertTrue(r.isWatertight, r.description)
        XCTAssertEqual(r.components, 1)
        XCTAssertEqual(r.eulerCharacteristic, 2)
        XCTAssertEqual(r.volumeMM3, 4.0 / 3.0 * .pi * 15 * 15 * 15, accuracy: 0.02 * 14137)
        XCTAssertGreaterThan(r.volumeMM3, 0, "normals must face outward")
    }

    func testMirroredGeometryKeepsOutwardNormals() {
        let (f, g) = sphereField(20, radius: 6)
        let mirrored = Isosurface.extract(f, g, iso: 0, toPatient: { SIMD3(-$0.x, $0.y, $0.z) }, flipWinding: true)
        XCTAssertGreaterThan(MeshReport.analyze(mirrored).volumeMM3, 0)
    }

    func testSurfaceTouchingGridBorderIsClosed() {
        let g = Grid(nx: 6, ny: 6, nz: 6)
        let f = [Float](repeating: 1, count: g.count)  // everything inside
        let r = MeshReport.analyze(Isosurface.extract(f, g, iso: 0.5, toPatient: { $0 }))
        XCTAssertTrue(r.isWatertight, r.description)
        XCTAssertEqual(r.eulerCharacteristic, 2)
    }

    func testTaubinSmoothingKeepsVolumeAndTopology() {
        let (f, g) = sphereField(30, radius: 10)
        var m = Isosurface.extract(f, g, iso: 0, toPatient: { $0 })
        let before = MeshReport.analyze(m)
        MeshOps.taubinSmooth(&m, iterations: 20)
        let after = MeshReport.analyze(m)
        XCTAssertTrue(after.isWatertight)
        XCTAssertEqual(after.volumeMM3, before.volumeMM3, accuracy: before.volumeMM3 * 0.02)
    }

    func testSTLRoundTrip() throws {
        let (f, g) = sphereField(16, radius: 5)
        let m = Isosurface.extract(f, g, iso: 0, toPatient: { $0 })
        let url = tmp.appendingPathComponent("s.stl")
        try STL.write(m, to: url)
        let back = try STL.read(url)
        XCTAssertEqual(back.triangleCount, m.triangleCount)
        XCTAssertTrue(MeshReport.analyze(back).isWatertight)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        XCTAssertEqual(size, 84 + 50 * m.triangleCount)
    }

    // MARK: end-to-end model building on the phantom

    func expectedPhantomBrainML() -> Double {
        var n = 0
        for x in stride(from: -80.0, through: 80, by: 1) { for y in stride(from: -100.0, through: 100, by: 1) {
            for z in stride(from: -60.0, through: 90, by: 1) where Phantom.isBrain(SIMD3(x, y, z)) { n += 1 }
        } }
        return Double(n) / 1000
    }

    func testBrainModelOnNoisyPhantom() throws {
        let v = try loadPhantom(.sagittal, .jpeg2000Lossless, noise: 25)
        let r = ModelBuilder.build(v, options: ModelOptions())
        let expected = expectedPhantomBrainML()
        XCTAssertTrue(r.report.isWatertight, r.report.description)
        XCTAssertEqual(r.report.components, 1)
        XCTAssertEqual(r.maskVolumeML ?? 0, expected, accuracy: expected * 0.05, r.log.joined(separator: "\n"))
        XCTAssertEqual(r.report.volumeMM3 / 1000, expected, accuracy: expected * 0.05)
        // Print frame: sits on z = 0.
        XCTAssertEqual(MeshOps.bounds(r.mesh)!.min.z, 0, accuracy: 1e-3)
    }

    func testHeadModelOnPhantom() throws {
        let v = try loadPhantom(.axial)
        var o = ModelOptions()
        o.mode = .head
        let r = ModelBuilder.build(v, options: o)
        XCTAssertTrue(r.report.isWatertight, r.report.description)
        XCTAssertGreaterThan(r.report.volumeMM3 / 1000, expectedPhantomBrainML() * 1.5)
    }

    func testSeriesInfoCarriesNoPatientIdentifiers() throws {
        let dir = tmp.appendingPathComponent("phi")
        try Phantom.write(to: dir, plane: .axial)
        let s = try SeriesScanner.scan(directory: dir)[0]
        let dump = String(describing: s)
        XCTAssertFalse(dump.contains("PHANTOM^SYNTHETIC"))
        XCTAssertFalse(dump.contains("PHANTOM-ID-0001"))
    }
}
