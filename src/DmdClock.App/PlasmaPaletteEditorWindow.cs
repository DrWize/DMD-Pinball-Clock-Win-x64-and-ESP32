using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace DmdClock.App;

public sealed class PlasmaPaletteEditorWindow : Window
{
    private readonly Color[] _colors;
    private readonly Button[] _colorButtons;

    public PlasmaPaletteEditorWindow(IReadOnlyList<string> initialColors)
    {
        Title = "Custom plasma palette";
        Width = 520;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _colors = initialColors.Select(ParseColor).ToArray();
        _colorButtons = new Button[_colors.Length];

        var colorRow = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions(
                string.Join(',', Enumerable.Repeat("*", _colors.Length))),
            ColumnSpacing = 8
        };
        for (var index = 0; index < _colors.Length; index++)
        {
            var colorIndex = index;
            var button = new Button
            {
                Height = 90,
                HorizontalContentAlignment = HorizontalAlignment.Center,
                VerticalContentAlignment = VerticalAlignment.Center
            };
            button.Click += async (_, _) => await PickColorAsync(colorIndex);
            _colorButtons[index] = button;
            UpdateButton(index);
            Grid.SetColumn(button, index);
            colorRow.Children.Add(button);
        }

        var save = new Button { Content = "Save palette", MinWidth = 110 };
        var cancel = new Button { Content = "Cancel", MinWidth = 90 };
        save.Click += (_, _) => Close(_colors.Select(ToHex).ToArray());
        cancel.Click += (_, _) => Close(null);

        Content = new StackPanel
        {
            Margin = new Thickness(20),
            Spacing = 14,
            Children =
            {
                new TextBlock
                {
                    Text = "Choose four colors. The plasma blends between them and loops back to the first.",
                    TextWrapping = TextWrapping.Wrap
                },
                colorRow,
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Spacing = 10,
                    Children = { cancel, save }
                }
            }
        };
    }

    private async Task PickColorAsync(int index)
    {
        var dialog = new ColorPickerWindow(
            $"Plasma color {index + 1}", _colors[index], "Apply", "Cancel");
        var selected = await dialog.ShowDialog<Color?>(this);
        if (selected is not { } color) return;
        _colors[index] = color;
        UpdateButton(index);
    }

    private void UpdateButton(int index)
    {
        var color = _colors[index];
        _colorButtons[index].Content = $"Color {index + 1}\n{ToHex(color)}";
        _colorButtons[index].Background = new SolidColorBrush(color);
        var luminance = (color.R * 299) + (color.G * 587) + (color.B * 114);
        _colorButtons[index].Foreground = luminance >= 128_000 ? Brushes.Black : Brushes.White;
    }

    private static Color ParseColor(string value)
    {
        try { return Color.Parse(value); }
        catch (FormatException) { return Color.FromRgb(120, 100, 255); }
    }

    private static string ToHex(Color color) => $"#{color.R:X2}{color.G:X2}{color.B:X2}";
}
