using System;
using System.Collections.Generic;
using System.Globalization;

namespace NiuMa
{
    internal sealed class OccupationPreset
    {
        internal readonly string Id;
        internal readonly string Name;
        internal readonly bool IsCustom;
        readonly Dictionary<WorkState, string> _defaults;

        internal OccupationPreset(string id, string name, bool isCustom, Dictionary<WorkState, string> defaults)
        {
            Id = id;
            Name = name;
            IsCustom = isCustom;
            _defaults = defaults;
        }

        internal string Label(WorkState state)
        {
            string value;
            return _defaults.TryGetValue(state, out value) ? value : null;
        }
    }

    internal sealed class StatusPreferences
    {
        internal static readonly IList<WorkState> States = Array.AsReadOnly(new[] {
            WorkState.BeforeWork, WorkState.Working, WorkState.Lunch, WorkState.Overtime, WorkState.AfterWork, WorkState.RestDay
        });
        const string General = "general";
        const string SelectedKey = "Status.Selected";
        const string NamePrefix = "Status.Name.";
        const string DefaultPrefix = "Status.Default.";
        const string OverridePrefix = "Status.Override.";

        static readonly OccupationPreset[] BuiltIn = {
            BuiltInPreset(General, "通用"),
            BuiltInPreset("onClock", "上钟 / 下钟", "待上钟", "上钟中", "休息中", null, "已下钟"),
            BuiltInPreset("cook", "厨师", "待开灶", "掌勺中", "歇一会儿", null, "已收灶"),
            BuiltInPreset("construction", "建筑工人", "待开工", "施工中", "工间休息", "赶工中", "已收工"),
            BuiltInPreset("developer", "程序员", "待开工", "开发中", "休息中", null, "已下线")
        };

        List<OccupationPreset> _occupations = new List<OccupationPreset>(BuiltIn);
        Dictionary<string, Dictionary<WorkState, string>> _overrides = new Dictionary<string, Dictionary<WorkState, string>>();
        string _selectedId = General;

        internal IEnumerable<OccupationPreset> Occupations { get { return _occupations; } }
        internal OccupationPreset Selected { get { return Find(_selectedId); } }

        static OccupationPreset BuiltInPreset(string id, string name, params string[] labels)
        {
            var defaults = new Dictionary<WorkState, string>();
            for (int i = 0; i < labels.Length; i++) if (labels[i] != null) defaults.Add(States[i], labels[i]);
            return new OccupationPreset(id, name, false, defaults);
        }

        internal StatusPreferences Clone()
        {
            return new StatusPreferences {
                _selectedId = _selectedId,
                _occupations = new List<OccupationPreset>(_occupations),
                // Setting overrides replaces a complete dictionary, so drafts can share the current values.
                _overrides = new Dictionary<string, Dictionary<WorkState, string>>(_overrides)
            };
        }

        OccupationPreset Find(string id) { return _occupations.Find(preset => preset.Id == id); }

        internal void Select(string id)
        {
            if (Find(id) != null) _selectedId = id;
        }

        internal static string DefaultLabel(WorkState state)
        {
            switch (state)
            {
                case WorkState.BeforeWork: return "还没上班";
                case WorkState.Working: return "上班中";
                case WorkState.Lunch: return "午休中";
                case WorkState.Overtime: return "加班中";
                case WorkState.AfterWork: return "已下班";
                default: return "休息日";
            }
        }

        internal string OccupationDefault(WorkState state) { return Selected.Label(state) ?? DefaultLabel(state); }

        internal string Override(WorkState state)
        {
            Dictionary<WorkState, string> labels;
            string label;
            return _overrides.TryGetValue(_selectedId, out labels) && labels.TryGetValue(state, out label) ? label : null;
        }

        internal string Label(WorkState state) { return Override(state) ?? OccupationDefault(state); }

        internal string MiniLabel(Snapshot snapshot)
        {
            if (snapshot.State == WorkState.Working) return Engine.Duration(snapshot.SecondsToNext, false) + "后下班";
            var customized = Override(snapshot.State) ?? Selected.Label(snapshot.State);
            if (customized != null) return customized;
            switch (snapshot.State)
            {
                case WorkState.BeforeWork: return "未上班";
                case WorkState.Lunch: return "午休";
                case WorkState.RestDay: return "休息";
                default: return DefaultLabel(snapshot.State);
            }
        }

