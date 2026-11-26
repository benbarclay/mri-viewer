import Foundation

/// Errors raised while reading DICOM files. Messages never include element values,
/// so they are safe to print or log (no patient data).
public enum DICOMError: Error, CustomStringConvertible {
    case notDICOM
    case truncated(at: Int)
    case unsupportedTransferSyntax(String)
    case missingElement(String)
    case unsupported(String)
    case decodeFailed(String)

    public var description: String {
        switch self {
        case .notDICOM: return "not a DICOM Part 10 file (no DICM marker)"
        case .truncated(let at): return "file truncated at byte \(at)"
        case .unsupportedTransferSyntax(let ts): return "unsupported transfer syntax \(ts)"
        case .missingElement(let n): return "missing required element \(n)"
        case .unsupported(let s): return "unsupported: \(s)"
        case .decodeFailed(let s): return "pixel decode failed: \(s)"
        }
    }
}

/// A DICOM tag packed as (group << 16) | element.
public struct Tag: Hashable, CustomStringConvertible {
    public let raw: UInt32
    public init(_ group: UInt16, _ element: UInt16) { raw = UInt32(group) << 16 | UInt32(element) }
    public var group: UInt16 { UInt16(raw >> 16) }
    public var element: UInt16 { UInt16(raw & 0xFFFF) }
    public var description: String { String(format: "(%04X,%04X)", group, element) }

    // Technical (non-identifying) tags this project reads.
    public static let transferSyntaxUID = Tag(0x0002, 0x0010)
    public static let sopClassUID = Tag(0x0008, 0x0016)
    public static let modality = Tag(0x0008, 0x0060)
    public static let seriesDescription = Tag(0x0008, 0x103E)
    public static let sliceThickness = Tag(0x0018, 0x0050)
    public static let spacingBetweenSlices = Tag(0x0018, 0x0088)
    public static let echoTime = Tag(0x0018, 0x0081)
    public static let repetitionTime = Tag(0x0018, 0x0080)
    public static let studyInstanceUID = Tag(0x0020, 0x000D)
    public static let seriesInstanceUID = Tag(0x0020, 0x000E)
    public static let seriesNumber = Tag(0x0020, 0x0011)
    public static let instanceNumber = Tag(0x0020, 0x0013)
    public static let imagePositionPatient = Tag(0x0020, 0x0032)
    public static let imageOrientationPatient = Tag(0x0020, 0x0037)
    public static let samplesPerPixel = Tag(0x0028, 0x0002)
    public static let photometricInterpretation = Tag(0x0028, 0x0004)
    public static let numberOfFrames = Tag(0x0028, 0x0008)
    public static let rows = Tag(0x0028, 0x0010)
    public static let columns = Tag(0x0028, 0x0011)
    public static let pixelSpacing = Tag(0x0028, 0x0030)
    public static let bitsAllocated = Tag(0x0028, 0x0100)
    public static let bitsStored = Tag(0x0028, 0x0101)
    public static let pixelRepresentation = Tag(0x0028, 0x0103)
    public static let windowCenter = Tag(0x0028, 0x1050)
    public static let windowWidth = Tag(0x0028, 0x1051)
    public static let rescaleIntercept = Tag(0x0028, 0x1052)
    public static let rescaleSlope = Tag(0x0028, 0x1053)
    public static let pixelData = Tag(0x7FE0, 0x0010)

    static let item = Tag(0xFFFE, 0xE000)
    static let itemDelimitation = Tag(0xFFFE, 0xE00D)
    static let sequenceDelimitation = Tag(0xFFFE, 0xE0DD)
}

public enum TransferSyntax {
    public static let implicitLE = "1.2.840.10008.1.2"
    public static let explicitLE = "1.2.840.10008.1.2.1"
    public static let deflatedExplicitLE = "1.2.840.10008.1.2.1.99"
    public static let explicitBE = "1.2.840.10008.1.2.2"
    public static let jpegBaseline = "1.2.840.10008.1.2.4.50"
    public static let jpeg2000Lossless = "1.2.840.10008.1.2.4.90"
    public static let jpeg2000 = "1.2.840.10008.1.2.4.91"

