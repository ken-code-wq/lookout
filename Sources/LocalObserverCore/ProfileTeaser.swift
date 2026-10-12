import Foundation

// The dashboard's line about the You page, chosen by the day: days 1 to 5 recap the month before, December through
// January 7 is Wrapped for the year (the year before, in early January), and every other day is quiet. Pure, so the
// windows are checked without the UI. A recap or Wrapped can be dismissed for its month or year; the quiet line can't.

public enum ProfileTeaser: Hashable, Sendable {
    /// Days 1 to 5: the month before, named by its first day.
    case recap(monthStart: Date)
    /// December 1 to January 7: a calendar year, to date while it's still under way.
    case wrapped(year: Int)
    /// Any other day: this month, read as it stands.
    case quiet

    /// The variant `date` shows, read on `calendar`.
    public static func on(_ date: Date, calendar: Calendar = .current) -> ProfileTeaser {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        // Wrapped wins over the recap: December's first five days belong to the year, not to November.
        if month == 12 { return .wrapped(year: year) }
        if month == 1 && day <= 7 { return .wrapped(year: year - 1) }
        if day <= 5, let start = calendar.dateInterval(of: .month, for: date)?.start,
           let previous = calendar.date(byAdding: .month, value: -1, to: start) {
            return .recap(monthStart: previous)
        }
        return .quiet
    }

    /// The stretch the teaser reads its numbers from: last month, the calendar year, or this month.
    public func period(calendar: Calendar = .current) -> ProfilePeriod {
        switch self {
        case .recap(let monthStart):
            return .custom(calendar.dateInterval(of: .month, for: monthStart) ?? DateInterval(start: monthStart, duration: 0))
        case .wrapped(let year): return .calendarYear(year, calendar: calendar)
        case .quiet: return .month
        }
    }

    /// Names the recap's month or Wrapped's year, so a dismissed one stays dismissed until it's replaced. Nil for the
    /// quiet line, which has nothing to dismiss.
    public func dismissalKey(calendar: Calendar = .current) -> String? {
        switch self {
        case .recap(let monthStart):
            let parts = calendar.dateComponents([.year, .month], from: monthStart)
            return "recap-\(parts.year ?? 0)-\(parts.month ?? 0)"
        case .wrapped(let year): return "wrapped-\(year)"
        case .quiet: return nil
        }
    }
}
