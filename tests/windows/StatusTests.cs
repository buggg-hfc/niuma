using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
#if WINDOWS_UI_TESTS
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
#endif

namespace NiuMa
{
    static class StatusTests
    {
        static int checks;

        static void Check(bool condition, string message)
        {
            checks++;
            if (!condition) throw new InvalidOperationException(message);
        }

        [STAThread]
        public static int Main()
        {
            try
            {
                CheckCore();
                CheckHuawei();
#if WINDOWS_UI_TESTS
                CheckEditor();
#endif
                Console.WriteLine("PASS: {0} Windows checks", checks);
                return 0;
            }
            catch (Exception error)
            {
                Console.Error.WriteLine(error);
                return 1;
            }
        }

        static void CheckCore()
        {
            var time = new DateTime(2026, 11, 18, 11, 0, 0);
            var settings = new AppSettings { LunchEnabled = true };
            var status = settings.StatusPreferences;
            Check(status.Occupations.Select(preset => preset.Name).SequenceEqual(new[] {
                "通用", "上钟 / 下钟", "厨师", "建筑工人", "程序员"
            }), "built-ins match macOS");
            var phases = new[] {
                time.AddHours(-2), time, time.AddHours(1), time.AddHours(9), time.AddHours(9), time.AddDays(3)
            };
            status.SetOverrides(StatusPreferences.States.ToDictionary(state => state, state => "新文案 " + state));
            for (int i = 0; i < phases.Length; i++)
            {
                settings.Overtime = i == 3;
                var expected = StatusPreferences.States[i];
                Check(Engine.Compute(settings, phases[i]).State == expected, "payroll phase remains " + expected);
                Check(Engine.Report(settings, phases[i]).Contains("状态：新文案 " + expected + "\n"), "report resolves status from the same snapshot");
            }
            Check(status.MiniLabel(Engine.Compute(settings, time)).EndsWith("后下班"), "mini displays the working countdown");
            Check(status.MiniLabel(Engine.Compute(settings, phases[2])) == "新文案 Lunch", "mini uses custom text outside active work");
            var before = Engine.Compute(settings, time);
            status.Select("onClock");
            Check(status.Label(WorkState.Working) == "上钟中", "on-clock preset uses default wording");
            var after = Engine.Compute(settings, time);
            Check(before.Earned == after.Earned && before.SecondsToNext == after.SecondsToNext, "switching occupation preserves pay and countdown");
            status.SetOverrides(new Dictionary<WorkState, string> { { WorkState.Working, "  当班中 🎤 = \\  " } });
            var cancelled = settings.Clone();
            cancelled.StatusPreferences.AddOccupation("取消的职业");
            Check(!status.Occupations.Any(preset => preset.Name == "取消的职业"), "editing a clone preserves the source configuration");
            status.AddOccupation("驻场演出");
            Check(status.Override(WorkState.Working) == null && status.Label(WorkState.Working) == "当班中 🎤 = \\", "custom occupation captures all effective defaults");
            status.SetOverrides(new Dictionary<WorkState, string> { { WorkState.Lunch, "  排练间歇  " } });
            status.Select("general");
            Check(status.Label(WorkState.Working) == "新文案 Working", "each occupation remembers its own edits");
            status.Select(status.Occupations.Last().Id);
            settings.Masked = true;
            Check(Engine.Report(settings, time).Contains("状态：当班中 🎤 = \\\n今日已赚：**** / ****"), "report keeps the full status while hiding pay");

            string directory = Path.Combine(Path.GetTempPath(), "niuma-windows-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            try
            {
                var file = Path.Combine(directory, "settings.ini");
                File.WriteAllText(file, "Amount=321\r\nTopmost=False\r\n", Encoding.UTF8);
                var legacy = AppSettings.LoadFrom(file);
                Check(legacy.Amount == 321 && !legacy.Topmost && legacy.StatusPreferences.Label(WorkState.Working) == "上班中", "legacy INI retains settings and original wording");
                settings.Amount = 321;
                settings.SaveTo(file);
                File.AppendAllText(file, "Status.Override." + status.Selected.Id + ".Overtime=bad\\ntext\r\n");
                var loaded = AppSettings.LoadFrom(file);
                Check(loaded.Amount == settings.Amount && loaded.Masked && loaded.StatusPreferences.Selected.Name == "驻场演出", "occupation and ordinary settings round-trip");
                Check(loaded.StatusPreferences.Label(WorkState.Working) == status.Label(WorkState.Working), "named defaults round-trip with UTF-8 and INI punctuation");
                Check(loaded.StatusPreferences.Label(WorkState.Lunch) == "排练间歇" && loaded.StatusPreferences.Label(WorkState.Overtime) == "加班中", "malformed label falls back independently");
                loaded.StatusPreferences.DeleteSelected();
                loaded.SaveTo(file);
                loaded = AppSettings.LoadFrom(file);
                Check(loaded.StatusPreferences.Selected.Name == "通用" && loaded.StatusPreferences.Occupations.Count() == 5, "deletion persists and selects general");
                Check(loaded.StatusPreferences.Label(WorkState.Working) == "新文案 Working", "deletion preserves other occupation overrides");
            }
            finally { Directory.Delete(directory, true); }
        }

        static void CheckHuawei()
        {
            var settings = new AppSettings
            {
                SalaryMode = AppSettings.HuaweiSalaryMode,
                HuaweiBasePay = 12000,
                HuaweiPerformancePay = 4000,
                HuaweiAnnualBonus = 24000
            };
            var friday = new DateTime(2025, 6, 27, 19, 0, 0);
            var saturday = new DateTime(2025, 6, 28, 14, 30, 0);
            var normal = Engine.Compute(settings, friday);
            var extra = Engine.Compute(settings, saturday);
            Check(normal.DailyPay == 900 && !normal.IsHuaweiOvertime,
                "ordinary wages and one twelfth of the bonus use the 20 scheduled workdays in June");
            Check(extra.IsHuaweiOvertime && extra.DailyPay == 1200 && Math.Abs(extra.Earned - 600) < 1e-8,
                "the added Saturday earns double the base daily rate across the regular work hours");
            settings.Overtime = true;
            var afterSaturday = Engine.Compute(settings, saturday.Date.AddHours(20));
            Check(afterSaturday.State == WorkState.AfterWork && Math.Abs(afterSaturday.Earned - 1200) < 1e-8,
                "the added Saturday ends at the daily double-pay amount even when ordinary overtime is enabled");
            settings.Overtime = false;
            Check(Math.Abs(Engine.MonthEarned(settings, saturday, extra.Earned) - 17700) < 1e-8 &&
                Math.Abs(Engine.MonthTotal(settings, saturday) - 19200) < 1e-8,
                "month-to-date and projected income count the double-paid day once");

            var holiday = Engine.Compute(settings, new DateTime(2025, 5, 31, 12, 0, 0));
            Check(holiday.State == WorkState.RestDay && holiday.DailyPay == 0 && !holiday.IsHuaweiOvertime,
                "a public holiday on the last Saturday remains a day off");
            var makeup = Engine.Compute(settings, new DateTime(2026, 2, 28, 12, 0, 0));
            Check(makeup.State == WorkState.Working && !makeup.IsHuaweiOvertime && makeup.DailyPay > 0 &&
                makeup.DailyPay == Engine.Compute(settings, new DateTime(2026, 2, 27)).DailyPay,
                "a scheduled makeup shift replaces the double-paid Saturday with ordinary wages");
            Check(!Engine.IsWorkDay(settings, new DateTime(2025, 9, 27)) &&
                Engine.IsWorkDay(settings, new DateTime(2025, 9, 28)),
                "a makeup Sunday can cancel the added Saturday and remains a working day");

            var monthEnd = new DateTime(2026, 1, 31);
            Check(Engine.Compute(settings, monthEnd).IsHuaweiOvertime,
                "a last Saturday producing six consecutive workdays remains eligible");
            settings.OverrideDate = Engine.DateKey(monthEnd.AddDays(1));
            settings.OverrideMode = 2;
            Check(!Engine.IsWorkDay(settings, monthEnd) && Engine.IsWorkDay(settings, monthEnd.AddDays(1)),
                "a personal shift in the next month can make the streak exactly seven and cancel the Saturday");

            settings.OverrideMode = 1;
            settings.OverrideDate = Engine.DateKey(friday);
            Check(Engine.Compute(settings, friday).DailyPay == 0 && Engine.Compute(settings, saturday).DailyPay == 1200,
                "personal leave overrides attendance without changing the scheduled-day divisor");
            var movedPayday = new DateTime(2026, 2, 14);
            settings.OverrideDate = Engine.DateKey(movedPayday);
            Check(!Engine.IsWorkDay(settings, movedPayday) &&
                Engine.DaysToPayDay(settings, movedPayday.AddDays(-1)) == 1 && Engine.DaysToPayDay(settings, movedPayday) == 0,
                "payday moves back from the public holiday to an official makeup workday regardless of personal leave");
            Check(Engine.DaysToPayDay(settings, movedPayday.AddDays(1)) == 26,
                "the countdown advances to the next adjusted payday after an early payday");

            settings.HuaweiMonthDays = 24;
            Check(Engine.Compute(settings, friday).DailyPay == 750 &&
                Engine.Compute(settings, saturday).DailyPay == 1000,
                "a manual divisor changes both wage rates while preserving the calendar");

            var directory = Path.Combine(Path.GetTempPath(), "niuma-windows-huawei-" + Guid.NewGuid().ToString("N"));
            try
            {
                var file = Path.Combine(directory, "settings.ini");
                settings.SaveTo(file);
                var loaded = AppSettings.LoadFrom(file);
                Check(loaded.SalaryMode == AppSettings.HuaweiSalaryMode && loaded.HuaweiBasePay == 12000 &&
                    loaded.HuaweiPerformancePay == 4000 && loaded.HuaweiAnnualBonus == 24000 && loaded.HuaweiMonthDays == 24,
                    "Huawei salary settings survive reopening the configuration");
            }
            finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
        }

#if WINDOWS_UI_TESTS
        static T Control<T>(DependencyObject root, string id) where T : DependencyObject
        {
            var matching = root as T;
            if (matching != null && AutomationProperties.GetAutomationId(matching) == id) return matching;
            foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
            {
                var result = Control<T>(child, id);
                if (result != null) return result;
            }
            return null;
        }

        static void Click(Button button) { button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); }

