import Foundation
import LocalObserverCore

/// The dashboard's profile line: which variant each day shows, and which stretch it reads. The January case is the
/// one that's easy to get wrong: Wrapped on January 1 to 7 is the year before, and the first days of a month recap
/// the month before, not the month they're in.
enum TeaserChecks {
    static func run() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2

        func noon(_ day: Int, month: Int, year: Int = 2026) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        }
        func key(_ day: Int, month: Int, year: Int = 2026) -> String? {
            ProfileTeaser.on(noon(day, month: month, year: year), calendar: calendar).dismissalKey(calendar: calendar)
        }

        // Days 1 to 5 recap the month before; the rest of the month is the quiet line.
        precondition(key(1, month: 10) == "recap-2026-9" && key(5, month: 10) == "recap-2026-9", "Days 1 to 5 recap last month")
        precondition(key(6, month: 10) == nil && key(12, month: 10) == nil && key(30, month: 11) == nil, "Other days are quiet")
        precondition(key(3, month: 2) == "recap-2026-1", "February recaps January")
        guard case .recap(let monthStart) = ProfileTeaser.on(noon(3, month: 10), calendar: calendar) else {
            preconditionFailure("October 3 should recap September")
        }
        precondition(monthStart == calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)), "The recap names September's first day")
        precondition(ProfileTeaser.on(noon(3, month: 10), calendar: calendar).period(calendar: calendar)
                     == .custom(DateInterval(start: calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!,
                                             end: calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!)),
                     "The recap reads the whole of September")

        // December is Wrapped for the year to date, and it takes over the first days of the month.
        precondition(key(1, month: 12) == "wrapped-2026" && key(2, month: 12) == "wrapped-2026" && key(31, month: 12) == "wrapped-2026",
                     "Wrapped all of December, not a recap of November")
        precondition(ProfileTeaser.on(noon(1, month: 12), calendar: calendar).period(calendar: calendar) == .calendarYear(2026, calendar: calendar),
                     "December's Wrapped reads the calendar year")

        // January 1 to 7 is Wrapped for the year before, not for the year it's in and not a recap of December.
        precondition(key(1, month: 1, year: 2027) == "wrapped-2026" && key(7, month: 1, year: 2027) == "wrapped-2026",
                     "Early January wraps the year before")
        precondition(key(5, month: 1, year: 2027) != "recap-2026-12", "Early January is Wrapped, not a December recap")
        precondition(ProfileTeaser.on(noon(3, month: 1, year: 2027), calendar: calendar).period(calendar: calendar) == .calendarYear(2026, calendar: calendar),
                     "January's Wrapped reads the year before")
        precondition(key(8, month: 1, year: 2027) == nil, "January 8 is quiet")

        // February onwards goes back to recaps of the month before.
        precondition(key(2, month: 2, year: 2027) == "recap-2027-1", "February 2027 recaps January 2027")

        // Dismissal keys are unique per month and per year, so one dismissal doesn't hide another. December and January
        // share Wrapped's key on purpose: it's one window.
        let keys = [key(1, month: 10), key(1, month: 11), key(1, month: 12), key(1, month: 2, year: 2027)].compactMap { $0 }
        precondition(Set(keys).count == keys.count, "Each recap and Wrapped has its own key")
    }
}
