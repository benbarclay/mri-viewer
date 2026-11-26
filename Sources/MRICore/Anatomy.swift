import Foundation

/// A printable brain part.
public struct PartSpec: Hashable {
    public let id: Int
    public let name: String
    /// -1 left, +1 right, 0 midline. Unlabelled voxels only inherit parts from the same hemisphere.
    public let hemisphere: Int
    /// RGB 0…1 for previews and coloured exports.
    public let color: SIMD3<Float>
}

/// Maps FreeSurfer `aparc.DKTatlas+aseg` labels (as produced by FastSurfer) to printable parts:
/// four lobes per hemisphere, cerebellum and brainstem, plus optional deep structures.
///
/// Label numbers follow FreeSurferColorLUT.txt: cortical DKT parcels are 1000 + index (left) and
/// 2000 + index (right); subcortical structures use the aseg numbers.
public enum Anatomy {
    public static let frontal = [2, 3, 12, 14, 17, 18, 19, 20, 24, 26, 27, 28, 32]   // incl. anterior cingulate
    public static let parietal = [8, 10, 22, 23, 25, 29, 31]                         // incl. posterior/isthmus cingulate
    public static let temporal = [6, 7, 9, 15, 16, 30, 33, 34, 35]                    // incl. insula (35)
    public static let occipital = [5, 11, 13, 21]

    public static func parts(deep: Bool) -> [PartSpec] {
        var p: [PartSpec] = [
            PartSpec(id: 1, name: "left-frontal", hemisphere: -1, color: [0.90, 0.45, 0.40]),
            PartSpec(id: 2, name: "left-parietal", hemisphere: -1, color: [0.40, 0.65, 0.90]),
            PartSpec(id: 3, name: "left-temporal", hemisphere: -1, color: [0.45, 0.80, 0.45]),
            PartSpec(id: 4, name: "left-occipital", hemisphere: -1, color: [0.95, 0.80, 0.35]),
            PartSpec(id: 5, name: "right-frontal", hemisphere: 1, color: [0.80, 0.35, 0.32]),
            PartSpec(id: 6, name: "right-parietal", hemisphere: 1, color: [0.32, 0.55, 0.80]),
            PartSpec(id: 7, name: "right-temporal", hemisphere: 1, color: [0.36, 0.70, 0.36]),
            PartSpec(id: 8, name: "right-occipital", hemisphere: 1, color: [0.85, 0.70, 0.28]),
            PartSpec(id: 9, name: "cerebellum", hemisphere: 0, color: [0.75, 0.55, 0.85]),
            PartSpec(id: 10, name: "brainstem", hemisphere: 0, color: [0.65, 0.65, 0.65]),
        ]
        if deep {
            p += [
                PartSpec(id: 11, name: "left-deep-nuclei", hemisphere: -1, color: [0.95, 0.60, 0.75]),
                PartSpec(id: 12, name: "right-deep-nuclei", hemisphere: 1, color: [0.85, 0.50, 0.65]),
                PartSpec(id: 13, name: "left-hippocampus-amygdala", hemisphere: -1, color: [0.50, 0.85, 0.85]),
                PartSpec(id: 14, name: "right-hippocampus-amygdala", hemisphere: 1, color: [0.40, 0.75, 0.75]),
                PartSpec(id: 15, name: "ventricles", hemisphere: 0, color: [0.55, 0.75, 1.00]),
            ]
        }
        return p
    }

    /// Part id for a label (0 = not directly assigned; such voxels inherit from their neighbours).
    public static func part(for label: Int32, deep: Bool) -> Int {
        let l = Int(label)
        if (1000 ..< 1100).contains(l) || (2000 ..< 2100).contains(l) {
            let idx = l % 1000, base = l >= 2000 ? 4 : 0
            if frontal.contains(idx) { return base + 1 }
            if parietal.contains(idx) { return base + 2 }
            if temporal.contains(idx) { return base + 3 }
            if occipital.contains(idx) { return base + 4 }
            return 0
        }
        switch l {
        case 7, 8, 46, 47: return 9                          // cerebellar cortex + white matter
        case 16, 28, 60: return 10                           // brainstem (+ ventral diencephalon)
        default: break
        }
        guard deep else { return 0 }
        switch l {
        case 10, 11, 12, 13, 26: return 11                   // L thalamus, caudate, putamen, pallidum, accumbens
        case 49, 50, 51, 52, 58: return 12
        case 17, 18: return 13                               // L hippocampus, amygdala
        case 53, 54: return 14
        case 4, 5, 14, 15, 43, 44, 72: return 15             // lateral, inf-lat, 3rd, 4th, 5th ventricles
        default: return 0
        }
    }

    /// Whether a label is brain tissue (incl. ventricles, which are filled for printing).
    public static func isBrain(_ label: Int32) -> Bool {
        let l = Int(label)
        if l == 0 || l == 24 { return false }               // background, extra-cerebral CSF
        if (1000 ..< 1100).contains(l) || (2000 ..< 2100).contains(l) { return true }
        return [2, 4, 5, 7, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18, 26, 28, 30, 31, 41, 43, 44, 46, 47, 49, 50,
                51, 52, 53, 54, 58, 60, 62, 63, 72, 77, 85, 251, 252, 253, 254, 255].contains(l)
    }

    /// -1 left, +1 right, 0 midline/unknown — used to stop left white matter joining right lobes.
    public static func hemisphere(of label: Int32) -> Int {
        let l = Int(label)
        if (1000 ..< 1100).contains(l) { return -1 }
        if (2000 ..< 2100).contains(l) { return 1 }
        if [2, 4, 5, 7, 8, 10, 11, 12, 13, 17, 18, 26, 28, 30, 31].contains(l) { return -1 }
        if [41, 43, 44, 46, 47, 49, 50, 51, 52, 53, 54, 58, 60, 62, 63].contains(l) { return 1 }
        return 0
    }
}
