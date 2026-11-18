using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;

namespace NiuMa
{
    internal static class ChinaWorkCalendar
    {
        static readonly Dictionary<DateTime, bool> Exceptions = new Dictionary<DateTime, bool>();
        static readonly HashSet<int> Years = new HashSet<int>();

        static ChinaWorkCalendar()
        {
            var stream = typeof(ChinaWorkCalendar).Assembly.GetManifestResourceStream("NiuMa.ChinaWorkCalendar");
            if (stream == null) return;

            using (var reader = new StreamReader(stream))
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    var fields = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                    if (fields.Length != 2) continue;
                    int year;
                    DateTime date;
                    if (fields[0] == "year" && int.TryParse(fields[1], NumberStyles.None, CultureInfo.InvariantCulture, out year))
                        Years.Add(year);
                    else if ((fields[1] == "work" || fields[1] == "rest") &&
                        DateTime.TryParseExact(fields[0], "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out date))
                        Exceptions[date] = fields[1] == "work";
                }
            }
        }

        internal static bool HasYear(int year) { return Years.Contains(year); }

        internal static bool TryGetWorkDay(DateTime date, out bool workDay)
        {
            return Exceptions.TryGetValue(date.Date, out workDay);
        }

        internal static bool IsOfficialWorkDay(DateTime date)
        {
            bool workDay;
            if (TryGetWorkDay(date, out workDay)) return workDay;
            return date.DayOfWeek != DayOfWeek.Saturday && date.DayOfWeek != DayOfWeek.Sunday;
        }
    }

    internal sealed class HuaweiPayroll
    {
        internal enum WorkDay { Rest, Ordinary, MonthEndOvertime }

        internal struct MonthRates
        {
            internal double Days;
            internal double OrdinaryPay;
            internal double OvertimePay;

            internal double PayFor(WorkDay workDay)
            {
                if (workDay == WorkDay.Rest) return 0;
                return workDay == WorkDay.MonthEndOvertime ? OvertimePay : OrdinaryPay;
            }
        }

        readonly AppSettings _settings;
        readonly bool[] _week;

        internal HuaweiPayroll(AppSettings settings)
        {
            _settings = settings;
            _week = settings.WorkDaySet();
        }

        bool HasPersonalOverride(DateTime date)
        {
            return _settings.OverrideMode != 0 && _settings.OverrideDate == Engine.DateKey(date);
        }

        bool IsOrdinaryDay(DateTime date, bool includePersonalOverride)
        {
            if (includePersonalOverride && HasPersonalOverride(date)) return _settings.OverrideMode == 2;
            bool official;
            return ChinaWorkCalendar.TryGetWorkDay(date, out official) ? official : _week[(int)date.DayOfWeek];
        }

        internal WorkDay Day(DateTime date, bool includePersonalOverride = true)
        {
            if (includePersonalOverride && HasPersonalOverride(date))
                return _settings.OverrideMode == 2 ? WorkDay.Ordinary : WorkDay.Rest;

            bool official;
            if (ChinaWorkCalendar.TryGetWorkDay(date, out official)) return official ? WorkDay.Ordinary : WorkDay.Rest;
            if (_week[(int)date.DayOfWeek]) return WorkDay.Ordinary;
            if (date.DayOfWeek != DayOfWeek.Saturday || date.Day + 7 <= DateTime.DaysInMonth(date.Year, date.Month))
                return WorkDay.Rest;

            int consecutive = 1;
            for (int offset = 1; consecutive < 7 && IsOrdinaryDay(date.AddDays(-offset), includePersonalOverride); offset++)
                consecutive++;
            for (int offset = 1; consecutive < 7 && IsOrdinaryDay(date.AddDays(offset), includePersonalOverride); offset++)
                consecutive++;
            return consecutive >= 7 ? WorkDay.Rest : WorkDay.MonthEndOvertime;
        }

        internal MonthRates Rates(DateTime month)
        {
            double days = _settings.HuaweiMonthDays;
            if (!(days >= 1 && days <= 31))
            {
                days = 0;
                int lastDay = DateTime.DaysInMonth(month.Year, month.Month);
                for (int day = 1; day <= lastDay; day++)
                    if (IsOrdinaryDay(new DateTime(month.Year, month.Month, day), false)) days++;
            }
            if (days == 0) return new MonthRates();

            double basePay = ValidPay(_settings.HuaweiBasePay);
            double monthlyPay = basePay + ValidPay(_settings.HuaweiPerformancePay) + ValidPay(_settings.HuaweiAnnualBonus) / 12;
            return new MonthRates { Days = days, OrdinaryPay = monthlyPay / days, OvertimePay = (basePay / days) * 2 };
        }

        static double ValidPay(double amount) { return amount >= 0 && amount <= 1e9 ? amount : 0; }

        internal static DateTime PayDate(DateTime month)
        {
            var date = new DateTime(month.Year, month.Month, 15);
            while (!ChinaWorkCalendar.IsOfficialWorkDay(date)) date = date.AddDays(-1);
            return date;
        }
    }
}
