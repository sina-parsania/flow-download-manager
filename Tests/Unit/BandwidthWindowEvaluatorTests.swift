// SPDX-License-Identifier: GPL-3.0-or-later

import Application
import XCTest

final class BandwidthWindowEvaluatorTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return cal
    }

    /// Builds a UTC instant on the week of 2026-07-19 (Sunday = weekday 1).
    private func date(weekday: Int, hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 18 + weekday
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard let value = calendar.date(from: components) else {
            preconditionFailure("test fixture date")
        }
        return value
    }

    func testEmptyWindowsAlwaysActive() {
        XCTAssertTrue(
            BandwidthWindowEvaluator.isActive(now: Date(), calendar: calendar, windows: [])
        )
    }

    func testDailyWindowActiveInside() {
        let windows = [BandwidthWindowEvaluator.dailyMidnightToEightPreset]
        let inside = date(weekday: 3, hour: 3, minute: 30)
        XCTAssertEqual(calendar.component(.weekday, from: inside), 3)
        XCTAssertTrue(BandwidthWindowEvaluator.isActive(now: inside, calendar: calendar, windows: windows))
    }

    func testDailyWindowInactiveOutside() {
        let windows = [BandwidthWindowEvaluator.dailyMidnightToEightPreset]
        let outside = date(weekday: 3, hour: 8, minute: 0)
        XCTAssertFalse(
            BandwidthWindowEvaluator.isActive(now: outside, calendar: calendar, windows: windows)
        )
        let late = date(weekday: 3, hour: 22, minute: 0)
        XCTAssertFalse(
            BandwidthWindowEvaluator.isActive(now: late, calendar: calendar, windows: windows)
        )
    }

    func testWeekdayScopedWindow() {
        let mondayOnly = BandwidthWindow(weekday: 2, startMinute: 0, endMinute: 480)
        let mondayMorning = date(weekday: 2, hour: 1, minute: 0)
        let tuesdayMorning = date(weekday: 3, hour: 1, minute: 0)
        XCTAssertTrue(
            BandwidthWindowEvaluator.isActive(
                now: mondayMorning, calendar: calendar, windows: [mondayOnly]
            )
        )
        XCTAssertFalse(
            BandwidthWindowEvaluator.isActive(
                now: tuesdayMorning, calendar: calendar, windows: [mondayOnly]
            )
        )
    }

    func testWrapAroundMidnightWindow() {
        let overnight = BandwidthWindow(weekday: nil, startMinute: 22 * 60, endMinute: 6 * 60)
        let late = date(weekday: 4, hour: 23, minute: 0)
        let early = date(weekday: 4, hour: 5, minute: 0)
        let midday = date(weekday: 4, hour: 12, minute: 0)
        XCTAssertTrue(BandwidthWindowEvaluator.isActive(now: late, calendar: calendar, windows: [overnight]))
        XCTAssertTrue(BandwidthWindowEvaluator.isActive(now: early, calendar: calendar, windows: [overnight]))
        XCTAssertFalse(BandwidthWindowEvaluator.isActive(now: midday, calendar: calendar, windows: [overnight]))
    }

    func testParseAndEncodeRoundTrip() throws {
        let json = #"[{"weekday":null,"startMinute":0,"endMinute":480}]"#
        let windows = try BandwidthWindowEvaluator.parseWindowsJSON(json)
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows[0].weekday)
        XCTAssertEqual(windows[0].startMinute, 0)
        XCTAssertEqual(windows[0].endMinute, 480)
        let encoded = try BandwidthWindowEvaluator.encodeWindowsJSON(windows)
        let again = try BandwidthWindowEvaluator.parseWindowsJSON(encoded)
        XCTAssertEqual(again, windows)
    }

    func testParseRejectsInvalidMinutes() {
        XCTAssertThrowsError(
            try BandwidthWindowEvaluator.parseWindowsJSON(
                #"[{"weekday":null,"startMinute":0,"endMinute":2000}]"#
            )
        ) { error in
            XCTAssertEqual(error as? BandwidthWindowEvaluator.ParseError, .invalidWindow)
        }
    }

    func testParseRejectsInvalidWeekday() {
        XCTAssertThrowsError(
            try BandwidthWindowEvaluator.parseWindowsJSON(
                #"[{"weekday":9,"startMinute":0,"endMinute":60}]"#
            )
        ) { error in
            XCTAssertEqual(error as? BandwidthWindowEvaluator.ParseError, .invalidWindow)
        }
    }
}
