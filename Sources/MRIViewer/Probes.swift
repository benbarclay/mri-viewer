import AppKit
import Foundation
import ImageIO
import MRICore
import SceneKit
import UniformTypeIdentifiers

/// Headless and in-app verification probes. They print numbers, never patient data.
enum Probes {
    /// `MRIViewer --render-check <dicom-dir> <out-dir> [--allow-non-phantom]`
    /// Renders the three anatomical planes through the volume centre to PNGs using the app's renderer.
    /// Refuses non-phantom data unless explicitly allowed, so screenshots for docs can't leak a real scan.
    static func renderCheck(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--render-check"), i + 2 < args.count else {
            print("usage: MRIViewer --render-check <dicom-dir> <out-dir>")
            return 2
        }
        let dir = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
        do {
            let series = try SeriesScanner.scan(directory: dir)
            guard let s = series.max(by: { $0.slices.count < $1.slices.count }) else { print("no series"); return 1 }
            guard s.description.hasPrefix("PHANTOM") || args.contains("--allow-non-phantom") else {
                print("refusing: not a synthetic phantom series (pass --allow-non-phantom to override)")
                return 3
            }
            let v = try VolumeLoader.load(s)
            let r = Reslicer(v)
            let p = v.percentiles([0.5, 99.5])
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let mv = v.voxel(Phantom.markerCenter)
            let cursor = [Int(mv.x.rounded()), Int(mv.y.rounded()), Int(mv.z.rounded())]
            for plane in ViewPlane.allCases {
                let idx = r.screen(for: plane, cursor: cursor).slice
                let sl = r.slice(plane, index: idx)
                guard let img = SliceRenderer.image(sl, center: (p[0] + p[1]) / 2, width: p[1] - p[0]) else { return 1 }
                let url = out.appendingPathComponent("\(plane.rawValue).png")
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return 1 }
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
                print("\(plane.rawValue): \(sl.width)x\(sl.height) px, \(String(format: "%.2fx%.2f", sl.pixelWidthMM, sl.pixelHeightMM)) mm/px → \(url.lastPathComponent)")
            }
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }
}

extension Probes {
    /// `MRIViewer --render-kit <phantom-dir> <labels> <out.png> [--explode 0.6]` — offscreen render of the
    /// kit preview scene (phantom only), to check the 3D preview without a window.
    static func renderKit(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--render-kit"), i + 3 < args.count else { print("usage: --render-kit <dir> <labels> <out.png>"); return 2 }
        do {
            let s = try SeriesScanner.scan(directory: URL(fileURLWithPath: args[i + 1]))[0]
            guard s.description.hasPrefix("PHANTOM") || args.contains("--allow-non-phantom") else {
                print("refusing: not a synthetic phantom series"); return 3
            }
            let v = try VolumeLoader.load(s)
            let labels = try LabelVolume.read(URL(fileURLWithPath: args[i + 2])).resampled(onto: v)
            let kit = PrintKit.build(v, labels: labels, options: KitOptions())
            let explode = args.firstIndex(of: "--explode").flatMap { Double(args[$0 + 1]) } ?? 0.6
            let scene = KitScene.build(kit)
            KitScene.apply(scene, explode: explode, showHead: true)
            let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            r.scene = scene.scene
            r.pointOfView = scene.scene.rootNode.childNodes.first { $0.camera != nil }
            let img = r.snapshot(atTime: 0, with: CGSize(width: 1200, height: 900), antialiasingMode: .multisampling4X)
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return 1 }
            try png.write(to: URL(fileURLWithPath: args[i + 3]))
            print("rendered \(kit.parts.count) parts → \(args[i + 3])")
            return 0
        } catch { print("error: \(error)"); return 1 }
    }
}

/// In-app probe (`--open <dir> --probe`): waits for the real store to load, drives slice stepping and
/// model building through the same code paths as the UI, prints the results and exits.
@MainActor
enum UIProbe {
    static var timer: Timer?
    static var phase = 0
    static var started = Date()

    static func start(_ store: ViewerStore) {
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { tick(store) }
        }
    }

    static func finish(_ code: Int32, _ msg: String) -> Never {
        print(msg)
        timer?.invalidate()
        exit(code)
    }

    static func tick(_ store: ViewerStore) {
        if Date().timeIntervalSince(started) > 180 { finish(1, "WARN probe timed out in phase \(phase)") }
        if let e = store.errorText { finish(1, "WARN error: \(e)") }
        switch phase {
        case 0:
            guard let v = store.volume, let r = store.reslicer else { return }
            print("probe: series=\(store.series.count) volume=\(v.nx)x\(v.ny)x\(v.nz) slices axial=\(r.sliceCount(.axial)) coronal=\(r.sliceCount(.coronal)) sagittal=\(r.sliceCount(.sagittal))")
            let before = store.cursor
            store.step(.axial, by: 5)
            let moved = zip(before, store.cursor).filter { $0 != $1 }.count
            print("probe: axial step moved \(moved) cursor axis (expect 1)")
            for plane in ViewPlane.allCases {
                guard let (img, _) = store.image(for: plane) else { finish(1, "WARN no image for \(plane)") }
                print("probe: \(plane.rawValue) image \(img.width)x\(img.height)")
            }
            print(String(format: "probe: auto threshold %.1f", store.effectiveThreshold))
            store.buildModel()
            phase = 1
        case 1:
            guard let m = store.model, !store.isBuilding else { return }
            print("probe: model \(m.report.description.replacingOccurrences(of: "\n", with: " | "))")
            let overlayOK = store.overlay == .model && m.mask != nil
            print("probe: model overlay active: \(overlayOK)")
            finish(m.report.isWatertight ? 0 : 1, "probe: done in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        default:
            break
        }
    }
}

/// `--open <dir> --labels <file> --kit-probe [--stay]`: loads a label map, builds the print kit through
/// the real store, prints the part summary and exits (or stays open with `--stay`, for screenshots).
@MainActor
enum KitProbe {
    static var timer: Timer?
    static var phase = 0
    static var started = Date()

    static func start(_ store: ViewerStore, labels: String, stay: Bool) {
        started = Date()
        store.panelMode = .kit
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { tick(store, labels: labels, stay: stay) }
        }
    }

    static func tick(_ store: ViewerStore, labels: String, stay: Bool) {
        if Date().timeIntervalSince(started) > 300 { print("WARN kit probe timed out in phase \(phase)"); exit(1) }
        if let e = store.errorText { print("WARN error: \(e)"); exit(1) }
        switch phase {
        case 0:
            guard store.volume != nil else { return }
            store.loadLabels(URL(fileURLWithPath: labels), source: "probe")
            phase = 1
        case 1:
            guard store.labels != nil, store.regionMap != nil else { return }
            let regions = Set(store.regionMap!.filter { $0 != 0 })
            print("kit probe: labels loaded, \(regions.count) regions on the overlay")
            store.buildKit()
            phase = 2
        case 2:
            guard let k = store.kit, !store.isBuildingKit else { return }
            for p in k.parts {
                print(String(format: "kit probe: %@ %.0f mL watertight %@", p.name, p.report.volumeMM3 / 1000, p.report.isWatertight ? "yes" : "NO"))
            }
            timer?.invalidate()
            if stay { store.explode = 0.6; phase = 3; return }
            exit(k.parts.allSatisfy { $0.report.isWatertight } ? 0 : 1)
        default:
            break
        }
    }
}
