using System.Windows;

namespace XM5Control.Views;

public partial class FlyoutWindow : Window
{
    public FlyoutWindow()
    {
        InitializeComponent();
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
