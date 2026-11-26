import Foundation
import COpenJPEG

/// Full-precision JPEG 2000 decoding via the vendored OpenJPEG library.
public enum JPEG2000 {
    public struct Image {
        public let width: Int
        public let height: Int
        public let precision: Int
        public let signed: Bool
        public let samples: [Int32]
    }

    private final class Reader {
        let base: UnsafeRawPointer
        let count: Int
        var pos = 0
        init(base: UnsafeRawPointer, count: Int) { self.base = base; self.count = count }
    }

    public static func decode(_ data: Data) throws -> Image {
        let bytes = [UInt8](data)
        guard bytes.count > 12 else { throw DICOMError.decodeFailed("JPEG 2000 stream too short") }
        // Raw codestream starts with SOC marker FF 4F; otherwise assume a JP2 file.
        let format = (bytes[0] == 0xFF && bytes[1] == 0x4F) ? OPJ_CODEC_J2K : OPJ_CODEC_JP2

        return try bytes.withUnsafeBytes { raw -> Image in
            let reader = Reader(base: raw.baseAddress!, count: raw.count)
            let user = Unmanaged.passUnretained(reader).toOpaque()

            guard let codec = opj_create_decompress(format) else { throw DICOMError.decodeFailed("opj_create_decompress") }
            defer { opj_destroy_codec(codec) }
            var params = opj_dparameters_t()
            opj_set_default_decoder_parameters(&params)
            guard opj_setup_decoder(codec, &params) != 0 else { throw DICOMError.decodeFailed("opj_setup_decoder") }

            guard let stream = opj_stream_create(OPJ_SIZE_T(65536), OPJ_TRUE) else { throw DICOMError.decodeFailed("opj_stream_create") }
            defer { opj_stream_destroy(stream) }
            opj_stream_set_user_data(stream, user, nil)
            opj_stream_set_user_data_length(stream, OPJ_UINT64(raw.count))
            opj_stream_set_read_function(stream) { buffer, n, user in
                let r = Unmanaged<Reader>.fromOpaque(user!).takeUnretainedValue()
                let remaining = r.count - r.pos
                if remaining <= 0 { return OPJ_SIZE_T.max } // (OPJ_SIZE_T)-1 signals end of stream
                let k = min(Int(n), remaining)
                memcpy(buffer!, r.base + r.pos, k)
                r.pos += k
                return OPJ_SIZE_T(k)
            }
            opj_stream_set_skip_function(stream) { n, user in
                let r = Unmanaged<Reader>.fromOpaque(user!).takeUnretainedValue()
                let target = max(0, min(r.count, r.pos + Int(n)))
                let moved = target - r.pos
                r.pos = target
                return OPJ_OFF_T(moved)
            }
            opj_stream_set_seek_function(stream) { n, user in
                let r = Unmanaged<Reader>.fromOpaque(user!).takeUnretainedValue()
                guard n >= 0, Int(n) <= r.count else { return OPJ_FALSE }
                r.pos = Int(n)
                return OPJ_TRUE
            }

            var imagePtr: UnsafeMutablePointer<opj_image_t>?
            guard opj_read_header(stream, codec, &imagePtr) != 0, let image = imagePtr else {
                throw DICOMError.decodeFailed("opj_read_header")
            }
            defer { opj_image_destroy(image) }
            guard opj_decode(codec, stream, image) != 0, opj_end_decompress(codec, stream) != 0 else {
                throw DICOMError.decodeFailed("opj_decode")
            }
            guard image.pointee.numcomps >= 1, let comps = image.pointee.comps else {
                throw DICOMError.decodeFailed("no image components")
            }
            let c = comps[0]
            let w = Int(c.w), h = Int(c.h)
            guard let p = c.data else { throw DICOMError.decodeFailed("no component data") }
            let samples = Array(UnsafeBufferPointer(start: p, count: w * h))
            return Image(width: w, height: h, precision: Int(c.prec), signed: c.sgnd != 0, samples: samples)
        }
    }

    private final class Writer { var data = Data() }

    /// Lossless (reversible 5/3) JPEG 2000 codestream encoder for one grayscale plane.
    /// Used to build synthetic test data that exercises the same encapsulated path as real scans.
    public static func encodeLossless(_ samples: [Int32], width: Int, height: Int, precision: Int, signed: Bool = false) throws -> Data {
        var cp = opj_image_cmptparm_t()
        cp.dx = 1; cp.dy = 1
        cp.w = OPJ_UINT32(width); cp.h = OPJ_UINT32(height)
        cp.prec = OPJ_UINT32(precision); cp.sgnd = signed ? 1 : 0
        guard let image = opj_image_create(1, &cp, OPJ_CLRSPC_GRAY) else { throw DICOMError.decodeFailed("opj_image_create") }
        defer { opj_image_destroy(image) }
        image.pointee.x0 = 0; image.pointee.y0 = 0
        image.pointee.x1 = OPJ_UINT32(width); image.pointee.y1 = OPJ_UINT32(height)
        guard let dst = image.pointee.comps[0].data else { throw DICOMError.decodeFailed("no component buffer") }
        for i in 0 ..< min(samples.count, width * height) { dst[i] = samples[i] }

        var params = opj_cparameters_t()
        opj_set_default_encoder_parameters(&params)
        params.tcp_numlayers = 1
        params.tcp_rates.0 = 0        // 0 = lossless
        params.cp_disto_alloc = 1
        params.irreversible = 0       // reversible 5/3 wavelet
        // Each resolution level halves the image; keep the smallest level at least 1 pixel.
        var levels = 1
        while levels < 6 && (min(width, height) >> levels) >= 1 { levels += 1 }
        params.numresolution = OPJ_INT32(levels)

        guard let codec = opj_create_compress(OPJ_CODEC_J2K) else { throw DICOMError.decodeFailed("opj_create_compress") }
        defer { opj_destroy_codec(codec) }
        guard opj_setup_encoder(codec, &params, image) != 0 else { throw DICOMError.decodeFailed("opj_setup_encoder") }

        let writer = Writer()
        guard let stream = opj_stream_create(OPJ_SIZE_T(65536), OPJ_FALSE) else { throw DICOMError.decodeFailed("opj_stream_create") }
        defer { opj_stream_destroy(stream) }
        opj_stream_set_user_data(stream, Unmanaged.passUnretained(writer).toOpaque(), nil)
        opj_stream_set_write_function(stream) { buffer, n, user in
            let w = Unmanaged<Writer>.fromOpaque(user!).takeUnretainedValue()
            w.data.append(buffer!.assumingMemoryBound(to: UInt8.self), count: Int(n))
            return n
        }
        opj_stream_set_skip_function(stream) { n, user in
            let w = Unmanaged<Writer>.fromOpaque(user!).takeUnretainedValue()
            if n > 0 { w.data.append(Data(count: Int(n))) }
            return n
        }
        opj_stream_set_seek_function(stream) { n, user in
            let w = Unmanaged<Writer>.fromOpaque(user!).takeUnretainedValue()
            if Int(n) > w.data.count { w.data.append(Data(count: Int(n) - w.data.count)) }
            return OPJ_TRUE
        }
        guard opj_start_compress(codec, image, stream) != 0,
              opj_encode(codec, stream) != 0,
              opj_end_compress(codec, stream) != 0 else { throw DICOMError.decodeFailed("opj_encode") }
        return writer.data
    }
}
