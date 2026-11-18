import Foundation

struct ChinaWorkCalendar {
    enum Adjustment: String { case rest, work }

    static let bundled: Self = {
        guard let url = Bundle.main.url(forResource: "china-work-calendar", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return Self("") }
        return Self(contents)
    }()

    private struct Month: Hashable {
        let year: Int
        let month: Int
    }

    private(set) var years: Set<Int> = []
    private var months: [Month: [Int: Adjustment]] = [:]

    init(_ contents: String) {
        for line in contents.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            if fields[0] == "year", let year = Int(fields[1]) {
                years.insert(year)
                continue
            }
            let date = fields[0].split(separator: "-")
            guard date.count == 3, let year = Int(date[0]), let month = Int(date[1]), let day = Int(date[2]),
                  (1...12).contains(month), (1...31).contains(day), let value = Adjustment(rawValue: String(fields[1]))
            else { continue }
            months[Month(year: year, month: month), default: [:]][day] = value
        }
    }

    func adjustments(in parts: DateComponents) -> [Int: Adjustment] {
        guard let year = parts.year, let month = parts.month else { return [:] }
        return months[Month(year: year, month: month)] ?? [:]
    }
}

struct HuaweiPayroll {
    enum WorkDay { case rest, regular, doubleBase }

    let calendar: Calendar
    let holidays: ChinaWorkCalendar

    private func weekdayWork(_ parts: DateComponents, workDays: [Int]) -> Bool {
        workDays.contains((parts.weekday ?? 1) - 1)
    }

    private func individualOverride(_ settings: AppSettings, _ parts: DateComponents) -> WorkDay? {
        guard settings.overrideMode != 0,
              let year = parts.year, let month = parts.month, let day = parts.day,
              settings.overrideDate == String(format: "%04d-%02d-%02d", year, month, day) else { return nil }
        return settings.overrideMode == 2 ? .regular : .rest
    }

    private func scheduledWork(_ parts: DateComponents, workDays: [Int]) -> Bool {
        if let day = parts.day, let adjustment = holidays.adjustments(in: parts)[day] {
            return adjustment == .work
        }
        return weekdayWork(parts, workDays: workDays)
    }

    func workDay(_ settings: AppSettings, on date: Date) -> WorkDay {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        if let individual = individualOverride(settings, parts) { return individual }
        guard let day = parts.day else { return .rest }
        if let adjustment = holidays.adjustments(in: parts)[day] {
            return adjustment == .work ? .regular : .rest
        }
        if weekdayWork(parts, workDays: settings.workDays) { return .regular }
        guard parts.weekday == 7, let days = calendar.range(of: .day, in: .month, for: date),
              day + 7 >= days.upperBound else { return .rest }

        var consecutive = 1
        for step in [-1, 1] {
            var adjacent = date
            while let next = calendar.date(byAdding: .day, value: step, to: adjacent) {
                let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: next)
                let works = individualOverride(settings, parts).map { $0 != .rest }
                    ?? scheduledWork(parts, workDays: settings.workDays)
                if !works { break }
                consecutive += 1
                if consecutive >= 7 { return .rest }
                adjacent = next
            }
        }
        return .doubleBase
    }

    func divisor(_ settings: AppSettings, in month: Date) -> Double {
        if settings.huaweiMonthDays > 0 { return settings.huaweiMonthDays }
        guard let days = calendar.range(of: .day, in: .month, for: month) else { return 0 }
        var parts = calendar.dateComponents([.year, .month], from: month)
        parts.day = 1
        guard let first = calendar.date(from: parts) else { return 0 }
        let firstWeekday = calendar.component(.weekday, from: first) - 1
        let adjustments = holidays.adjustments(in: parts)
        return Double(days.reduce(into: 0) { number, day in
            if let adjustment = adjustments[day] {
                if adjustment == .work { number += 1 }
            } else if settings.workDays.contains((firstWeekday + day - 1) % 7) {
                number += 1
            }
        })
    }

    func rates(_ settings: AppSettings, in month: Date) -> (regular: Double, doubleBase: Double) {
        let days = divisor(settings, in: month)
        guard days > 0 else { return (0, 0) }
        let monthlySalary = settings.huaweiBaseSalary + settings.huaweiPerformanceSalary + settings.huaweiAnnualBonus / 12
        let baseDaily = settings.huaweiBaseSalary / days
        return (monthlySalary / days, 2 * baseDaily)
    }

    func payday(in month: Date) -> Date {
        var parts = calendar.dateComponents([.year, .month], from: month)
        parts.day = 15
        var target = calendar.date(from: parts)!
        while !scheduledWork(calendar.dateComponents([.year, .month, .day, .weekday], from: target),
                             workDays: [1, 2, 3, 4, 5]) {
            target = calendar.date(byAdding: .day, value: -1, to: target)!
        }
        return target
    }

    func hasOfficialSchedule(for month: Date) -> Bool {
        holidays.years.contains(calendar.component(.year, from: month))
    }
}
