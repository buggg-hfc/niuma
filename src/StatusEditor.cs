using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;

namespace NiuMa
{
    internal sealed class StatusEditor : StackPanel
    {
        sealed class StatusRow
        {
            internal TextBox Input;
            internal TextBlock Placeholder, Preview;
            internal Button Reset;
        }

        readonly Dictionary<WorkState, StatusRow> _rows = new Dictionary<WorkState, StatusRow>();
        readonly ComboBox _occupations = new ComboBox { MinWidth = 80 };
        readonly TextBox _name = Input("自定义职业名称", "occupationName");
        readonly TextBlock _error = Ui.T("", 12, Ui.Carrot);
        readonly Button _delete, _restore;
        StatusPreferences _draft;
        bool _loading;

        internal StatusEditor(StatusPreferences preferences)
        {
            AutomationProperties.SetAutomationId(_occupations, "occupations");
            AutomationProperties.SetName(_occupations, "职业预设");
            _occupations.SelectionChanged += SelectOccupation;
            _delete = ActionButton("删除职业", "deleteOccupation", (o, e) => {
                _draft.DeleteSelected();
                LoadSelection(true);
            });
            _restore = ActionButton("恢复默认文案", "restoreStatuses", (o, e) => {
                foreach (var row in _rows.Values) row.Input.Clear();
                RefreshPreviews();
            });
            Children.Add(Toolbar(_occupations, _delete, _restore));

            var table = new Grid { Margin = new Thickness(0, 8, 0, 2) };
            foreach (var width in new[] { new GridLength(75), new GridLength(1, GridUnitType.Star), new GridLength(98), new GridLength(56) })
                table.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
            table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            AddToTable(table, Ui.T("显示文案", 11, Ui.Gray), 0, 1);
            AddToTable(table, Ui.T("预览", 11, Ui.Gray), 0, 2);
            foreach (var state in StatusPreferences.States) AddStatusRow(table, state);
            Children.Add(table);

            var save = ActionButton("存为新职业", "saveOccupation", (o, e) => SaveOccupation());
            _name.KeyDown += (o, e) => {
                if (e.Key == Key.Enter) { e.Handled = true; SaveOccupation(); }
            };
            var nameHint = Ui.T("输入新职业名称", 12, Ui.Gray);
            Children.Add(Toolbar(Placeholder(_name, nameHint), save));
            var help = Ui.T("留空使用职业默认文案。新职业会将六项预览用作默认文案。", 11, Ui.Gray);
            help.Margin = new Thickness(0, 5, 0, 0);
            Children.Add(help);
            _error.Visibility = Visibility.Collapsed;
            Children.Add(_error);
            Reset(preferences);
        }

        void AddStatusRow(Grid table, WorkState state)
        {
            int index = table.RowDefinitions.Count;
            table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = StatusPreferences.DefaultLabel(state);
            var input = Input(label + "的显示文案", "statusInput." + state);
            var preview = Ui.T("", 12, Ui.Leaf, FontWeights.SemiBold);
            preview.TextWrapping = TextWrapping.NoWrap;
            preview.TextTrimming = TextTrimming.CharacterEllipsis;
            preview.TextAlignment = TextAlignment.Center;
            AutomationProperties.SetAutomationId(preview, "statusPreview." + state);
            var placeholder = Ui.T("", 12, Ui.Gray);
            var reset = ActionButton("恢复", "statusReset." + state, (o, e) => input.Clear());
            AutomationProperties.SetName(reset, "恢复「" + label + "」默认文案");
            input.TextChanged += (o, e) => { if (!_loading) RefreshPreviews(); };
            AddToTable(table, Ui.T(label, 13, Ui.Sub), index, 0);
            AddToTable(table, Placeholder(input, placeholder), index, 1);
            AddToTable(table, new Border {
                Child = preview, Background = Ui.B("#184E7E32"), CornerRadius = new CornerRadius(11), Padding = new Thickness(5, 3, 5, 3)
            }, index, 2);
            AddToTable(table, reset, index, 3);
            _rows.Add(state, new StatusRow { Input = input, Placeholder = placeholder, Preview = preview, Reset = reset });
        }

