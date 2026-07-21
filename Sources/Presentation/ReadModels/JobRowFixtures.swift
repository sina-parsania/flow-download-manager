// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation

/// Deterministic fixture read models for previews, snapshots and the 10,000-row
/// performance baseline (`05-quality-testing-release-gates.md` §5). Deterministic:
/// the same `count`/`seed` always yields the same rows, so snapshots are stable.
public enum JobRowFixtures {
    private static let hosts = [
        "cdn.example.test", "files.example.test", "mirror.example.test",
        "media.example.test", "archive.example.test"
    ]
    private static let categories = ["videos", "audio", "images", "documents", "archives"]
    private static let states: [JobState] = [
        .downloading, .queued, .paused, .completed, .failed, .scheduled, .retryWaiting
    ]

    /// Build `count` deterministic rows. UUIDs are derived from the index so they
    /// are stable across runs.
    public static func make(count: Int, seed: UInt64 = 1) -> [JobRowModel] {
        (0 ..< count).map { index in
            let s = UInt64(index) &+ seed
            let state = states[index % states.count]
            let total: Int64 = 1_000_000 + Int64((s &* 2_654_435_761) % 900_000_000)
            let fraction: Double? = {
                switch state {
                case .completed: return 1.0
                case .queued, .scheduled: return 0.0
                case .failed: return Double(s % 80) / 100.0
                default: return Double(s % 100) / 100.0
                }
            }()
            let transferred = Int64((fraction ?? 0) * Double(total))
            return JobRowModel(
                id: deterministicUUID(index),
                name: "download-\(String(format: "%05d", index)).bin",
                sourceHost: hosts[index % hosts.count],
                state: state,
                progressFraction: fraction,
                bytesTransferred: transferred,
                totalBytes: total,
                speedBytesPerSecond: state == .downloading ? Int64(500_000 + (s % 4_000_000)) : 0,
                etaSeconds: state == .downloading ? Int(5 + (s % 3600)) : nil,
                categoryKey: categories[index % categories.count],
                projectName: index % 7 == 0 ? "Project \(index % 5)" : nil,
                tagNames: index % 3 == 0 ? ["tag-\(index % 4)"] : []
            )
        }
    }

    /// Index-derived UUIDv7-shaped identifier, stable across runs.
    private static func deterministicUUID(_ index: Int) -> UUID {
        let hi = UInt64(0x0000_0000_7000_8000)
        let lo = UInt64(index) &+ 0x0000_0000_0000_0001
        func bytes(_ v: UInt64) -> [UInt8] {
            (0 ..< 8).map { UInt8((v >> (8 * (7 - $0))) & 0xFF) }
        }
        let b = bytes(hi) + bytes(lo)
        return UUID(uuid: (
            b[0],
            b[1],
            b[2],
            b[3],
            b[4],
            b[5],
            b[6],
            b[7],
            b[8],
            b[9],
            b[10],
            b[11],
            b[12],
            b[13],
            b[14],
            b[15]
        ))
    }
}
