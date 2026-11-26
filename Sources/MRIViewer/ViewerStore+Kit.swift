import AppKit
import CryptoKit
import Foundation
import MRICore
import UniformTypeIdentifiers

/// Print-kit workflow: segmentation (FastSurfer or an imported label map) → kit build → export.
extension ViewerStore {
    /// Where segmentations of a series are cached (outside any repository; local only).
    func segmentationDir() -> URL? {
        guard let s = selectedSeries else { return nil }
        let key = SHA256.hash(data: Data(((folder?.path ?? "") + "|" + s.id).utf8)).map { String(format: "%02x", $0) }.joined()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MRIViewer/segmentations/\(key.prefix(16))")
    }

    static func fastSurferHome() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["FASTSURFER_HOME"], fm.fileExists(atPath: env + "/run_fastsurfer.sh") {
            return URL(fileURLWithPath: env)
        }
        for root in [fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")] {
            let items = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            for name in items.sorted().reversed() where name.hasPrefix("FastSurfer") && !name.hasSuffix(".app") {
                let d = root.appendingPathComponent(name)
                if fm.fileExists(atPath: d.appendingPathComponent("run_fastsurfer.sh").path) { return d }
            }
        }
        return nil
    }

    func loadCachedLabels() {
        guard let dir = segmentationDir() else { return }
        let url = dir.appendingPathComponent("labels.mgz")
        if FileManager.default.fileExists(atPath: url.path) { loadLabels(url, source: "FastSurfer (cached)") }
    }

    func loadLabelsPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["mgz", "mgh", "nii", "gz"].compactMap { UTType(filenameExtension: $0) }
        p.message = "Choose a FreeSurfer/FastSurfer label map (aparc.DKTatlas+aseg .mgz or .nii)."
        if p.runModal() == .OK, let url = p.url { loadLabels(url, source: url.lastPathComponent) }
    }

    func loadLabels(_ url: URL, source: String) {
        guard let v = volume else { return }
        let deep = kitOptions.deepStructures
        Task.detached(priority: .userInitiated) {
            do {
                let lv = try LabelVolume.read(url)
                let lab = lv.resampled(onto: v)
                let regions = PrintKit.regions(v, labels: lab, deep: deep)
                await MainActor.run {
                    self.labels = lab
                    self.regionMap = regions
                    self.labelsSource = source
                    self.overlay = .regions
                    self.invalidate()
                }
            } catch {
                await MainActor.run { self.errorText = "Could not read labels: \(error)" }
            }
        }
    }

    func refreshRegions() {
        guard let v = volume, let lab = labels else { return }
        let deep = kitOptions.deepStructures
        Task.detached {
            let r = PrintKit.regions(v, labels: lab, deep: deep)
            await MainActor.run { self.regionMap = r; self.invalidate() }
        }
    }

    func runFastSurfer() {
        guard let v = volume, let home = Self.fastSurferHome(), let dir = segmentationDir(), !segmentationRunning else { return }
        segmentationRunning = true
        segmentationStarted = Date()
        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let t1 = dir.appendingPathComponent("t1.nii")
                try NIfTI.write(v, to: t1)
                let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let cmd = "source \(q(home.path + "/macos_setup_fastsurfer.sh")) >/dev/null && run_fastsurfer.sh --seg_only --no_cereb --no_hypothal --no_cc --t1 \(q(t1.path)) --sd \(q(dir.path)) --sid fastsurfer > \(q(dir.path + "/fastsurfer.log")) 2>&1"
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = ["-c", cmd]
                try p.run()
                p.waitUntilExit()
                let out = dir.appendingPathComponent("fastsurfer/mri/aparc.DKTatlas+aseg.deep.mgz")
                guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
                    throw DICOMError.decodeFailed("FastSurfer exited with \(p.terminationStatus); log: \(dir.path)/fastsurfer.log")
                }
                let labelsURL = dir.appendingPathComponent("labels.mgz")
                try? FileManager.default.removeItem(at: labelsURL)
                try FileManager.default.copyItem(at: out, to: labelsURL)
                try? FileManager.default.removeItem(at: t1)
                await MainActor.run {
                    self.segmentationRunning = false
                    self.loadLabels(labelsURL, source: "FastSurfer")
                }
            } catch {
                await MainActor.run { self.segmentationRunning = false; self.errorText = "Segmentation failed: \(error)" }
            }
        }
    }

    func buildKit() {
        guard let v = volume, let lab = labels, !isBuildingKit else { return }
        isBuildingKit = true
        kitLog = []
        let o = kitOptions
        Task.detached(priority: .userInitiated) {
            let r = PrintKit.build(v, labels: lab, options: o) { line in
                Task { @MainActor in self.kitLog.append(line) }
            }
            await MainActor.run {
                self.kit = r
                self.kitVersion += 1
                self.isBuildingKit = false
            }
        }
    }

    func exportKit() {
        guard let k = kit else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Export Here"
        p.message = "Choose a folder for the kit's STL files (one per part, plus kit.txt)."
        if p.runModal() == .OK, let url = p.url {
            do {
                try KitExport.write(k, to: url)
                status = "Exported \(k.parts.count) parts to \(url.lastPathComponent)"
            } catch {
                errorText = "Export failed: \(error)"
            }
        }
    }
}
