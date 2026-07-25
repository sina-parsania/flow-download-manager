// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Persistence
import XCTest

final class FinalizationReconcilerTests: XCTestCase {
    func testPreparedPartialOnlyResumesPromotion() {
        let plan = FinalizationReconciler.plan(
            intent: FinalizationIntentSnapshot(
                stage: .prepared,
                expectedByteSize: 128,
                zipAutoExtract: false
            ),
            snapshot: .partialOnly(partialSize: 128)
        )
        XCTAssertEqual(plan, .resumePromotion)
    }

    func testPreparedFinalOnlyAdvancesToPostProcessing() {
        let plan = FinalizationReconciler.plan(
            intent: FinalizationIntentSnapshot(
                stage: .prepared,
                expectedByteSize: 64,
                zipAutoExtract: false
            ),
            snapshot: .finalOnly(finalSize: 64)
        )
        XCTAssertEqual(plan, .completeWithoutPostProcessing)
    }

    func testPreparedBothFilesIsAmbiguous() {
        let plan = FinalizationReconciler.plan(
            intent: FinalizationIntentSnapshot(
                stage: .prepared,
                expectedByteSize: 10,
                zipAutoExtract: false
            ),
            snapshot: .both(partialSize: 10, finalSize: 10)
        )
        XCTAssertEqual(plan, .failAmbiguousFiles)
    }

    func testPromotedFinalOnlyRunsPostProcessingWhenZipEnabled() {
        let plan = FinalizationReconciler.plan(
            intent: FinalizationIntentSnapshot(
                stage: .promoted,
                expectedByteSize: 32,
                zipAutoExtract: true
            ),
            snapshot: .finalOnly(finalSize: 32)
        )
        XCTAssertEqual(plan, .runPostProcessing)
    }
}
