// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB

/// Central GRDB `Configuration` for the engine's database.
///
/// WAL mode is provided by `DatabasePool`; this configuration adds foreign-key
/// enforcement and an explicit busy timeout (`02-architecture.md` §9). The agent
/// is the sole writer; the app never opens a competing writable connection.
public enum DatabaseConfiguration {
    /// Default busy timeout for writer contention against WAL readers.
    public static let defaultBusyTimeout: TimeInterval = 5

    public static func make(busyTimeout: TimeInterval = defaultBusyTimeout) -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(busyTimeout)
        config.prepareDatabase { db in
            // NORMAL synchronous is the standard, durable WAL setting; checkpoints
            // are managed explicitly by the writer policy in the Persistence slice.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return config
    }
}
