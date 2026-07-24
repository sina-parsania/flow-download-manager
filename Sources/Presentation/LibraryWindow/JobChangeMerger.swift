// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation
import XPCContracts

/// Pure merge of a change-aware Library batch into existing row models.
public enum JobChangeMerger {
    public struct Outcome: Sendable {
        public let rows: [JobRowModel]
        public let needsFullRefresh: Bool

        public init(rows: [JobRowModel], needsFullRefresh: Bool) {
            self.rows = rows
            self.needsFullRefresh = needsFullRefresh
        }
    }

    public static func apply(
        current: [JobRowModel],
        batch: JobChangeBatch,
        mapUpsert: (JobSnapshot) -> JobRowModel?
    ) -> Outcome {
        if batch.hasGap {
            return Outcome(rows: current, needsFullRefresh: true)
        }
        let removed = Set(batch.removedJobIDs.compactMap(UUID.init(uuidString:)))
        var byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for id in removed {
            byID[id] = nil
        }
        for snapshot in batch.upserts {
            guard let row = mapUpsert(snapshot) else { continue }
            byID[row.id] = row
        }
        // Preserve a stable order: existing order first, new ids appended.
        var ordered: [JobRowModel] = []
        ordered.reserveCapacity(byID.count)
        var seen = Set<UUID>()
        for row in current where byID[row.id] != nil {
            if let updated = byID[row.id] {
                ordered.append(updated)
                seen.insert(row.id)
            }
        }
        for snapshot in batch.upserts {
            guard let id = UUID(uuidString: snapshot.id), !seen.contains(id),
                  let row = byID[id]
            else { continue }
            ordered.append(row)
            seen.insert(id)
        }
        return Outcome(rows: ordered, needsFullRefresh: false)
    }
}