        static void CheckEditor()
        {
            var original = new StatusPreferences();
            var editor = new StatusEditor(original);
            editor.Measure(new Size(382, double.PositiveInfinity));
            editor.Arrange(new Rect(0, 0, 382, editor.DesiredSize.Height));
            var occupations = Control<ComboBox>(editor, "occupations");
            foreach (var state in StatusPreferences.States)
            {
                var input = Control<TextBox>(editor, "statusInput." + state);
                var preview = Control<TextBlock>(editor, "statusPreview." + state);
                var reset = Control<Button>(editor, "statusReset." + state);
                Check(input.ActualWidth > 80, "editor fits the minimum settings width");
                input.Text = "正在编辑 " + state;
                Check(preview.Text == input.Text, "each edit updates its live preview");
                Click(reset);
                Check(input.Text.Length == 0 && preview.Text == StatusPreferences.DefaultLabel(state), "each reset restores the default");
            }
            var working = Control<TextBox>(editor, "statusInput.Working");
            var workingPreview = Control<TextBlock>(editor, "statusPreview.Working");
            occupations.SelectedIndex = 1;
            Check(workingPreview.Text == "上钟中", "selecting an occupation updates the preview");
            working.Text = "驻场中";
            occupations.SelectedIndex = 2;
            Check(workingPreview.Text == "掌勺中", "another occupation has its own wording");
            occupations.SelectedIndex = 1;
            Check(working.Text == "驻场中" && workingPreview.Text == "驻场中", "switching back restores the first occupation's edits");
            var name = Control<TextBox>(editor, "occupationName");
            name.Text = "驻场演出";
            Click(Control<Button>(editor, "saveOccupation"));
            Check(editor.Collect().Selected.Name == "驻场演出" && working.Text.Length == 0 && workingPreview.Text == "驻场中", "saving an occupation captures the draft as defaults");
            working.Text = new string('演', 81);
            Check(workingPreview.Text == "格式有误", "invalid edit is previewed as an error");
            Click(Control<Button>(editor, "restoreStatuses"));
            Check(working.Text.Length == 0 && workingPreview.Text == "驻场中", "all-state reset restores the current occupation defaults");
            Check(original.Selected.Name == "通用" && original.Occupations.Count() == 5, "editor keeps original settings independent");
            Click(Control<Button>(editor, "deleteOccupation"));
            Check(editor.Collect().Selected.Name == "通用" && occupations.Items.Count == 5, "deleting a custom occupation returns to general");
        }
#endif
    }
}
