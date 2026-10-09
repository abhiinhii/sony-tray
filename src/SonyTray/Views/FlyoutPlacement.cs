using System.Windows;

namespace SonyTray.Views;

/// <summary>Bottom-right placement in one consistent WPF coordinate space.</summary>
internal static class FlyoutPlacement
{
    internal static Rect Calculate(Rect workArea, Size desiredSize)
    {
        if (workArea.IsEmpty || workArea.Width <= 0 || workArea.Height <= 0
            || !double.IsFinite(workArea.Width) || !double.IsFinite(workArea.Height))
            throw new ArgumentOutOfRangeException(nameof(workArea));

        // Keep the full frame inside even an unusually small work area.
        double inset = Math.Min(4, Math.Max(0, Math.Min(workArea.Width, workArea.Height) / 2 - 1));
        double width = Math.Min(desiredSize.Width, workArea.Width - 2 * inset);
        double height = Math.Min(desiredSize.Height, workArea.Height - 2 * inset);
        return new Rect(workArea.Right - inset - width, workArea.Bottom - inset - height, width, height);
    }
}