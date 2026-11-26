import Foundation
import simd

/// One image file that belongs to a series stack. Holds geometry only.
public struct SliceRef {
    public let url: URL
    public let instanceNumber: Int
    public let position: SIMD3<Double>
}

/// A stack of parallel same-sized slices that can be assembled into a volume.
///
/// Deliberately exposes only technical acquisition metadata — no patient, study date,
/// institution or operator fields are ever read into this type.
public struct SeriesInfo: Identifiable, Hashable {
    public let id: String
    public let seriesNumber: Int
    public let description: String
    public let modality: String
    public let rows: Int
    public let columns: Int
    public let pixelSpacing: SIMD2<Double>     // (row spacing, column spacing) in mm
    public let sliceThickness: Double?
    public let rowDirection: SIMD3<Double>
    public let columnDirection: SIMD3<Double>
    public let transferSyntax: String
    public internal(set) var slices: [SliceRef]

    public static func == (a: SeriesInfo, b: SeriesInfo) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    public var normal: SIMD3<Double> { simd_normalize(simd_cross(rowDirection, columnDirection)) }

    /// Plane the slices were acquired in, judged from the slice normal.
    public var acquisitionPlane: String {
        let n = simd_abs(normal)
        if n.z >= n.x && n.z >= n.y { return "axial" }
        if n.y >= n.x { return "coronal" }
        return "sagittal"
    }

    /// Suitable for a 3D volume: enough slices to make a block.
    public var isVolumetric: Bool { slices.count >= 8 }

    public var summary: String {
        let d = description.isEmpty ? "(no description)" : description
        return "#\(seriesNumber) \(d)"
    }
}

public enum SeriesScanner {
    /// Recursively scans a directory for DICOM image files and groups them into stacks.
    /// `progress` receives (done, total).
    public static func scan(directory: URL, progress: ((Int, Int) -> Void)? = nil) throws -> [SeriesInfo] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var urls: [URL] = []
        for case let u as URL in en {
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { urls.append(u) }
        }
        return scan(files: urls, progress: progress)
    }

    struct Header {
        let url: URL
        let seriesUID: String
        let seriesNumber: Int
        let description: String
        let modality: String
        let rows: Int, columns: Int
        let spacing: SIMD2<Double>
        let thickness: Double?
        let orientation: [Double]
        let position: SIMD3<Double>
        let instance: Int
        let ts: String
    }

    public static func scan(files urls: [URL], progress: ((Int, Int) -> Void)? = nil) -> [SeriesInfo] {
        var headers = [Header?](repeating: nil, count: urls.count)
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            let h = readHeader(urls[i])
            lock.lock()
            headers[i] = h
            done += 1
            let d = done
            lock.unlock()
            if d % 25 == 0 || d == urls.count { progress?(d, urls.count) }
        }
        // Group by series, then by orientation + size (a series can hold several stacks, e.g. localizers).
        var groups: [String: [Header]] = [:]
        var order: [String] = []
        for h in headers.compactMap({ $0 }) {
            let o = h.orientation.map { String(format: "%.3f", $0) }.joined(separator: ",")
            let key = "\(h.seriesUID)|\(o)|\(h.rows)x\(h.columns)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(h)
        }
        var result: [SeriesInfo] = []
        for key in order {
            guard let hs = groups[key], let f = hs.first else { continue }
            let row = SIMD3(f.orientation[0], f.orientation[1], f.orientation[2])
            let col = SIMD3(f.orientation[3], f.orientation[4], f.orientation[5])
            let normal = simd_normalize(simd_cross(row, col))
            var slices = hs.map { SliceRef(url: $0.url, instanceNumber: $0.instance, position: $0.position) }
            slices.sort { simd_dot($0.position, normal) < simd_dot($1.position, normal) }
            // Drop exact duplicate positions (repeated acquisitions); keep the first.
            var dedup: [SliceRef] = []
            for s in slices {
                if let last = dedup.last, abs(simd_dot(s.position - last.position, normal)) < 1e-4 { continue }
                dedup.append(s)
            }
            result.append(SeriesInfo(
                id: key, seriesNumber: f.seriesNumber, description: f.description, modality: f.modality,
                rows: f.rows, columns: f.columns, pixelSpacing: f.spacing, sliceThickness: f.thickness,
                rowDirection: row, columnDirection: col, transferSyntax: f.ts, slices: dedup))
        }
        result.sort { ($0.seriesNumber, -$0.slices.count) < ($1.seriesNumber, -$1.slices.count) }
        return result
    }

    static func readHeader(_ url: URL) -> Header? {
        guard let f = try? DICOMFile(url: url), f.has(.pixelData),
              let rows = f.uint16(.rows), let cols = f.uint16(.columns) else { return nil }
        let ori = f.doubles(.imageOrientationPatient)
        let pos = f.doubles(.imagePositionPatient)
        let ps = f.doubles(.pixelSpacing)
        let orientation = ori.count == 6 ? ori : [1, 0, 0, 0, 1, 0]
        let position = pos.count == 3 ? SIMD3(pos[0], pos[1], pos[2]) : SIMD3(0, 0, Double(f.int(.instanceNumber) ?? 0))
        return Header(
            url: url,
            seriesUID: f.string(.seriesInstanceUID) ?? "unknown",
            seriesNumber: f.int(.seriesNumber) ?? 0,
            description: f.string(.seriesDescription) ?? "",
            modality: f.string(.modality) ?? "",
            rows: rows, columns: cols,
            spacing: ps.count == 2 ? SIMD2(ps[0], ps[1]) : SIMD2(1, 1),
            thickness: f.double(.sliceThickness),
            orientation: orientation, position: position,
            instance: f.int(.instanceNumber) ?? 0,
            ts: f.transferSyntax)
    }
}
