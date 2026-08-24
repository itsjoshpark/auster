import CryptoKit
import Foundation

/// Dropbox's `content_hash` (api-notes §4): 4 MiB blocks, each SHA-256'd, the
/// digests concatenated and SHA-256'd again. Everything streams, because sync
/// folders routinely hold files larger than memory.
public enum ContentHasher {

    /// Dropbox's block size. Also the chunk size uploads use, so a session's
    /// per-chunk hashes line up with block boundaries (api-notes §6).
    public static let blockSize = 4 * 1024 * 1024

    /// Hashes a file by streaming it. Throws whatever reading it threw: a hash of
    /// the wrong bytes is worse than no hash, so this never falls back.
    public static func hash(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var streaming = Streaming()
        while let chunk = try handle.read(upToCount: blockSize), !chunk.isEmpty {
            streaming.update(chunk)
        }
        return streaming.finalize()
    }

    /// Hashes bytes already in memory.
    public static func hash(data: Data) -> String {
        var streaming = Streaming()
        streaming.update(data)
        return streaming.finalize()
    }

    /// Accumulates the hash as bytes arrive, so a transfer can be verified while
    /// it happens. `finalize()` is non-mutating and repeatable, working on a copy
    /// of the in-progress block.
    public struct Streaming: Sendable {

        /// Concatenated raw digests of the blocks completed so far.
        private var digests = Data()

        /// Hasher for the block currently being filled.
        private var blockHasher = SHA256()

        /// Bytes fed into `blockHasher`.
        private var blockFilled = 0

        public init() {}

        public mutating func update(_ chunk: Data) {
            var remaining = chunk[...]
            while !remaining.isEmpty {
                let take = min(ContentHasher.blockSize - blockFilled, remaining.count)
                let boundary = remaining.index(remaining.startIndex, offsetBy: take)
                blockHasher.update(data: remaining[remaining.startIndex..<boundary])
                blockFilled += take
                remaining = remaining[boundary...]

                if blockFilled == ContentHasher.blockSize {
                    digests.append(contentsOf: blockHasher.finalize())
                    blockHasher = SHA256()
                    blockFilled = 0
                }
            }
        }

        /// The hash of everything fed in so far.
        public func finalize() -> String {
            var complete = digests
            if blockFilled > 0 {
                // `finalize()` on the hasher is non-mutating, so reading the
                // partial block here leaves it open for more input.
                complete.append(contentsOf: blockHasher.finalize())
            }
            return SHA256.hash(data: complete)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }
}
