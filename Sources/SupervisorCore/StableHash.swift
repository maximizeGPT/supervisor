// StableHash.swift — the shared stable (non-randomized) hash behind every
// persisted identity.
//
// EXTRACTED (issue #54 item 3) from two byte-for-byte identical private
// copies: ReviewFindingStore.fnv1a64Hex (review-finding fingerprints) and
// MemoryEntry.stableHash (second-brain entry ids + excerpt hashes). Swift's
// own `Hasher` is per-run randomized, so any identity that must survive
// across launches and processes hashes through this instead.
//
// FROZEN: the offset basis, prime, XOR-then-multiply order, and the
// unpadded-lowercase hex formatting are all load-bearing — fingerprints and
// memory ids already on disk were minted with exactly this function, and
// changing any part would orphan them. StableHashTests pins golden values.

import Foundation

/// A caseless enum hosting the stable hash: pure static function, no state.
enum StableHash {

    /// FNV-1a 64-bit over the UTF-8 bytes, hex-encoded (lowercase, no zero
    /// padding — `String(_:radix:)`'s natural form). Deterministic across
    /// processes — the property persistence-based dedup and stable ids need.
    static func fnv1a64Hex(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}
