import Foundation

public enum KitExport {
    /// Writes one binary STL per part plus `kit.txt` (part list, sizes, checks, assembly notes).
    public static func write(_ r: KitResult, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var txt = "MRI print kit — all parts share one coordinate frame (mm). Import every STL together to see\n"
        txt += "the assembly; use your slicer's 'drop to bed' / 'lay on face' per part when printing.\n\n"
        for (k, p) in r.parts.enumerated() {
            let name = String(format: "%02d-%@.stl", k + 1, p.name)
            try STL.write(p.mesh, to: dir.appendingPathComponent(name), header: "mri-viewer \(p.name)")
            txt += String(format: "%@  %@  %.0f x %.0f x %.0f mm  %.1f mL  %d triangles  watertight %@\n",
                          name, p.group, p.report.size.x, p.report.size.y, p.report.size.z,
                          p.report.volumeMM3 / 1000, p.report.triangles, p.report.isWatertight ? "yes" : "NO")
        }
        if let z = r.splitHeightMM { txt += String(format: "\nhead split height (patient S): %.1f mm\n", z) }
        if let u = r.undercutML { txt += String(format: "cavity undercuts: bowl %.1f mL, cap %.1f mL\n", u.lower, u.upper) }
        txt += String(format: "brain part overlap: %.2f mL\n\nlog:\n", r.overlapML)
        txt += r.log.joined(separator: "\n") + "\n"
        try txt.write(to: dir.appendingPathComponent("kit.txt"), atomically: true, encoding: .utf8)
    }
}
