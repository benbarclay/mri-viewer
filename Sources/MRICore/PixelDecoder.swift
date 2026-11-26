import Foundation
import ImageIO
import CoreGraphics

/// Pixel format of a single-sample (grayscale) image.
public struct PixelFormat: Equatable {
    public var rows: Int
    public var columns: Int
    public var bitsAllocated: Int
    public var bitsStored: Int
    public var signed: Bool
    public var samplesPerPixel: Int
    public var photometric: String

    public init(file: DICOMFile) throws {
        guard let r = file.uint16(.rows), let c = file.uint16(.columns) else { throw DICOMError.missingElement("Rows/Columns") }
        rows = r
        columns = c
        bitsAllocated = file.uint16(.bitsAllocated) ?? 16
        bitsStored = file.uint16(.bitsStored) ?? bitsAllocated
        signed = (file.uint16(.pixelRepresentation) ?? 0) == 1
        samplesPerPixel = file.uint16(.samplesPerPixel) ?? 1
        photometric = file.string(.photometricInterpretation) ?? "MONOCHROME2"
    }
}

/// Decodes DICOM pixel data into stored values (before rescale), as Float.
public enum PixelDecoder {
    public static func decodeFrames(_ file: DICOMFile) throws -> [[Float]] {
        let fmt = try PixelFormat(file: file)
        guard fmt.samplesPerPixel == 1 else { throw DICOMError.unsupported("\(fmt.samplesPerPixel) samples per pixel (colour)") }
        let frames = try file.pixelFrames()
        let ts = file.transferSyntax
        var out: [[Float]] = []
        if TransferSyntax.isEncapsulated(ts) {
            switch ts {
            case TransferSyntax.jpeg2000Lossless, TransferSyntax.jpeg2000:
                for f in frames { out.append(try decodeJPEG2000(Data(f), fmt: fmt)) }
            case TransferSyntax.jpegBaseline:
                // 8-bit baseline JPEG: ImageIO is exact enough for 8-bit data.
                for f in frames { out.append(try decodeImageIO(Data(f), fmt: fmt)) }
            default:
                throw DICOMError.unsupportedTransferSyntax(ts)
            }
        } else {
            guard let data = frames.first else { throw DICOMError.missingElement("PixelData") }
            let n = fmt.rows * fmt.columns
            let nFrames = max(1, file.int(.numberOfFrames) ?? 1)
            let bytesPerPixel = fmt.bitsAllocated / 8
            guard data.count >= n * nFrames * bytesPerPixel else { throw DICOMError.truncated(at: data.startIndex) }
            for k in 0 ..< nFrames {
                out.append(decodeNative(data, offset: data.startIndex + k * n * bytesPerPixel, count: n, fmt: fmt))
            }
        }
        if fmt.photometric == "MONOCHROME1" {
            // Inverted grayscale: flip so that higher always means brighter.
            let maxV = Float((1 << fmt.bitsStored) - 1)
            out = out.map { $0.map { maxV - $0 } }
        }
        return out
    }

    static func decodeNative(_ d: ArraySlice<UInt8>, offset: Int, count n: Int, fmt: PixelFormat) -> [Float] {
        var px = [Float](repeating: 0, count: n)
        switch fmt.bitsAllocated {
        case 8:
            for i in 0 ..< n {
                let v = d[offset + i]
                px[i] = fmt.signed ? Float(Int8(bitPattern: v)) : Float(v)
            }
        default: // 16
            let mask: UInt16 = fmt.bitsStored >= 16 ? 0xFFFF : UInt16((1 << fmt.bitsStored) - 1)
            let signBit: UInt16 = UInt16(1) << UInt16(max(0, fmt.bitsStored - 1))
            for i in 0 ..< n {
                let o = offset + 2 * i
                var v = (UInt16(d[o]) | UInt16(d[o + 1]) << 8) & mask
                if fmt.signed {
                    if v & signBit != 0 { v |= ~mask } // sign-extend
                    px[i] = Float(Int16(bitPattern: v))
                } else {
                    px[i] = Float(v)
                }
            }
        }
        return px
    }

    static func decodeJPEG2000(_ d: Data, fmt: PixelFormat) throws -> [Float] {
        let img = try JPEG2000.decode(d)
        guard img.width == fmt.columns, img.height == fmt.rows else {
            throw DICOMError.decodeFailed("decoded size \(img.width)x\(img.height) != \(fmt.columns)x\(fmt.rows)")
        }
        var px = [Float](repeating: 0, count: img.samples.count)
        for i in px.indices { px[i] = Float(img.samples[i]) }
        return px
    }

    static func decodeImageIO(_ d: Data, fmt: PixelFormat) throws -> [Float] {
        let opts = [kCGImageSourceTypeIdentifierHint: "public.jpeg", kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(d as CFData, opts),
              let img = CGImageSourceCreateImageAtIndex(src, 0, opts) else {
            throw DICOMError.decodeFailed("ImageIO could not decode JPEG")
        }
        guard img.width == fmt.columns, img.height == fmt.rows, img.bitsPerComponent == 8 else {
            throw DICOMError.decodeFailed("unexpected JPEG layout")
        }
        // Draw into an 8-bit gray context with no colour management to read raw samples.
        var px8 = [UInt8](repeating: 0, count: fmt.rows * fmt.columns)
        let ok = px8.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: fmt.columns, height: fmt.rows, bitsPerComponent: 8,
                                      bytesPerRow: fmt.columns, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: fmt.columns, height: fmt.rows))
            return true
        }
        guard ok else { throw DICOMError.decodeFailed("CGContext") }
        return px8.map { Float($0) }
    }
}
