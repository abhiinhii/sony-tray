using System.ComponentModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using SonyTray.Services;

namespace SonyTray.Views;

public partial class FlyoutWindow : Window
{
    private const double PreferredWidth = 340;
    private bool _positioning;

    public FlyoutWindow()
    {
        InitializeComponent();
        try
        {
            Icon = BitmapFrame.Create(new Uri("pack://application:,,,/Assets/app.ico"));
        }
        catch (Exception ex)
        {
            // Window icon is cosmetic only — never let a bad/missing resource break the window.
            Log.Error($"Failed to set FlyoutWindow icon: {ex.Message}");
        }
        Deactivated += (_, _) => Hide();
        SizeChanged += (_, _) => RepositionVisibleFlyout();
        IsVisibleChanged += (_, e) =>
        {
            // Subscribe only while visible so hidden/reused windows and offscreen tests
            // do not remain referenced by the static display-settings event.
            if ((bool)e.NewValue) SystemParameters.StaticPropertyChanged += WorkAreaChanged;
            else SystemParameters.StaticPropertyChanged -= WorkAreaChanged;
        };
    }

    public void ShowNearTray()
    {
        Rect area = SystemParameters.WorkArea;
        ApplyWorkAreaLimits(area);
        // Position the measured content before showing, then account for the final
        // native size. Later capability/EQ replies keep the same bottom anchor.
        if (Content is FrameworkElement content)
        {
            content.Measure(new Size(Width, MaxHeight));
            Rect frame = FlyoutPlacement.Calculate(area, new Size(Width, content.DesiredSize.Height));
            Left = frame.Left;
            Top = frame.Top;
        }
        Show();
        RepositionVisibleFlyout();
        Activate();
    }

    private void ApplyWorkAreaLimits(Rect area)
    {
        Rect limits = FlyoutPlacement.Calculate(area, new Size(PreferredWidth, area.Height));
        MaxWidth = limits.Width;
        MaxHeight = limits.Height;
        Width = limits.Width;
    }

    private void RepositionVisibleFlyout()
    {
        if (!IsVisible || _positioning) return;
        _positioning = true;
        try
        {
            Rect area = SystemParameters.WorkArea;
            ApplyWorkAreaLimits(area);
            UpdateLayout();
            Rect frame = FlyoutPlacement.Calculate(area, new Size(ActualWidth, ActualHeight));
            Left = frame.Left;
            Top = frame.Top;
        }
        finally { _positioning = false; }
    }

    private void WorkAreaChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SystemParameters.WorkArea))
            Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(RepositionVisibleFlyout));
    }

    private void CanHideFlyout(object sender, CanExecuteRoutedEventArgs e)
    {
        e.CanExecute = true;
        e.Handled = true;
    }

    private void HideFlyout(object sender, ExecutedRoutedEventArgs e)
    {
        Hide();
        e.Handled = true;
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        e.Cancel = true; // tray app: closing just hides
        Hide();
    }
}