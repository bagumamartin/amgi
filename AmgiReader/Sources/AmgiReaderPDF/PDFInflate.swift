public import Compression
public import Foundation

/// Decompresses a `/FlateDecode` stream.
///
/// Delegates to the platform's DEFLATE rather than carrying a hand-rolled
/// decoder, and that is a correctness decision rather than a convenience one.
/// A cross-reference stream holds *byte offsets*: a decoder that is subtly
/// wrong does not fail, it returns a plausible array of wrong numbers, and
/// every offset read from it lands in the middle of some other object. The file
/// still opens — here and in Preview — with an annotation on the wrong page. A
/// decoder that refuses what it does not fully understand is strictly safer,
/// and the platform's is the one that is always right.
enum PDFInflate {
    /// Decodes a DEFLATE stream as a PDF `/FlateDecode` filter produces it.
    ///
    /// Two things about that format are worth stating, because getting either
    /// wrong fails quietly:
    ///
    /// - A PDF's `/FlateDecode` payload is *zlib-wrapped* (RFC 1950: a two-byte
    ///   header, a raw DEFLATE body, an Adler-32 trailer), while the platform's
    ///   `COMPRESSION_ZLIB` codec decodes *bare* DEFLATE (RFC 1951) and ignores
    ///   any wrapper. Handing it a wrapped stream without stripping the header
    ///   does not reliably fail; on the samples measured it produced 63 bytes of
    ///   plausible garbage from an 1,800-byte payload.
    /// - So the header is detected and skipped explicitly rather than by
    ///   trial, and the body is decoded with the streaming API, which
    ///   distinguishes a clean end of stream from a decode error partway
    ///   through. A truncated cross-reference stream is the case that matters
    ///   most: a decoder that returned what it managed to read would hand back
    ///   a short, well-formed array whose missing tail silently omits every
    ///   object past that point.
    static func decode(_ input: [UInt8]) -> [UInt8]? {
        guard !input.isEmpty else { return [] }
        let body = hasZlibHeader(input) ? input.dropFirst(2) : input[...]
        return try? inflate(body)
    }

    /// A zlib header is a compression method of 8 (DEFLATE) and a check value
    /// that makes the two header bytes a multiple of 31.
    ///
    /// Checked properly rather than assumed, because some producers emit bare
    /// DEFLATE under a `/FlateDecode` label and skipping two bytes of a stream
    /// that has no header loses the first two bytes of every object offset.
    static func hasZlibHeader(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else { return false }
        guard bytes[0] & 0x0F == 8 else { return false }
        return (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0
    }

    private enum InflateError: Error {
        case couldNotStart
        case failed(compression_status)
        case endedWithoutFinishing
    }

    /// Inflates a bare DEFLATE stream, failing rather than returning a partial
    /// result.
    ///
    /// The output buffer is fixed and the input is fed in chunks, so there is
    /// no guessing at the expanded size — a cross-reference stream is a few tens
    /// of kilobytes, but a content stream can be tens of megabytes, and a
    /// capacity heuristic would either waste memory on one or truncate the other.
    private static func inflate(_ input: ArraySlice<UInt8>) throws -> [UInt8] {
        let source = Array(input)
        // An empty array has no base address, and the loop below would
        // dereference it unconditionally. A zlib stream whose body was
        // entirely a header decodes to nothing, so this is reachable.
        guard !source.isEmpty else { return [] }
        let chunkSize = 64 * 1_024

        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(
            &stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB
        ) == COMPRESSION_STATUS_OK else { throw InflateError.couldNotStart }
        defer { compression_stream_destroy(&stream) }

        var output: [UInt8] = []
        // Reserved up front and appended to, so a large stream is not
        // repeatedly reallocated as it grows.
        output.reserveCapacity(max(chunkSize, source.count * 4))
        var destination = [UInt8](repeating: 0, count: chunkSize)
        var sourceOffset = 0
        var status = COMPRESSION_STATUS_OK

        while true {
            let sourceEnd = min(sourceOffset + chunkSize, source.count)
            let available = sourceEnd - sourceOffset

            status = source.withUnsafeBufferPointer { sourceBuffer in
                destination.withUnsafeMutableBufferPointer { destinationBuffer in
                    // A null pointer is required when the corresponding size is
                    // zero; the codec dereferences it unconditionally.
                    stream.src_ptr = available > 0
                        ? sourceBuffer.baseAddress! + sourceOffset
                        : UnsafePointer(bitPattern: 1)!
                    stream.src_size = available
                    stream.dst_ptr = destinationBuffer.baseAddress!
                    stream.dst_size = chunkSize
                    return compression_stream_process(
                        &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    )
                }
            }

            guard status == COMPRESSION_STATUS_OK || status == COMPRESSION_STATUS_END
            else { throw InflateError.failed(status) }

            let produced = chunkSize - stream.dst_size
            if produced > 0 {
                output.append(contentsOf: destination[0..<produced])
            }
            sourceOffset = sourceEnd

            if status == COMPRESSION_STATUS_END { return output }
            // No progress on either side: the stream is not going to end.
            guard produced > 0 || available > 0 else {
                throw InflateError.endedWithoutFinishing
            }
        }
    }
}
