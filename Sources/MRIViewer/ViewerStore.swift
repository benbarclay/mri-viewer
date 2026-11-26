import AppKit
import Foundation
import MRICore
import SwiftUI

enum OverlayMode: String, CaseIterable, Identifiable {
    case none, threshold, model
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .threshold: return "Threshold"
        case .model: return "Model mask"
        }
    }
}

/// App state. Holds the loaded volume and everything the views project from it.
/// Patient-identifying DICOM fields are never read, so nothing here can display them.
@MainActor
final class ViewerStore: ObservableObject {
    @Published var folder: URL?
    @Published var series: [SeriesInfo] = []
    @Published var selectedSeriesID: SeriesInfo.ID?
    @Published private(set) var volume: Volume?
    @Published private(set) var reslicer: Reslicer?
    @Published var cursor: [Int] = [0, 0, 0]
    @Published var windowCenter: Float = 0
    @Published var windowWidth: Float = 1
    @Published var status: String = ""
    @Published var errorText: String?
    @Published var isBusy = false
    @Published var progress: Double?

    // 3D model
    @Published var options = ModelOptions()
    @Published var autoThresholdValue: Float?
    @Published var overlay: OverlayMode = .threshold
    @Published private(set) var model: ModelResult?
    @Published private(set) var modelVersion = 0
    @Published var modelLog: [String] = []
    @Published var isBuilding = false
    @Published var showInspector = true
    /// Bumped whenever slice images must be re-rendered.
    @Published private(set) var renderToken = 0

    private var intensityRange: (Float, Float) = (0, 1)

    var selectedSeries: SeriesInfo? { series.first { $0.id == selectedSeriesID } }
    var effectiveThreshold: Float { options.threshold ?? autoThresholdValue ?? 0 }
    var thresholdRange: ClosedRange<Float> { intensityRange.0 ... max(intensityRange.0 + 1, intensityRange.1) }

    // MARK: loading

