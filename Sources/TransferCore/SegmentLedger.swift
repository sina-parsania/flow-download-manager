// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import TransferCurlBridge

/// Persisted per-segment progress map. Lives as a `.segmap` sidecar next to the
/// partial; deleted on success. In-memory updates on every progress callback,
/// disk writes throttled to once per second plus explicit flushes.
final class SegmentLedger: @unchecked Sendable {
    struct Entry: Codable, Sendable {
        var start: Int64
        var end: Int64 // inclusive
        var written: Int64
    }

    private struct MapFile: Codable {
        var total: Int64
        var baseOffset: Int64
        var entries: [Entry]
        /// Absent in maps written before validators existed. Decoding must keep
        /// working for those — a missing validator means "cannot verify", which
        /// still resumes; only a contradicted one rejects.
        var validator: ResourceValidator?
    }

    let total: Int64
    /// Bytes on disk before the mapped region (legacy contiguous-prefix resume).
    let baseOffset: Int64
    /// What the server said this resource was when the map was created.
    let validator: ResourceValidator?

    private let sidecarURL: URL
    private let lock = NSLock()
    private var entries: [Entry]
    private var lastSaveNanos: UInt64 = 0

    init(
        total: Int64,
        baseOffset: Int64,
        entries: [Entry],
        sidecarURL: URL,
        validator: ResourceValidator? = nil
    ) {
        self.total = total
        self.baseOffset = baseOffset
        self.entries = entries
        self.sidecarURL = sidecarURL
        self.validator = validator
    }

    static func load(sidecarURL: URL) -> SegmentLedger? {
        guard let data = try? Data(contentsOf: sidecarURL),
              let file = try? JSONDecoder().decode(MapFile.self, from: data),
              file.total > 0,
              !file.entries.isEmpty,
              file.entries.allSatisfy({ entry in
                  entry.start >= 0 && entry.end < file.total && entry.start <= entry.end
                      && entry.written >= 0 && entry.written <= entry.end - entry.start + 1
              }),
              isStructurallyValid(file)
        else { return nil }
        return SegmentLedger(
            total: file.total,
            baseOffset: file.baseOffset,
            entries: file.entries,
            sidecarURL: sidecarURL,
            validator: file.validator
        )
    }

    /// Contiguous coverage from `baseOffset` through `total - 1`, sorted, no gaps
    /// or overlaps. Invalid maps return nil from `load` without rewriting the sidecar.
    private static func isStructurallyValid(_ file: MapFile) -> Bool {
        guard file.baseOffset >= 0, file.baseOffset < file.total else { return false }
        let entries = file.entries
        guard let first = entries.first, let last = entries.last else { return false }
        guard first.start == file.baseOffset else { return false }
        guard last.end == file.total - 1 else { return false }

        for index in entries.indices {
            let entry = entries[index]
            if index > 0 {
                let previous = entries[index - 1]
                guard previous.start < entry.start else { return false }
                guard previous.end < Int64.max else { return false }
                guard entry.start == previous.end + 1 else { return false }
            }
        }
        return true
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    struct Work: Equatable {
        let entryIndex: Int
        let baseWritten: Int64
        let request: CurlMultiLoop.RangeRequest
    }

    func remainingWork() -> [Work] {
        lock.lock()
        defer { lock.unlock() }
        return entries.enumerated().compactMap { index, entry in
            let start = entry.start + entry.written
            guard start <= entry.end else { return nil }
            return Work(
                entryIndex: index,
                baseWritten: entry.written,
                request: CurlMultiLoop.RangeRequest(
                    rangeHeader: "\(start)-\(entry.end)",
                    fileOffset: start,
                    expectedBytes: entry.end - start + 1
                )
            )
        }
    }

    func remainingBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return entries.reduce(Int64(0)) { $0 + ($1.end - $1.start + 1 - $1.written) }
    }

    func downloadedBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return entries.reduce(Int64(0)) { $0 + $1.written }
    }

    /// Records cumulative progress for one entry; returns completed bytes
    /// across all entries. Persists at most once per second.
    func record(entry index: Int, written: Int64) -> Int64 {
        lock.lock()
        if index >= 0, index < entries.count {
            let capacity = entries[index].end - entries[index].start + 1
            entries[index].written = min(max(entries[index].written, written), capacity)
        }
        let done = entries.reduce(Int64(0)) { $0 + $1.written }
        let now = DispatchTime.now().uptimeNanoseconds
        var snapshot: MapFile?
        if now &- lastSaveNanos >= 1_000_000_000 {
            lastSaveNanos = now
            snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries, validator: validator)
        }
        lock.unlock()
        if let snapshot { write(snapshot) }
        return done
    }

    func markCompleted(entryIndices: [Int]) {
        lock.lock()
        for index in entryIndices where index >= 0 && index < entries.count {
            entries[index].written = entries[index].end - entries[index].start + 1
        }
        let snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries, validator: validator)
        lock.unlock()
        write(snapshot)
    }

    /// Splits the largest remaining ranges until `targetCount` incomplete
    /// entries exist (or chunks would drop below 4 MiB). Called between retry
    /// attempts so leftover bytes regain parallel connections.
    func resplit(targetCount: Int) {
        let minChunk: Int64 = 4 * 1024 * 1024
        lock.lock()
        while true {
            let incomplete = entries.indices.filter {
                entries[$0].written < entries[$0].end - entries[$0].start + 1
            }
            guard incomplete.count < targetCount else { break }
            guard let largest = incomplete.max(by: { lhs, rhs in
                remainingLocked(entries[lhs]) < remainingLocked(entries[rhs])
            }), remainingLocked(entries[largest]) >= 2 * minChunk else { break }
            let entry = entries[largest]
            let head = entry.start + entry.written
            let mid = head + remainingLocked(entry) / 2
            entries[largest].end = mid - 1
            // Insert, never append. `load` rejects a map whose entries are not
            // contiguous and ascending — and appending the tail half of a *middle*
            // entry breaks both that and `last.end == total - 1`. The map still
            // described the download correctly in memory, so the pass finished
            // fine; the damage only showed up on the next launch, where `load`
            // returned nil, the resume was skipped, and a preallocated full-size
            // partial was left for the caller to misread. Splitting the last entry
            // happened to be safe, which is why this survived.
            entries.insert(Entry(start: mid, end: entry.end, written: 0), at: largest + 1)
        }
        let snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries, validator: validator)
        lock.unlock()
        write(snapshot)
    }

    func flush() {
        lock.lock()
        let snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries, validator: validator)
        lock.unlock()
        write(snapshot)
    }

    func saveNow() throws {
        lock.lock()
        let snapshot = MapFile(total: total, baseOffset: baseOffset, entries: entries, validator: validator)
        lock.unlock()
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: sidecarURL, options: .atomic)
    }

    func deleteSidecar() {
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    private func remainingLocked(_ entry: Entry) -> Int64 {
        entry.end - entry.start + 1 - entry.written
    }

    private func write(_ snapshot: MapFile) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: sidecarURL, options: .atomic)
    }
}
