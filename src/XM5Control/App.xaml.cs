using System.Windows;
using System.Windows.Controls;
using Hardcodet.Wpf.TaskbarNotification;
using XM5Control.Services;
using XM5Control.Views;

namespace XM5Control;

public partial class App : Application
{
    private Mutex? _instanceMutex;
    private TaskbarIcon? _trayIcon;
    private FlyoutWindow? _flyout;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _instanceMutex = new Mutex(initiallyOwned: true, "XM5Control-SingleInstance", out bool isNew);
        if (!isNew)
        {
            Shutdown();
            return;
        }
        Log.Info("XM5 Control starting");
        _flyout = new FlyoutWindow();

        var menu = new ContextMenu();
        var exitItem = new MenuItem { Header = "Exit" };
        exitItem.Click += (_, _) => Shutdown();
        menu.Items.Add(exitItem);

        _trayIcon = new TaskbarIcon
        {
            Icon = TrayIconFactory.Create(connected: false),
            ToolTipText = "XM5 Control — not connected",
            ContextMenu = menu,
        };
        _trayIcon.LeftClickCommand = new RelayCommand(() => _flyout.ShowNearTray());
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _trayIcon?.Dispose();
        _instanceMutex?.Dispose();
        base.OnExit(e);
    }
}

/// <summary>Minimal ICommand wrapper (no MVVM framework by design).</summary>
public sealed class RelayCommand(Action execute) : System.Windows.Input.ICommand
{
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => execute();
}
