import CryptoKit
import Foundation
import Testing

@testable import AusterCore

/// The Dropbox content hash is how Auster decides whether a local file and a
/// remote revision are the same bytes without transferring anything, so it is
/// checked against an independent implementation of the published algorithm
/// (api-notes §4) rather than against itself.
@Suite("ContentHasher")
struct ContentHasherTests {

    // MARK: - Reference implementation

    /// SHA-256 per 4 MiB block, concatenate the raw digests, SHA-256 that,
    /// hex-encode. Deliberately naive and whole-file: it exists to disagree with
    /// the streaming implementation if that one is wrong.
    private func reference(_ data: Data) -> String {
        var digests = Data()
        var offset = 0
        while offset < data.count {
            let end = min(offset + ContentHasher.blockSize, data.count)
            digests.append(contentsOf: SHA256.hash(data: data[offset..<end]))
            offset = end
        }
        return SHA256.hash(data: digests).map { String(format: "%02x", $0) }.joined()
    }

    /// Deterministic pseudo-random bytes: real content, reproducible failures.
    private func bytes(_ count: Int, seed: UInt64 = 0x5DEE_CE66) -> Data {
        var state = seed | 1
        var data = Data(count: count)
        // Parameter type spelled out: the untyped closure is ambiguous between
        // Foundation's raw-buffer and deprecated typed-pointer overloads.
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for index in 0..<count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                raw[index] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return data
    }

    private func scratchFile(_ data: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "auster-hash-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    // MARK: - Block size

    @Test("the block size is Dropbox's 4 MiB")
    func blockSize() {
        #expect(ContentHasher.blockSize == 4_194_304)
    }

    // MARK: - Known values

    @Test("an empty input hashes the empty digest concatenation")
    func emptyInput() {
        // SHA-256 of zero bytes: no blocks means nothing to concatenate.
        let expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(ContentHasher.hash(data: Data()) == expected)
        #expect(reference(Data()) == expected)
    }

    @Test("a single block is not the plain SHA-256 of its bytes")
    func singleBlockIsDoubleHashed() {
        let data = Data("hello".utf8)
        let plain = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(ContentHasher.hash(data: data) != plain)
        #expect(ContentHasher.hash(data: data) == reference(data))
    }

    // MARK: - Block boundaries

    @Test(
        "hashing matches the reference across the block boundary",
        arguments: [
            0,
            1,
            1024,
            ContentHasher.blockSize - 1,
            ContentHasher.blockSize,
            ContentHasher.blockSize + 1,
            ContentHasher.blockSize * 2,
            ContentHasher.blockSize * 2 + 12_345,
        ]
    )
    func boundaries(size: Int) throws {
        let data = bytes(size)
        #expect(ContentHasher.hash(data: data) == reference(data))

        let url = try scratchFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ContentHasher.hash(fileAt: url) == reference(data))
    }

    // MARK: - Streaming

    @Test(
        "streaming in uneven chunks matches hashing the whole input",
        arguments: [1, 7, 4096, ContentHasher.blockSize - 3, ContentHasher.blockSize + 5]
    )
    func streamingChunkSizes(chunk: Int) {
        let data = bytes(ContentHasher.blockSize * 2 + 9_999)

        var streaming = ContentHasher.Streaming()
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            streaming.update(data[offset..<end])
            offset = end
        }

        #expect(streaming.finalize() == reference(data))
    }

    @Test("finalize does not consume the accumulator")
    func finalizeIsRepeatable() {
        var streaming = ContentHasher.Streaming()
        streaming.update(Data("hello".utf8))
        let first = streaming.finalize()
        #expect(streaming.finalize() == first)

        // ...and the stream can still be extended afterwards.
        streaming.update(Data(" world".utf8))
        #expect(streaming.finalize() == ContentHasher.hash(data: Data("hello world".utf8)))
    }

    @Test("an empty update leaves the hash alone")
    func emptyUpdate() {
        var streaming = ContentHasher.Streaming()
        streaming.update(Data())
        #expect(streaming.finalize() == ContentHasher.hash(data: Data()))
    }

    // MARK: - Files

    @Test("hashing a file agrees with hashing its bytes")
    func fileMatchesData() throws {
        let data = bytes(ContentHasher.blockSize + 500_000)
        let url = try scratchFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try ContentHasher.hash(fileAt: url) == ContentHasher.hash(data: data))
    }

    @Test("hashing a missing file throws rather than returning the empty hash")
    func missingFileThrows() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "auster-absent-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try ContentHasher.hash(fileAt: url)
        }
    }
}
