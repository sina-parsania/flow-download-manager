// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One calendar window when a bandwidth policy applies (FR-QUE).
///
/// - `weekday`: `1...7` matching `Calendar` weekday (1 = Sunday), or `nil` for every day.
/// - `startMinute` / `endMinute`: minutes from local midnight in `0...1439`.
///   When `endMinute > startMinute`, the half-open interval is `[start, end)`.
///   When `endMinute <= startMinute`, the window wraps midnight.
public struct BandwidthWindow: Sendable, Equatable, Codable {
    public var weekday: Int?
    public var startMinute: Int
    public var endMinute: Int

    public init(weekday: Int?, startMinute: Int, endMinute: Int) {
        self.weekday = weekday
        self.startMinute = startMinute
        self.endMinute = endMinute
    }
}

/// Pure evaluator for calendar bandwidth windows.
public enum BandwidthWindowEvaluator {
    public enum ParseError: Error, Equatable, Sendable {
        case malformedJSON
        case invalidWindow
    }

    /// Parses `[{ "weekday": 1-7|null, "startMinute": 0-1439, "endMinute": 0-1439 }, ...]`.
    public static func parseWindowsJSON(_ json: String) throws -> [BandwidthWindow] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let data = trimmed.data(using: .utf8) else {
            throw ParseError.malformedJSON
        }
        let decoder = JSONDecoder()
        let windows: [BandwidthWindow]
        do {
            windows = try decoder.decode([BandwidthWindow].self, from: data)
        } catch {
            throw ParseError.malformedJSON
        }
        for window in windows {
            guard isValid(window) else { throw ParseError.invalidWindow }
        }
        return windows
    }

    public static func encodeWindowsJSON(_ windows: [BandwidthWindow]) throws -> String {
        for window in windows {
            guard isValid(window) else { throw ParseError.invalidWindow }
        }
        let data = try JSONEncoder().encode(windows)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ParseError.malformedJSON
        }
        return string
    }

    /// Preset: every day from 00:00 up to (but not including) 08:00 local time.
    public static let dailyMidnightToEightPreset = BandwidthWindow(
        weekday: nil,
        startMinute: 0,
        endMinute: 480
    )

    public static func isValid(_ window: BandwidthWindow) -> Bool {
        if let weekday = window.weekday, !(1 ... 7).contains(weekday) {
            return false
        }
        guard (0 ... 1439).contains(window.startMinute),
              (0 ... 1439).contains(window.endMinute)
        else {
            return false
        }
        return true
    }

    /// Returns `true` when budgets should apply / transfers may start.
    ///
    /// An empty window list is always active (rate limit, if any, applies all day).
    public static func isActive(
        now: Date,
        calendar: Calendar,
        windows: [BandwidthWindow]
    ) -> Bool {
        guard !windows.isEmpty else { return true }
        let weekday = calendar.component(.weekday, from: now)
        let minuteOfDay = calendar.component(.hour, from: now) * 60
            + calendar.component(.minute, from: now)
        return windows.contains { window in
            matches(window: window, weekday: weekday, minuteOfDay: minuteOfDay)
        }
    }

    private static func matches(
        window: BandwidthWindow,
        weekday: Int,
        minuteOfDay: Int
    ) -> Bool {
        if let required = window.weekday, required != weekday {
            return false
        }
        if window.endMinute > window.startMinute {
            return minuteOfDay >= window.startMinute && minuteOfDay < window.endMinute
        }
        // Wraps midnight: active from start through end of day, and from 00:00 until end.
        return minuteOfDay >= window.startMinute || minuteOfDay < window.endMinute
    }
}