        static TextBox Input(string name, string id)
        {
            var input = new TextBox { Padding = new Thickness(4, 3, 4, 3), VerticalContentAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(input, name);
            AutomationProperties.SetAutomationId(input, id);
            return input;
        }

        static Grid Placeholder(TextBox input, TextBlock placeholder)
        {
            var grid = new Grid();
            placeholder.IsHitTestVisible = false;
            placeholder.Margin = new Thickness(6, 0, 4, 0);
            placeholder.VerticalAlignment = VerticalAlignment.Center;
            placeholder.TextWrapping = TextWrapping.NoWrap;
            placeholder.TextTrimming = TextTrimming.CharacterEllipsis;
            input.TextChanged += (o, e) => placeholder.Visibility = input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            grid.Children.Add(input);
            grid.Children.Add(placeholder);
            return grid;
        }

        static Button ActionButton(string label, string id, RoutedEventHandler action)
        {
            var button = new Button { Content = label, Padding = new Thickness(6, 3, 6, 3) };
            AutomationProperties.SetAutomationId(button, id);
            button.Click += action;
            return button;
        }

        static DockPanel Toolbar(UIElement filler, params Button[] buttons)
        {
            var panel = new DockPanel { Margin = new Thickness(0, 4, 0, 2) };
            for (int i = buttons.Length - 1; i >= 0; i--)
            {
                var button = buttons[i];
                button.Margin = new Thickness(6, 0, 0, 0);
                DockPanel.SetDock(button, Dock.Right);
                panel.Children.Add(button);
            }
            panel.Children.Add(filler);
            return panel;
        }

        static void AddToTable(Grid table, FrameworkElement view, int row, int column)
        {
            view.Margin = new Thickness(0, 3, column == 3 ? 0 : 6, 3);
            view.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetRow(view, row);
            Grid.SetColumn(view, column);
            table.Children.Add(view);
        }

        internal void Reset(StatusPreferences preferences)
        {
            _draft = preferences.Clone();
            _name.Clear();
            LoadSelection(true);
        }

        void LoadSelection(bool rebuildMenu)
        {
            _loading = true;
            if (rebuildMenu)
            {
                _occupations.Items.Clear();
                foreach (var preset in _draft.Occupations)
                    _occupations.Items.Add(new ComboBoxItem { Content = preset.Name, Tag = preset.Id });
            }
            var selected = _draft.Selected;
            foreach (ComboBoxItem item in _occupations.Items)
                if ((string)item.Tag == selected.Id) { _occupations.SelectedItem = item; break; }
            _delete.IsEnabled = selected.IsCustom;
            foreach (var entry in _rows)
            {
                entry.Value.Placeholder.Text = _draft.OccupationDefault(entry.Key);
                entry.Value.Input.Text = _draft.Override(entry.Key) ?? "";
            }
            _loading = false;
            RefreshPreviews();
        }

        void RefreshPreviews()
        {
            bool hasOverrides = false;
            string error = null;
            foreach (var entry in _rows)
            {
                var row = entry.Value;
                row.Reset.IsEnabled = row.Input.Text.Length != 0;
                hasOverrides |= row.Reset.IsEnabled;
                try
                {
                    var text = StatusPreferences.CleanLabel(entry.Key, row.Input.Text);
                    row.Preview.Text = text.Length == 0 ? _draft.OccupationDefault(entry.Key) : text;
                    row.Preview.Foreground = entry.Key == WorkState.Overtime ? Ui.Carrot : Ui.Leaf;
                    row.Preview.ToolTip = row.Preview.Text;
                }
                catch (ArgumentException invalid)
                {
                    row.Preview.Text = "格式有误";
                    row.Preview.Foreground = Ui.Carrot;
                    row.Preview.ToolTip = invalid.Message;
                    error = error ?? invalid.Message;
                }
            }
            _restore.IsEnabled = hasOverrides;
            ShowError(error);
        }

        void ShowError(string message)
        {
            _error.Text = message ?? "";
            _error.Visibility = message == null ? Visibility.Collapsed : Visibility.Visible;
        }

        internal StatusPreferences Collect()
        {
            var draft = _draft.Clone();
            var labels = new Dictionary<WorkState, string>();
            foreach (var entry in _rows) labels.Add(entry.Key, entry.Value.Input.Text);
            draft.SetOverrides(labels);
            return draft;
        }

        void SelectOccupation(object sender, SelectionChangedEventArgs args)
        {
            var item = _occupations.SelectedItem as ComboBoxItem;
            if (_loading || item == null) return;
            try
            {
                _draft = Collect();
                _draft.Select((string)item.Tag);
                LoadSelection(false);
            }
            catch (ArgumentException invalid)
            {
                _loading = true;
                _occupations.SelectedItem = args.RemovedItems.Count > 0 ? args.RemovedItems[0] : null;
                _loading = false;
                ShowError(invalid.Message);
            }
        }

        void SaveOccupation()
        {
            try
            {
                var draft = Collect();
                draft.AddOccupation(_name.Text);
                _draft = draft;
                _name.Clear();
                LoadSelection(true);
            }
            catch (ArgumentException invalid) { ShowError(invalid.Message); }
        }
    }
}
