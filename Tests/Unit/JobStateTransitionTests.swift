// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import XCTest

/// Exhaustive coverage of the job state machine (`04-domain-and-data-contracts.md`
/// §3). Every ordered pair of the 16 states is asserted against an independently
/// written expectation table, and the spec's named rules are checked directly so
/// the two encodings cannot silently drift together.
final class JobStateTransitionTests: XCTestCase {
    /// Expected adjacency, authored from the contract independently of the Domain
    /// implementation. Any pair not listed is forbidden (including self-loops).
    private let expected: [JobState: Set<JobState>] = [
        .created: [.inspecting, .cancelled],
        .inspecting: [.awaitingUserSelection, .ready, .failed, .cancelled],
        .awaitingUserSelection: [.ready, .cancelled, .failed],
        .ready: [.queued, .scheduled, .cancelled],
        .queued: [.connecting, .scheduled, .paused, .cancelled, .failed],
        .scheduled: [.queued, .connecting, .paused, .cancelled],
        .connecting: [.downloading, .retryWaiting, .paused, .failed, .cancelled],
        .downloading: [.verifying, .merging, .paused, .retryWaiting, .failed, .cancelled],
        .paused: [.connecting, .queued, .cancelled, .failed],
        .retryWaiting: [.connecting, .cancelled, .failed],
        .verifying: [.merging, .postProcessing, .retryWaiting, .failed, .cancelled],
        .merging: [.verifying, .postProcessing, .failed, .cancelled],
        .postProcessing: [.completed, .failed, .cancelled],
        .completed: [],
        .failed: [.ready, .queued],
        .cancelled: [.ready, .queued]
    ]

    func testEveryOrderedPairMatchesContract() {
        for from in JobState.allCases {
            for to in JobState.allCases {
                let allowed = expected[from, default: []].contains(to)
                XCTAssertEqual(
                    from.canTransition(to: to), allowed,
                    "\(from) → \(to) should be \(allowed ? "allowed" : "forbidden")"
                )
            }
        }
    }

    func testNoSelfTransitions() {
        for state in JobState.allCases {
            XCTAssertFalse(state.canTransition(to: state), "\(state) → \(state) must be forbidden")
        }
    }

    // --- Named rules from the contract, asserted independently of the table. ---

    func testVerifyingToCompletedIsIllegal() {
        XCTAssertFalse(JobState.verifying.canTransition(to: .completed))
    }

    func testCompletionOnlyThroughPostProcessing() {
        // The single legal predecessor of `completed`.
        let predecessors = JobState.allCases.filter { $0.canTransition(to: .completed) }
        XCTAssertEqual(predecessors, [.postProcessing])
    }

    func testCompletedIsAbsolutelyTerminal() {
        for target in JobState.allCases {
            XCTAssertFalse(JobState.completed.canTransition(to: target))
        }
    }

    func testFailedAndCancelledRestartOnlyToReadyOrQueued() {
        for terminal in [JobState.failed, .cancelled] {
            for target in JobState.allCases {
                let allowed = terminal.canTransition(to: target)
                if target == .ready || target == .queued {
                    XCTAssertTrue(allowed, "\(terminal) → \(target) should be allowed (restart)")
                } else {
                    XCTAssertFalse(allowed, "\(terminal) → \(target) should be forbidden")
                }
            }
        }
    }

    func testCreatedRequiresInspectionBeforeTransfer() {
        XCTAssertTrue(JobState.created.canTransition(to: .inspecting))
        XCTAssertFalse(JobState.created.canTransition(to: .downloading))
        XCTAssertFalse(JobState.created.canTransition(to: .ready))
    }

    func testPauseAndResumeShape() {
        XCTAssertTrue(JobState.downloading.canTransition(to: .paused))
        XCTAssertTrue(JobState.paused.canTransition(to: .connecting))
    }
}
