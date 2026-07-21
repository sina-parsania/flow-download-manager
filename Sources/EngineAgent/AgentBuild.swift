// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Build identity the agent reports over the control interface.
///
/// Phase 0 is the pre-1.0 foundation; each subsequent phase increments the minor
/// version, reaching `1.0.0` at Phase 5 (`00-master-plan.md` §5). The signed
/// release build overrides this from its bundle's `CFBundleShortVersionString`;
/// the command-line agent has no bundle of its own, so the constant is the source
/// of truth for the helper.
public enum AgentBuild {
    public static let version = "0.1.0"
}
