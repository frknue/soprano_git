import AppKit
import Testing
@testable import SopranoGit

struct DateTextTests {
    let utc = TimeZone(identifier: "UTC")!
    // 2026-03-20 12:00:00 UTC
    let now = Date(timeIntervalSince1970: 1_774_008_000)

    func relative(_ secondsAgo: TimeInterval) -> String {
        DateText.format(now.addingTimeInterval(-secondsAgo), style: .relative, now: now, timeZone: utc)
    }

    @Test func relativeDatesUnderAMinuteReadNow() {
        #expect(relative(0) == "now")
        #expect(relative(59) == "now")
        #expect(relative(-30) == "now")
    }

    @Test func relativeDatesUseMinuteHourDayAndWeekBuckets() {
        #expect(relative(5 * 60) == "5m")
        #expect(relative(59 * 60) == "59m")
        #expect(relative(3 * 3600) == "3h")
        #expect(relative(2 * 86_400) == "2d")
        #expect(relative(6 * 86_400) == "6d")
        #expect(relative(7 * 86_400) == "1w")
        #expect(relative(21 * 86_400) == "3w")
        #expect(relative(34 * 86_400) == "4w")
    }

    @Test func olderRelativeDatesShowMonthAndDayWithYearOnlyWhenDifferent() {
        #expect(relative(16 * 86_400 + 35 * 86_400) == "Jan 28")
        let older = DateText.format(
            Date(timeIntervalSince1970: 1_678_000_000), style: .relative, now: now, timeZone: utc)
        #expect(older == "Mar 5 2023")
    }

    @Test func absoluteDatesUseIsoDayAndMinute() {
        let date = Date(timeIntervalSince1970: 1_772_633_100) // 2026-03-04 14:05 UTC
        #expect(DateText.format(date, style: .absolute, now: now, timeZone: utc) == "2026-03-04 14:05")
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        #expect(DateText.format(date, style: .absolute, now: now, timeZone: berlin) == "2026-03-04 15:05")
    }
}
