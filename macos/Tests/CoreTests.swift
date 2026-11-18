import Foundation

@main
struct CoreTests {
    static var checks = 0

    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else { fatalError("FAIL: \(message)") }
    }

    static func near(_ actual: Double, _ expected: Double, _ message: String) {
        check(abs(actual - expected) < 0.00001, "\(message): \(actual) != \(expected)")
    }

    static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value + "+08:00")!
    }

    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let engine = Engine(calendar: calendar)
        var settings = AppSettings()
        settings.amount = 800
        settings.startTime = "09:00"
        settings.endTime = "18:00"
        settings.lunchEnabled = true

        let cases: [(String, WorkState, Double, Double)] = [
            ("2026-11-10T08:59:59", .beforeWork, 0, 0),
            ("2026-11-10T09:00:00", .working, 0, 0),
            ("2026-11-10T11:00:00", .working, 200, 0.25),
            ("2026-11-10T12:00:00", .lunch, 300, 0.375),
            ("2026-11-10T12:59:59", .lunch, 300, 0.375),
            ("2026-11-10T13:00:00", .working, 300, 0.375),
            ("2026-11-10T18:00:00", .afterWork, 800, 1),
            ("2026-11-14T11:00:00", .restDay, 0, 0)
        ]
        for (time, state, earned, progress) in cases {
            let snapshot = engine.compute(settings, at: date(time))
            check(snapshot.state == state, "state at \(time)")
            near(snapshot.earned, earned, "earned at \(time)")
            near(snapshot.progress, progress, "progress at \(time)")
        }
        settings.overtime = true
        let overtime = engine.compute(settings, at: date("2026-11-10T20:00:00"))
        check(overtime.state == .overtime, "overtime state")
        near(overtime.earned, 1100, "overtime multiplier")
        near(overtime.progress, 1, "overtime doesn't inflate progress")
        settings.salaryMode = 1
        settings.amount = 17400
        near(settings.dailyPay, 800, "monthly salary uses configured 21.75 days")
        settings.overrideDate = "2026-11-14"
        settings.overrideMode = 2
        check(engine.compute(settings, at: date("2026-11-14T11:00:00")).state == .working, "makeup workday")
        check(engine.compute(settings, at: date("2026-11-15T11:00:00")).state == .restDay, "override expires")
        settings.overrideMode = 1
        settings.overrideDate = "2026-11-10"
        check(engine.compute(settings, at: date("2026-11-10T11:00:00")).state == .restDay, "leave day")

        settings = AppSettings()
        near(engine.monthEarned(settings, at: date("2026-11-10T14:00:00"), todayEarned: 50), 650, "past workdays assumed full attendance")
        near(engine.monthTotal(settings, at: date("2026-11-10T14:00:00")), 2100, "November 2026 has 21 weekdays")
        settings.payDay = 31
        check(engine.daysToPayDay(settings, at: date("2024-02-28T20:00:00")) == 1, "leap February payday")
        check(engine.daysToPayDay(settings, at: date("2023-02-28T20:00:00")) == 0, "short month payday")
        settings.payDay = 10
        check(engine.daysToPayDay(settings, at: date("2026-12-31T20:00:00")) == 10, "payday crosses year")
        check(engine.daysToPayDay(settings, at: date("2026-11-10T23:59:59")) == 0, "payday ignores time of day")
        try testHuaweiPayroll(calendar: calendar)
        settings.wishlist = "咖啡=30\n坏数据=nan\n负数=-2\n可乐＝3\n无限=infinity"
        check(settings.wishItems.map(\.name) == ["可乐", "咖啡"], "wishlist sorts finite positive prices")
        let snapshot = engine.compute(settings, at: date("2026-11-10T14:00:00"))
        check(engine.wishText(settings, snapshot: snapshot).contains("咖啡"), "achieved wish")
        settings.masked = true
        let report = engine.report(settings, at: date("2026-11-10T14:00:00"))
        check(report.contains("****") && !report.contains("44.44") && !report.contains("11.11"), "private report hides salary values")

        var invalid = AppSettings()
        for amount in [-1, Double.nan, Double.infinity, 1_000_000_001] {
            invalid.amount = amount
            check((try? invalid.validated()) == nil, "reject invalid salary \(amount)")
        }
        invalid = AppSettings()
        invalid.monthDays = 0
        check((try? invalid.validated()) == nil, "reject zero monthly divisor")
        invalid.monthDays = 1e-308
        invalid.salaryMode = 1
        check((try? invalid.validated()) == nil, "reject derived salary overflow")
        invalid = AppSettings()
        invalid.endTime = "09:00"
        check((try? invalid.validated()) == nil, "reject overnight schedule")
        invalid = AppSettings()
        invalid.lunchEnabled = true
        invalid.lunchEnd = "23:00"
        check((try? invalid.validated()) == nil, "reject lunch outside shift")
        invalid = AppSettings()
        invalid.lunchStart = invalid.startTime
        invalid.lunchEnd = invalid.endTime
        invalid.lunchEnabled = true
        check((try? invalid.validated()) == nil, "reject lunch consuming entire paid day")
        invalid = AppSettings()
        invalid.startTime = " 9：05 "
        check(try invalid.validated().startTime == "09:05", "normalize fullwidth colon")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        check(try store.load() == AppSettings(), "missing file loads defaults")
        let freshJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.load())) as! [String: Any]
        check(freshJSON["salaryConfigured"] as? Bool == false, "first launch explicitly marks example salary")
        var example = AppSettings()
        example.windowX = 120
        try store.save(example)
        check(try !store.load().salaryConfigured, "position persistence keeps example salary unconfigured")
        check(engine.report(example, at: date("2026-11-10T14:00:00")).contains("示例战报"), "example report identifies example salary")
        example.salaryConfigured = true
        check(!engine.report(example, at: date("2026-11-10T14:00:00")).contains("示例"), "configured report has no example marker")
        example.amount = 800
        example.startTime = "09:00"
        example.endTime = "18:00"
        example.lunchEnabled = true
        example.wishlist = "小目标=400"
        let beforeLunch = engine.compute(example, at: date("2026-11-10T11:50:00"))
        let wish = engine.wishText(example, snapshot: beforeLunch)
        check(wish.contains("再计薪") && !wish.contains("再过"), "wish crossing lunch explicitly describes paid time")
        settings.appName = "牛马 🫏 = 测试"
        settings.quotes = "反斜杠\\和等号=\n第二句"
        try store.save(settings)
        check(try store.load() == settings, "settings survive UTF8 and newline roundtrip")
        let original = try Data(contentsOf: store.fileURL)
        invalid.amount = .nan
        do { try store.save(invalid); fatalError("invalid save accepted") } catch {}
        check(try Data(contentsOf: store.fileURL) == original, "failed save preserves previous data")
        try Data("{\"amount\":200}".utf8).write(to: store.fileURL)
        check(try store.load().amount == 200 && store.load().decimals == 5, "missing fields get defaults")
        let legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.load())) as! [String: Any]
        check(legacyJSON["salaryConfigured"] as? Bool == true, "legacy settings count as configured salary")
        let workingTime = date("2026-11-10T14:00:00")
        check(engine.report(try store.load(), at: workingTime).contains("状态：上班中"), "legacy settings use the original status wording")
        let occupationJSON = #"""
        {"amount":234,"lunchEnabled":true,"overtime":true,"statusPreferences":{
          "selectedOccupationID":"cook",
          "overrides":{"general":null,"cook":{"working":"  🍳 掌勺中  ","lunch":42,"overtime":"坏\n文案"}},
          "customOccupations":[null,{"id":"test-profile","name":"面包师","labels":{"working":"烤面包"}}]
        }}
        """#
        try Data(occupationJSON.utf8).write(to: store.fileURL)
        let occupationSettings = try store.load()
        check(engine.report(occupationSettings, at: workingTime).contains("状态：🍳 掌勺中\n"), "report shows the selected occupation's custom status")
        check(engine.report(occupationSettings, at: date("2026-11-10T12:30:00")).contains("状态：歇一会儿\n"), "mistyped status falls back to the selected occupation")
        check(engine.report(occupationSettings, at: date("2026-11-10T21:00:00")).contains("状态：加班中\n"), "multiline status falls back independently")
        near(engine.compute(occupationSettings, at: workingTime).earned, 87.75, "custom wording preserves paid time and earned amount")
        check(occupationSettings.statusPreferences.customOccupations.map(\.name) == ["面包师"], "a malformed custom occupation does not discard the others")
        try store.save(occupationSettings)
        check(try store.load() == occupationSettings, "occupation settings round-trip after repairing individual invalid fields")
        try Data(#"{"amount":321,"statusPreferences":null}"#.utf8).write(to: store.fileURL)
        let fallback = try store.load()
        check(fallback.amount == 321 && fallback.statusPreferences.label(for: .working) == "上班中", "invalid status settings preserve unrelated pay settings")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: store.fileURL)
        do { _ = try store.load(); fatalError("corrupt file accepted") } catch {}
        check(try Data(contentsOf: store.fileURL) == corrupt, "load never overwrites corrupt settings")

        check(DigitRoller.offsets(value: 100, decimals: 2, speed: 0) == [1, 0, 0, 0, 0], "exact 100 carry")
        let rolling = DigitRoller.offsets(value: 9.999, decimals: 2, speed: 0.01)
        check(rolling[0] > 9 && rolling[0] <= 10, "nine rolls toward zero at carry")
        check(DigitRoller.offsets(value: 123.45, decimals: 2, speed: 0) == [1, 2, 3, 4, 5], "paused digits are exact")
        settings = AppSettings()
        settings.overtime = true
        settings.wishlist = "大目标=1e308"
        let largeWish = engine.compute(settings, at: date("2026-11-10T20:00:00"))
        check(!engine.wishText(settings, snapshot: largeWish).isEmpty, "huge finite wish doesn't overflow duration")
        print("PASS: \(checks) core checks")
    }

    private static func testHuaweiPayroll(calendar: Calendar) throws {
        let holidays = ChinaWorkCalendar("""
        # Synthetic additions cover month and year boundaries.
        year 2022
        year 2023
        year 2025
        year 2026
        year 2027
        2023-01-01 work
        2025-05-31 rest
        2026-02-28 work
        2027-01-31 work
        2027-05-15 work
        2027-09-15 rest
        """)
        let engine = Engine(calendar: calendar, holidays: holidays)
        var settings = AppSettings()
        settings.salaryMode = 2
        settings.huaweiBaseSalary = 21_000
        settings.huaweiPerformanceSalary = 4_200
        settings.huaweiAnnualBonus = 25_200
        settings.overtime = true

        let monday = date("2026-11-23T15:00:00")
        let saturday = date("2026-11-28T14:30:00")
        near(engine.huaweiPayroll.divisor(settings, in: monday), 21, "auto divisor excludes the extra Saturday")
        near(engine.compute(settings, at: monday).dailyPay, 1_300, "regular days include monthly performance and one twelfth of annual bonus")
        let special = engine.compute(settings, at: saturday)
        check(special.state == .working && special.huaweiDoublePay, "last Saturday is an independent double-pay workday")
        near(special.dailyPay, 2_000, "last Saturday pays twice base only")
        near(special.earned, 1_000, "double base accrues across the shift")
        let afterSaturday = engine.compute(settings, at: date("2026-11-28T20:00:00"))
        check(afterSaturday.state == .afterWork, "normal overtime does not extend double-pay Saturday past closing")
        near(afterSaturday.earned, 2_000, "double-pay Saturday caps at its daily rate")
        near(engine.monthTotal(settings, at: saturday), 29_300, "month total includes the double-pay day separately")
        near(engine.monthEarned(settings, at: saturday, todayEarned: special.earned), 27_000, "month earned uses completed regular days and elapsed double pay")
        check(engine.compute(settings, at: date("2026-11-21T11:00:00")).state == .restDay, "earlier Saturday is not automatically added")
        check(engine.compute(settings, at: date("2025-05-31T11:00:00")).state == .restDay, "official holiday cancels the last Saturday")

        let makeup = date("2026-02-28T11:00:00")
        let makeupSnapshot = engine.compute(settings, at: makeup)
        check(makeupSnapshot.state == .working && !makeupSnapshot.huaweiDoublePay, "official last-Saturday makeup pays as a regular day")
        near(engine.huaweiPayroll.divisor(settings, in: makeup), 21, "official weekend makeup is counted in the regular divisor")
        near(makeupSnapshot.dailyPay, 1_300, "regular rate applies to the last-Saturday official makeup")
        check(!engine.isWorkDay(settings, date("2027-01-30T11:00:00")), "candidate is canceled for a seven-day streak crossing months")
        let yearEnd = date("2022-12-31T11:00:00")
        check(!engine.isWorkDay(settings, yearEnd), "candidate is canceled for a seven-day streak crossing years")
        settings.overrideDate = "2023-01-01"
        settings.overrideMode = 1
        check(engine.compute(settings, at: yearEnd).huaweiDoublePay, "individual rest can break the streak so a six-day run is allowed")
        settings.overrideDate = "2026-11-28"
        check(!engine.isWorkDay(settings, saturday), "individual rest overrides special Saturday")
        settings.overrideMode = 2
        check(!engine.compute(settings, at: saturday).huaweiDoublePay, "individual makeup work pays the regular rate")
        near(engine.huaweiPayroll.divisor(settings, in: saturday), 21, "individual override does not change the automatic divisor")
        settings.overrideMode = 0
        settings.workDays.append(6)
        check(!engine.compute(settings, at: saturday).huaweiDoublePay, "configured weekly Saturday already pays as a regular day")
        settings.workDays.removeLast()
        settings.huaweiMonthDays = 20
        near(engine.compute(settings, at: monday).dailyPay, 1_365, "manual divisor replaces the scheduled day count")
        near(engine.compute(settings, at: saturday).dailyPay, 2_100, "manual divisor applies once to base double pay")
        settings.workDays = []
        settings.payDay = 27
        settings.overrideMode = 2
        settings.overrideDate = "2026-11-15"
        check(engine.daysToPayDay(settings, at: date("2026-11-13T20:00:00")) == 0, "Sunday payday rolls back to Friday independently of personal schedule")
        check(engine.daysToPayDay(settings, at: date("2027-09-14T20:00:00")) == 0, "official weekday holiday advances payday")
        check(engine.daysToPayDay(settings, at: date("2027-05-15T20:00:00")) == 0, "official makeup Saturday is a valid payday")
        check(engine.daysToPayDay(settings, at: date("2026-11-14T20:00:00")) == 31, "day after shifted payday counts toward the next month")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try store.save(settings)
        check(try store.load() == settings, "Huawei settings round-trip")
        settings.huaweiMonthDays = 0.5
        check((try? settings.validated()) == nil, "manual divisor values below one are rejected")
        settings.huaweiMonthDays = 0
        settings.huaweiAnnualBonus = -1
        check((try? settings.validated()) == nil, "negative annual bonus is rejected")

        if CommandLine.arguments.count > 1 {
            let data = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            let official = Engine(calendar: calendar, holidays: ChinaWorkCalendar(data))
            settings = AppSettings()
            settings.salaryMode = 2
            check(official.huaweiPayroll.hasOfficialSchedule(for: makeup), "shared calendar covers 2026")
            check(official.huaweiPayroll.workDay(settings, on: makeup) == .regular, "shared calendar includes the official February makeup")
            check(!official.isWorkDay(settings, date("2025-05-31T11:00:00")), "shared calendar includes the official May holiday")
            check(!official.isWorkDay(settings, date("2027-01-30T11:00:00")), "shared calendar cancels the January streak")
            check(official.daysToPayDay(settings, at: date("2027-09-14T20:00:00")) == 0, "shared calendar advances September payday")
        }
    }
}