    func openPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Open"
        p.message = "Choose a folder containing DICOM files (subfolders are searched)."
        if p.runModal() == .OK, let url = p.url { open(folder: url) }
    }

    func open(folder url: URL) {
        folder = url
        series = []
        volume = nil
        reslicer = nil
        model = nil
        errorText = nil
        isBusy = true
        status = "Scanning…"
        UserDefaults.standard.set(url.path, forKey: "lastFolder")
        Task.detached(priority: .userInitiated) {
            do {
                let found = try SeriesScanner.scan(directory: url) { done, total in
                    Task { @MainActor in self.progress = Double(done) / Double(max(1, total)) }
                }
                await MainActor.run {
                    self.series = found
                    self.isBusy = false
                    self.progress = nil
                    if found.isEmpty {
                        self.errorText = "No DICOM images found in this folder."
                        self.status = ""
                    } else {
                        // Default: the largest volumetric stack (usually the 3D T1).
                        let best = found.max { $0.rows * $0.columns * $0.slices.count < $1.rows * $1.columns * $1.slices.count }
                        self.select(best?.id)
                    }
                }
            } catch {
                await MainActor.run { self.errorText = "\(error)"; self.isBusy = false; self.progress = nil }
            }
        }
    }

    func select(_ id: SeriesInfo.ID?) {
        guard let id, id != selectedSeriesID || volume == nil, let s = series.first(where: { $0.id == id }) else {
            selectedSeriesID = id
            return
        }
        selectedSeriesID = id
        model = nil
        modelLog = []
        isBusy = true
        status = "Loading \(s.slices.count) slices…"
        Task.detached(priority: .userInitiated) {
            do {
                let v = try VolumeLoader.load(s) { done, total in
                    Task { @MainActor in self.progress = Double(done) / Double(max(1, total)) }
                }
                let p = v.percentiles([0.5, 99.5])
                let st = v.stats()
                let auto = ModelBuilder.autoThreshold(v, mode: .brain)
                await MainActor.run {
                    guard self.selectedSeriesID == id else { return }
                    self.volume = v
                    self.reslicer = Reslicer(v)
                    self.cursor = [v.nx / 2, v.ny / 2, v.nz / 2]
                    self.intensityRange = (st.min, st.max)
                    self.windowCenter = (p[0] + p[1]) / 2
                    self.windowWidth = max(1, p[1] - p[0])
                    self.autoThresholds = auto
                    self.autoThresholdValue = self.options.mode == .brain ? auto.brain : auto.head
                    self.isBusy = false
                    self.progress = nil
                    self.status = v.warnings.joined(separator: "; ")
                    self.renderToken += 1
                }
            } catch {
                await MainActor.run { self.errorText = "Could not load series: \(error)"; self.isBusy = false; self.progress = nil }
            }
        }
    }

    private var autoThresholds: (head: Float, brain: Float)?

    func modeChanged() {
        if let a = autoThresholds { autoThresholdValue = options.mode == .brain ? a.brain : a.head }
        invalidate()
    }

    func invalidate() { renderToken += 1 }

    func resetWindow() {
        guard let v = volume else { return }
        let p = v.percentiles([0.5, 99.5])
        windowCenter = (p[0] + p[1]) / 2
        windowWidth = max(1, p[1] - p[0])
        invalidate()
    }

    // MARK: interaction

    func setCursor(_ c: [Int]) {
        guard c != cursor else { return }
        cursor = c
        invalidate()
    }

    func step(_ plane: ViewPlane, by delta: Int) {
        guard let r = reslicer else { return }
        let a = r.axes(plane)
        var c = cursor
        c[a.n] = min(max(0, c[a.n] + delta), r.sliceCount(plane) - 1)
        setCursor(c)
    }

    func adjustWindow(dx: CGFloat, dy: CGFloat) {
        let scale = max(1, windowWidth) / 300
        windowWidth = max(1, windowWidth + Float(dx) * scale)
        windowCenter += Float(-dy) * scale
        invalidate()
    }

    // MARK: rendering

    func image(for plane: ViewPlane) -> (CGImage, Slice2D)? {
        guard let r = reslicer else { return nil }
        let p = r.screen(for: plane, cursor: cursor)
        let sl = r.slice(plane, index: p.slice)
        var overlayMask: [UInt8]?
        switch overlay {
        case .none:
            break
        case .threshold:
            if showInspector {
                let t = effectiveThreshold
                overlayMask = sl.pixels.map { $0 >= t ? 1 : 0 }
            }
        case .model:
            if let m = model, let mask = m.mask, m.volume.nx == r.volume.nx, m.volume.ny == r.volume.ny, m.volume.nz == r.volume.nz {
                overlayMask = r.maskSlice(plane, index: p.slice, mask: mask)
            }
        }
        guard let img = SliceRenderer.image(sl, center: windowCenter, width: windowWidth, overlay: overlayMask) else { return nil }
        return (img, sl)
    }

    // MARK: 3D model

    func buildModel() {
        guard let v = volume, !isBuilding else { return }
        isBuilding = true
        modelLog = []
        var o = options
        if o.threshold == nil { o.threshold = autoThresholdValue }
        Task.detached(priority: .userInitiated) {
            let r = ModelBuilder.build(v, options: o) { line in
                Task { @MainActor in self.modelLog.append(line) }
            }
            await MainActor.run {
                self.model = r
                self.modelVersion += 1
                self.isBuilding = false
                if r.mask != nil { self.overlay = .model }
                self.invalidate()
            }
        }
    }

    func exportSTL() {
        guard let m = model else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.init(filenameExtension: "stl")!]
        p.nameFieldStringValue = "\(options.mode.rawValue).stl"
        p.message = "Binary STL in millimetres, sitting on z = 0."
        if p.runModal() == .OK, let url = p.url {
            do {
                try STL.write(m.mesh, to: url)
                status = "Exported \(m.mesh.triangleCount) triangles to \(url.lastPathComponent)"
            } catch {
                errorText = "Export failed: \(error)"
            }
        }
    }
}
