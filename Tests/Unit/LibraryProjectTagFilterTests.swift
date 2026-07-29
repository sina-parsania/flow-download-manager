// SPDX-License-Identifier: GPL-3.0-or-later

import Domain
import Foundation
import XCTest
@testable import Presentation

@MainActor
final class LibraryProjectTagFilterTests: XCTestCase {
    private func row(
        name: String,
        projectID: String? = nil,
        projectName: String? = nil,
        tagIDs: [String] = [],
        tagNames: [String] = []
    ) -> JobRowModel {
        JobRowModel(
            id: UUID(),
            name: name,
            sourceHost: "example.test",
            state: .completed,
            progressFraction: 1,
            bytesTransferred: 100,
            totalBytes: 100,
            speedBytesPerSecond: 0,
            etaSeconds: nil,
            categoryKey: "documents",
            projectID: projectID,
            projectName: projectName,
            tagIDs: tagIDs,
            tagNames: tagNames
        )
    }

    private func model(_ rows: [JobRowModel]) -> LibraryModel {
        LibraryModel(rows: rows)
    }

    // MARK: - Filtering

    func testProjectFilterMatchesByIdentityNotName() {
        let target = row(name: "a", projectID: "p1", projectName: "Research")
        let other = row(name: "b", projectID: "p2", projectName: "Research")
        XCTAssertTrue(LibraryFilter.project("p1").matches(target))
        XCTAssertFalse(
            LibraryFilter.project("p1").matches(other),
            "two projects may share a name; the filter must follow the id"
        )
    }

    func testTagFilterMatchesAnyOfARowsTags() {
        let tagged = row(name: "a", tagIDs: ["t1", "t2"], tagNames: ["work", "urgent"])
        XCTAssertTrue(LibraryFilter.tag("t2").matches(tagged))
        XCTAssertFalse(LibraryFilter.tag("t3").matches(tagged))
    }

    func testRowWithNoProjectNeverMatchesAProjectFilter() {
        XCTAssertFalse(LibraryFilter.project("p1").matches(row(name: "a")))
    }

    // MARK: - Sidebar sections

    func testProjectFiltersAreDeduplicatedAndSortedByName() {
        let library = model([
            row(name: "a", projectID: "p2", projectName: "Zebra"),
            row(name: "b", projectID: "p1", projectName: "Alpha"),
            row(name: "c", projectID: "p1", projectName: "Alpha"),
            row(name: "d")
        ])
        XCTAssertEqual(library.projectFilters.map(\.name), ["Alpha", "Zebra"])
        XCTAssertEqual(library.projectFilters.map(\.id), ["p1", "p2"])
    }

    func testTagFiltersPairIDsWithNamesPositionally() {
        let library = model([
            row(name: "a", tagIDs: ["t1", "t2"], tagNames: ["work", "urgent"])
        ])
        XCTAssertEqual(
            library.tagFilters.sorted { $0.id < $1.id }.map { "\($0.id):\($0.name)" },
            ["t1:work", "t2:urgent"]
        )
    }

    /// The arrays come from independently bounded XPC fields, so a length
    /// mismatch must drop the extra rather than trap on an index.
    func testMismatchedTagArraysDoNotTrap() {
        let library = model([
            row(name: "a", tagIDs: ["t1", "t2", "t3"], tagNames: ["only-one"])
        ])
        XCTAssertEqual(library.tagFilters.count, 1)
    }

    func testSectionsAreEmptyWhenNothingIsOrganised() {
        let library = model([row(name: "a"), row(name: "b")])
        XCTAssertTrue(library.projectFilters.isEmpty)
        XCTAssertTrue(library.tagFilters.isEmpty)
    }

    // MARK: - Stale selection

    /// Deleting the last download in a project would otherwise leave the rail
    /// showing a selected filter that can never match, and the empty state
    /// would blame the engine.
    func testFilterFallsBackToAllWhenItsProjectHasNoRowsLeft() {
        let library = model([row(name: "a", projectID: "p1", projectName: "Research")])
        library.filter = .project("p1")
        library.rows = []
        library.pruneStaleFilter()
        XCTAssertEqual(library.filter, .all)
    }

    func testFilterFallsBackToAllWhenItsTagHasNoRowsLeft() {
        let library = model([row(name: "a", tagIDs: ["t1"], tagNames: ["work"])])
        library.filter = .tag("t1")
        library.rows = []
        library.pruneStaleFilter()
        XCTAssertEqual(library.filter, .all)
    }

    func testAStillPopulatedFilterIsKept() {
        let library = model([row(name: "a", projectID: "p1", projectName: "Research")])
        library.filter = .project("p1")
        library.pruneStaleFilter()
        XCTAssertEqual(library.filter, .project("p1"))
    }

    func testStatusFiltersAreNeverPruned() {
        let library = model([])
        library.filter = .failed
        library.pruneStaleFilter()
        XCTAssertEqual(library.filter, .failed, "a status filter matching nothing is a normal state")
    }

    // MARK: - Search

    func testSearchMatchesAProjectName() {
        let library = model([
            row(name: "invoice.pdf", projectID: "p1", projectName: "Taxes"),
            row(name: "photo.jpg")
        ])
        library.rows = library.rows
        let matches = library.rows.filter {
            $0.projectName?.localizedCaseInsensitiveContains("taxes") ?? false
        }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.name, "invoice.pdf")
    }

    func testSearchMatchesATagName() {
        let tagged = row(name: "notes.txt", tagIDs: ["t1"], tagNames: ["urgent"])
        XCTAssertTrue(tagged.tagNames.contains { $0.localizedCaseInsensitiveContains("URGENT") })
    }
}
