using System.Windows;
using SonyTray.Views;

namespace SonyTray.Tests;

public sealed class FlyoutPlacementTests
{
    [Fact]
    public void ContentGrowth_KeepsBottomAndRightEdgesInsideWorkArea()
    {
        var workArea = new Rect(0, 0, 1920, 1040);
        Rect initial = FlyoutPlacement.Calculate(workArea, new Size(340, 328));
        Rect expanded = FlyoutPlacement.Calculate(workArea, new Size(340, 438));
        Assert.Equal(1576, initial.Left);
        Assert.Equal(708, initial.Top);
        Assert.Equal(1576, expanded.Left);
        Assert.Equal(598, expanded.Top);
        Assert.Equal(workArea.Bottom - 4, expanded.Bottom);
        Assert.Equal(initial.Bottom, expanded.Bottom);
        Assert.Equal(initial.Right, expanded.Right);
    }

    [Fact]
    public void ShortNarrowWorkArea_ConstrainsEntireFrame()
    {
        var workArea = new Rect(40, 20, 320, 300);
        Rect frame = FlyoutPlacement.Calculate(workArea, new Size(340, 438));
        Assert.Equal(new Rect(44, 24, 312, 292), frame);
        Assert.True(workArea.Contains(frame));
    }

    [Fact]
    public void NegativeMonitorOrigin_RemainsWithinChosenWorkArea()
    {
        var workArea = new Rect(-1280, -200, 1280, 984);
        Rect frame = FlyoutPlacement.Calculate(workArea, new Size(340, 438));
        Assert.Equal(new Rect(-344, 342, 340, 438), frame);
        Assert.True(workArea.Contains(frame));
    }

    [Fact]
    public void TinyWorkArea_ReducesInsetAndKeepsPositiveSize()
    {
        var workArea = new Rect(0, 0, 6, 4);
        Rect frame = FlyoutPlacement.Calculate(workArea, new Size(340, 438));
        Assert.True(frame.Width > 0 && frame.Height > 0);
        Assert.True(workArea.Contains(frame));
    }
}