    public static func isEncapsulated(_ ts: String) -> Bool {
        ![implicitLE, explicitLE, explicitBE, deflatedExplicitLE].contains(ts)
    }
}

struct Element {
    let vr: String
    let offset: Int      // start of value bytes
    let length: Int      // value length (or -1 when undefined)
}

/// Minimal DICOM Part 10 reader: little-endian implicit/explicit VR, encapsulated pixel data.
/// Only top-level elements are indexed; sequences are skipped (classic single-frame images need nothing inside them).
public final class DICOMFile {
    public let transferSyntax: String
    let bytes: [UInt8]
    let explicitVR: Bool
    var elements: [Tag: Element] = [:]

    private static let longVRs: Set<String> = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UN", "UR", "UT", "SV", "UV"]

    public convenience init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 132, bytes[128] == 0x44, bytes[129] == 0x49, bytes[130] == 0x43, bytes[131] == 0x4D else {
            throw DICOMError.notDICOM
        }
        // File meta group (0002) is always explicit VR little endian.
        var meta: [Tag: Element] = [:]
        var pos = 132
        while pos + 8 <= bytes.count, Self.u16(bytes, pos) == 0x0002 {
            pos = try Self.readElement(bytes, pos, explicit: true, into: &meta)
        }
        guard let tsEl = meta[.transferSyntaxUID] else { throw DICOMError.missingElement("TransferSyntaxUID") }
        let ts = Self.string(bytes, tsEl)
        transferSyntax = ts
        if ts == TransferSyntax.explicitBE { throw DICOMError.unsupportedTransferSyntax(ts) }
        if ts == TransferSyntax.deflatedExplicitLE { throw DICOMError.unsupportedTransferSyntax(ts) }
        explicitVR = ts != TransferSyntax.implicitLE
        elements = meta
        while pos + 8 <= bytes.count {
            pos = try Self.readElement(bytes, pos, explicit: explicitVR, into: &elements)
        }
    }

    // MARK: value accessors

    public func has(_ tag: Tag) -> Bool { elements[tag] != nil }

    public func string(_ tag: Tag) -> String? {
        guard let el = elements[tag], el.length >= 0 else { return nil }
        return Self.string(bytes, el)
    }

    public func strings(_ tag: Tag) -> [String] {
        guard let s = string(tag) else { return [] }
        return s.split(separator: "\\", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Decimal string / integer string values.
    public func doubles(_ tag: Tag) -> [Double] { strings(tag).compactMap { Double($0) } }
    public func double(_ tag: Tag) -> Double? { doubles(tag).first }

    /// US (unsigned short) value; falls back to parsing a string for implicit-VR oddities.
    public func uint16(_ tag: Tag) -> Int? {
        guard let el = elements[tag], el.length >= 2 else { return nil }
        if el.vr == "US" || el.vr == "SS" || (el.vr == "UN" && el.length == 2) || el.vr == "OW" {
            return Int(Self.u16(bytes, el.offset))
        }
        return Int(string(tag) ?? "")
    }

    public func int(_ tag: Tag) -> Int? {
        if let el = elements[tag], el.vr == "US" || el.vr == "SS" { return uint16(tag) }
        return Int(string(tag) ?? "") ?? doubles(tag).first.map { Int($0) }
    }

    /// Raw pixel data bytes for native transfer syntaxes, or one codestream per frame when encapsulated.
    public func pixelFrames() throws -> [ArraySlice<UInt8>] {
        guard let el = elements[.pixelData] else { throw DICOMError.missingElement("PixelData") }
        if el.length >= 0 {
            return [bytes[el.offset ..< el.offset + el.length]]
        }
        // Encapsulated: items until sequence delimiter. First item is the basic offset table.
        var pos = el.offset
        var fragments: [ArraySlice<UInt8>] = []
        var first = true
        while pos + 8 <= bytes.count {
            let tag = Tag(Self.u16(bytes, pos), Self.u16(bytes, pos + 2))
            let len = Int(Self.u32(bytes, pos + 4))
            pos += 8
            if tag == .sequenceDelimitation { break }
            guard tag == .item, pos + len <= bytes.count else { throw DICOMError.truncated(at: pos) }
            if !first { fragments.append(bytes[pos ..< pos + len]) }
            first = false
            pos += len
        }
        let frames = max(1, int(.numberOfFrames) ?? 1)
        if frames == 1 && fragments.count > 1 {
            return [ArraySlice(fragments.flatMap { $0 })]
        }
        guard fragments.count == frames else {
            throw DICOMError.unsupported("\(fragments.count) fragments for \(frames) frames")
        }
        return fragments
    }

    // MARK: low-level parsing

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    static func string(_ b: [UInt8], _ el: Element) -> String {
        let slice = b[el.offset ..< el.offset + el.length]
        let s = String(decoding: slice, as: UTF8.self)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }

    /// Reads one element header at `pos`, records it, returns the position after its value.
    static func readElement(_ b: [UInt8], _ pos: Int, explicit: Bool, into dict: inout [Tag: Element]) throws -> Int {
        guard pos + 8 <= b.count else { throw DICOMError.truncated(at: pos) }
        let tag = Tag(u16(b, pos), u16(b, pos + 2))
        var vr = "UN"
        var length: UInt32
        var header = 8
        if explicit && tag.group != 0xFFFE {
            vr = String(decoding: b[pos + 4 ..< pos + 6], as: UTF8.self)
            if longVRs.contains(vr) {
                guard pos + 12 <= b.count else { throw DICOMError.truncated(at: pos) }
                length = u32(b, pos + 8)
                header = 12
            } else {
                length = UInt32(u16(b, pos + 6))
            }
        } else {
            length = u32(b, pos + 4)
        }
        let valueStart = pos + header
        if length == 0xFFFF_FFFF {
            dict[tag] = Element(vr: vr, offset: valueStart, length: -1)
            if tag == .pixelData {
                return try skipEncapsulated(b, valueStart)
            }
            return try skipUndefinedSequence(b, valueStart, explicit: explicit && vr != "UN")
        }
        let end = valueStart + Int(length)
        guard end <= b.count else { throw DICOMError.truncated(at: valueStart) }
        dict[tag] = Element(vr: vr, offset: valueStart, length: Int(length))
        return end
    }

    static func skipEncapsulated(_ b: [UInt8], _ start: Int) throws -> Int {
        var pos = start
        while pos + 8 <= b.count {
            let tag = Tag(u16(b, pos), u16(b, pos + 2))
            let len = Int(u32(b, pos + 4))
            pos += 8
            if tag == .sequenceDelimitation { return pos }
            pos += len
        }
        throw DICOMError.truncated(at: pos)
    }

    static func skipUndefinedSequence(_ b: [UInt8], _ start: Int, explicit: Bool) throws -> Int {
        var pos = start
        while pos + 8 <= b.count {
            let tag = Tag(u16(b, pos), u16(b, pos + 2))
            let len = u32(b, pos + 4)
            pos += 8
            if tag == .sequenceDelimitation { return pos }
            guard tag == .item else { throw DICOMError.unsupported("unexpected \(tag) in sequence") }
            if len == 0xFFFF_FFFF {
                var scratch: [Tag: Element] = [:]
                while true {
                    guard pos + 8 <= b.count else { throw DICOMError.truncated(at: pos) }
                    if Tag(u16(b, pos), u16(b, pos + 2)) == .itemDelimitation { pos += 8; break }
                    pos = try readElement(b, pos, explicit: explicit, into: &scratch)
                }
            } else {
                pos += Int(len)
            }
        }
        throw DICOMError.truncated(at: pos)
    }
}
