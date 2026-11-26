import Foundation
import simd

/// Anatomical viewing planes, shown in radiological convention:
/// axial & coronal have the patient's RIGHT on screen-left; sagittal has ANTERIOR on screen-left;
/// superior / anterior at the top.
public enum ViewPlane: String, CaseIterable, Identifiable {
    case axial, coronal, sagittal
    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    /// Patient axes (LPS index 0=L, 1=P, 2=S) and directions for screen-right, screen-down and the plane normal.
    var screen: (right: (axis: Int, sign: Int), down: (axis: Int, sign: Int), normal: Int) {
        switch self {
        case .axial: return ((0, +1), (1, +1), 2)           // right→ +L ; down → +P (anterior at top)
        case .coronal: return ((0, +1), (2, -1), 1)         // right→ +L ; down → −S
        case .sagittal: return ((1, +1), (2, -1), 0)        // right→ +P (anterior on the left) ; down → −S
        }
    }

    /// Orientation letters at the screen edges (left, right, top, bottom).
    public var edgeLabels: (left: String, right: String, top: String, bottom: String) {
        switch self {
        case .axial: return ("R", "L", "A", "P")
        case .coronal: return ("R", "L", "S", "I")
        case .sagittal: return ("A", "P", "S", "I")
        }
    }
}

/// Maps each anatomical patient axis to the voxel axis closest to it. Exact for orthogonal
/// acquisitions; for oblique ones it shows the nearest native plane (no interpolation).
public struct AnatomicalFrame {
    /// voxelAxis[p] = voxel axis (0=x,1=y,2=z) most aligned with patient axis p (L,P,S).
    public let voxelAxis: [Int]
    /// sign[p] = +1 when increasing the voxel index moves toward +p (L, P or S).
    public let sign: [Int]

    public init(_ v: Volume) {
        // Greedy assignment by largest absolute cosine, so every patient axis gets a distinct voxel axis.
        var pairs: [(Double, Int, Int)] = []
        for a in 0 ..< 3 { for p in 0 ..< 3 { pairs.append((abs(v.axes[a][p]), a, p)) } }
        pairs.sort { $0.0 > $1.0 }
        var axisFor = [-1, -1, -1], used = Set<Int>()
        var sgn = [1, 1, 1]
        for (_, a, p) in pairs where axisFor[p] < 0 && !used.contains(a) {
            axisFor[p] = a; used.insert(a)
            sgn[p] = v.axes[a][p] >= 0 ? 1 : -1
        }
        voxelAxis = axisFor
        sign = sgn
    }
}

/// A 2D cut through the volume, ready to display.
public struct Slice2D {
    public let width: Int
    public let height: Int
    public let pixels: [Float]
    /// Physical size of one pixel (mm) horizontally / vertically — use for the display aspect ratio.
    public let pixelWidthMM: Double
    public let pixelHeightMM: Double
}

public struct Reslicer {
    public let volume: Volume
    public let frame: AnatomicalFrame

    public init(_ v: Volume) { volume = v; frame = AnatomicalFrame(v) }

    func dim(_ a: Int) -> Int { volume.dims[a] }
    func spacing(_ a: Int) -> Double { [volume.spacing.x, volume.spacing.y, volume.spacing.z][a] }

    /// Voxel axes for (screen-x, screen-y, normal) and whether each runs reversed.
    public func axes(_ plane: ViewPlane) -> (u: Int, uFlip: Bool, v: Int, vFlip: Bool, n: Int) {
        let s = plane.screen
        let u = frame.voxelAxis[s.right.axis], v = frame.voxelAxis[s.down.axis], n = frame.voxelAxis[s.normal]
        let uFlip = frame.sign[s.right.axis] != s.right.sign
        let vFlip = frame.sign[s.down.axis] != s.down.sign
        return (u, uFlip, v, vFlip, n)
    }

    /// Number of slices available for a plane.
    public func sliceCount(_ plane: ViewPlane) -> Int { dim(axes(plane).n) }

    /// Extracts the slice at voxel index `index` along the plane normal (optionally of another field on the same grid).
    public func slice(_ plane: ViewPlane, index: Int, field: [Float]? = nil) -> Slice2D {
        let a = axes(plane)
        let w = dim(a.u), h = dim(a.v)
        let k = min(max(0, index), dim(a.n) - 1)
        let src = field ?? volume.data
        var out = [Float](repeating: 0, count: w * h)
        var c = [0, 0, 0]
        c[a.n] = k
        for y in 0 ..< h {
            c[a.v] = a.vFlip ? h - 1 - y : y
            for x in 0 ..< w {
                c[a.u] = a.uFlip ? w - 1 - x : x
                out[y * w + x] = src[volume.index(c[0], c[1], c[2])]
            }
        }
        return Slice2D(width: w, height: h, pixels: out, pixelWidthMM: spacing(a.u), pixelHeightMM: spacing(a.v))
    }

    /// Same as `slice` for a UInt8 mask.
    public func maskSlice(_ plane: ViewPlane, index: Int, mask: [UInt8]) -> [UInt8] {
        let a = axes(plane)
        let w = dim(a.u), h = dim(a.v)
        let k = min(max(0, index), dim(a.n) - 1)
        var out = [UInt8](repeating: 0, count: w * h)
        var c = [0, 0, 0]
        c[a.n] = k
        for y in 0 ..< h {
            c[a.v] = a.vFlip ? h - 1 - y : y
            for x in 0 ..< w {
                c[a.u] = a.uFlip ? w - 1 - x : x
                out[y * w + x] = mask[volume.index(c[0], c[1], c[2])]
            }
        }
        return out
    }

    /// Converts a screen pixel in a plane into a full voxel coordinate (other axis from `cursor`).
    public func voxel(for plane: ViewPlane, x: Int, y: Int, cursor: [Int]) -> [Int] {
        let a = axes(plane)
        var c = cursor
        c[a.u] = a.uFlip ? dim(a.u) - 1 - x : x
        c[a.v] = a.vFlip ? dim(a.v) - 1 - y : y
        return (0 ..< 3).map { min(max(0, c[$0]), dim($0) - 1) }
    }

    /// Screen position of the cursor in a plane plus the slice index it implies.
    public func screen(for plane: ViewPlane, cursor: [Int]) -> (x: Int, y: Int, slice: Int) {
        let a = axes(plane)
        let x = a.uFlip ? dim(a.u) - 1 - cursor[a.u] : cursor[a.u]
        let y = a.vFlip ? dim(a.v) - 1 - cursor[a.v] : cursor[a.v]
        return (x, y, cursor[a.n])
    }
}
