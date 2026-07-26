using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using DmdClock.Core.Settings;

namespace DmdClock.App;

public sealed class PlasmaSpeedEditorWindow : Window
{
    private readonly NumericUpDown _seconds;

    public PlasmaSpeedEditorWindow(int cycleMilliseconds)
    {
        Title = "Custom plasma speed";
        Width = 390;
        SizeToContent = SizeToContent.Height;
        CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _seconds = new NumericUpDown
        {
            Minimum = PlasmaSpeedDefinition.MinimumCycleMilliseconds / 1000m,
            Maximum = PlasmaSpeedDefinition.MaximumCycleMilliseconds / 1000m,
            Increment = PlasmaSpeedDefinition.StepMilliseconds / 1000m,
            Value = PlasmaSpeedDefinition.Normalize(cycleMilliseconds) / 1000m,
            FormatString = "0.00",
            MinWidth = 130,
            HorizontalContentAlignment = HorizontalAlignment.Center
        };

        var save = new Button { Content = "Apply", MinWidth = 90 };
        var cancel = new Button { Content = "Cancel", MinWidth = 90 };
        save.Click += (_, _) =>
        {
            var milliseconds = (int)Math.Round((_seconds.Value ?? 8m) * 1000m);
            Close(PlasmaSpeedDefinition.Normalize(milliseconds));
        };
        cancel.Click += (_, _) => Close(null);

        Content = new StackPanel
        {
            Margin = new Thickness(20),
            Spacing = 12,
            Children =
            {
                new TextBlock
                {
                    Text = "Time for one complete plasma color cycle (1–60 seconds).",
                    TextWrapping = TextWrapping.Wrap
                },
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Spacing = 8,
                    Children =
                    {
                        _seconds,
                        new TextBlock
                        {
                            Text = "seconds",
                            VerticalAlignment = VerticalAlignment.Center
                        }
                    }
                },
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
}