        internal static string CleanText(string text, string field, int limit)
        {
            foreach (char c in text)
                if (char.IsControl(c) || c == '\u2028' || c == '\u2029')
                    throw new ArgumentException(field + "请输入单行文字");
            var cleaned = text.Trim();
            if (new StringInfo(cleaned).LengthInTextElements > limit)
                throw new ArgumentException(field + "最多 " + limit + " 个字符");
            return cleaned;
        }

        internal static string CleanLabel(WorkState state, string text)
        {
            return CleanText(text, "「" + DefaultLabel(state) + "」文案", 80);
        }

        internal void SetOverrides(IDictionary<WorkState, string> entries)
        {
            var labels = new Dictionary<WorkState, string>();
            foreach (var entry in entries)
            {
                var label = CleanLabel(entry.Key, entry.Value);
                if (label.Length != 0) labels.Add(entry.Key, label);
            }
            if (labels.Count == 0) _overrides.Remove(_selectedId);
            else _overrides[_selectedId] = labels;
        }

        string AvailableName(string text)
        {
            var name = CleanText(text, "职业名称", 32);
            if (name.Length == 0) throw new ArgumentException("请输入职业名称");
            if (_occupations.Exists(preset => string.Equals(preset.Name, name, StringComparison.OrdinalIgnoreCase)))
                throw new ArgumentException("已有同名职业，请换一个名称");
            return name;
        }

        internal void AddOccupation(string text)
        {
            var name = AvailableName(text);
            var labels = new Dictionary<WorkState, string>();
            foreach (var state in States) labels.Add(state, Label(state));
            var id = Guid.NewGuid().ToString("N");
            _occupations.Add(new OccupationPreset(id, name, true, labels));
            _selectedId = id;
        }

        internal void DeleteSelected()
        {
            var preset = Selected;
            if (!preset.IsCustom) return;
            _occupations.Remove(preset);
            _overrides.Remove(preset.Id);
            _selectedId = General;
        }

        internal IEnumerable<KeyValuePair<string, string>> WriteEntries()
        {
            yield return new KeyValuePair<string, string>(SelectedKey, _selectedId);
            foreach (var preset in _occupations)
            {
                if (preset.IsCustom)
                {
                    yield return new KeyValuePair<string, string>(NamePrefix + preset.Id, preset.Name);
                    foreach (var state in States)
                    {
                        var label = preset.Label(state);
                        if (label != null) yield return new KeyValuePair<string, string>(DefaultPrefix + preset.Id + "." + state, label);
                    }
                }
                Dictionary<WorkState, string> labels;
                if (_overrides.TryGetValue(preset.Id, out labels))
                    foreach (var label in labels)
                        yield return new KeyValuePair<string, string>(OverridePrefix + preset.Id + "." + label.Key, label.Value);
            }
        }

        static Dictionary<WorkState, string> ReadLabels(IDictionary<string, string> entries, string prefix, string id)
        {
            var labels = new Dictionary<WorkState, string>();
            foreach (var state in States)
            {
                string text;
                if (!entries.TryGetValue(prefix + id + "." + state, out text)) continue;
                try
                {
                    string label = CleanLabel(state, text);
                    if (label.Length != 0) labels.Add(state, label);
                }
                catch (ArgumentException) { }
            }
            return labels;
        }

        internal static StatusPreferences ReadEntries(IDictionary<string, string> entries)
        {
            var result = new StatusPreferences();
            foreach (var entry in entries)
            {
                if (!entry.Key.StartsWith(NamePrefix, StringComparison.Ordinal)) continue;
                var id = entry.Key.Substring(NamePrefix.Length);
                Guid guid;
                if (!Guid.TryParseExact(id, "N", out guid)) continue;
                try
                {
                    var name = result.AvailableName(entry.Value);
                    result._occupations.Add(new OccupationPreset(id, name, true, ReadLabels(entries, DefaultPrefix, id)));
                }
                catch (ArgumentException) { }
            }
            foreach (var preset in result._occupations)
            {
                var labels = ReadLabels(entries, OverridePrefix, preset.Id);
                if (labels.Count != 0) result._overrides.Add(preset.Id, labels);
            }
            string selected;
            if (entries.TryGetValue(SelectedKey, out selected)) result.Select(selected);
            return result;
        }
    }
}
