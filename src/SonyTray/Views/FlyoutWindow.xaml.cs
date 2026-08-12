using System.Windows;
using System.Windows.Media.Imaging;
using SonyTray.Services;

namespace SonyTray.Views;

public partial class FlyoutWindow : Window
{
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
    }

    public void ShowNearTray()
    {
        var area = SystemParameters.WorkArea;
        // measure at current width so ActualHeight is valid before positioning
        Show();
        UpdateLayout();
        Left = area.Right - ActualWidth - 4;
        Top = area.Bottom - ActualHeight - 4;
        Activate();
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        e.Cancel = true; // tray app: closing just hides
        Hide();
    }
}
