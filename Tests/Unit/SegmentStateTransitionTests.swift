// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import XCTest

/// Exhaustive coverage of the segment state machine (`04-domain-and-data-contracts.md`
/// §4). Every ordered pair is asserted against an independently written table.
final class SegmentStateTransitionTests: XCTestCase {
    private let expected: [SegmentState: Set<SegmentState>] = [
        .planned: [.connecting, .cancelled],
        .connecting: [.active, .retryWaiting, .cancelled],
        .active: [.checkpointing, .retryWaiting, .cancelled],
        .checkpointing: [.complete, .active],
        .retryWaiting: [.connecting, .active, .cancelled],
        .complete: [],
        .cancelled: []
    ]

    func testEveryOrderedPairMatchesContract() {
        for from in SegmentState.allCases {
            for to in SegmentState.allCases {
                let allowed = expected[from, default: []].contains(to)
                XCTAssertEqual(
                    from.canTransition(to: to), allowed,
                    "\(from) → \(to) should be \(allowed ? "allowed" : "forbidden")"
                )
            }
        }
    }

    func testTerminalStatesHaveNoOutgoing() {
        for terminal in [SegmentState.complete, .cancelled] {
            for target in SegmentState.allCases {
                XCTAssertFalse(terminal.canTransition(to: target), "\(terminal) → \(target)")
            }
        }
    }

    func testHappyPath() {
        XCTAssertTrue(SegmentState.planned.canTransition(to: .connecting))
        XCTAssertTrue(SegmentState.connecting.canTransition(to: .active))
        XCTAssertTrue(SegmentState.active.canTransition(to: .checkpointing))
        XCTAssertTrue(SegmentState.checkpointing.canTransition(to: .complete))
    }

    func testCompleteOnlyFromCheckpointing() {
        let predecessors = SegmentState.allCases.filter { $0.canTransition(to: .complete) }
        XCTAssertEqual(predecessors, [.checkpointing])
    }

    func testCancellationSetMatchesContract() {
        // §4's cancellation sources: planned|connecting|active|retryWaiting.
        for state in [SegmentState.planned, .connecting, .active, .retryWaiting] {
            XCTAssertTrue(state.canTransition(to: .cancelled), "\(state) → cancelled")
        }
        // checkpointing/complete/cancelled cannot cancel directly.
        for state in [SegmentState.checkpointing, .complete, .cancelled] {
            XCTAssertFalse(state.canTransition(to: .cancelled), "\(state) → cancelled must be forbidden")
        }
    }
}
