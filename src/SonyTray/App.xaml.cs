using System.Windows;
using System.Windows.Controls;
using Hardcodet.Wpf.TaskbarNotification;
using SonyTray.Bluetooth;
using SonyTray.Services;
using SonyTray.ViewModels;
using SonyTray.Views;

namespace SonyTray;

public partial class App : Application
{
    private Mutex? _instanceMutex;
    private TaskbarIcon? _trayIcon;
    private FlyoutWindow? _flyout;
    private HeadphonesSession? _session;
    private MainViewModel? _viewModel;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Contains("--probe"))
        {
            // Deviation from brief (bug fix, same authorized scope as the Task.Delay/Say
            // changes): routing the exit through Dispatcher.Invoke(() => Shutdown(...)) left the
            // process alive for minutes after RunAsync() completed (observed: probe finished and
            // logged its result in ~4s, but the process didn't exit until ~2.5 min later, with
            // the wrong exit code). Probe mode never creates a window/dispatcher-owned resource,
            // so there is nothing that needs a graceful WPF shutdown — exit the process directly
            // and deterministically instead.
            Probe.RunAsync().ContinueWith(t =>
            {
                if (t.IsFaulted)
                {
                    Services.Log.Error($"Probe faulted: {t.Exception?.GetBaseException().Message}");
                    Environment.Exit(1);
                }
                Environment.Exit(t.Result);
            });
            return;
        }
        _instanceMutex = new Mutex(initiallyOwned: true, "SonyTray-SingleInstance", out bool isNew);
        if (!isNew)
        {
            Shutdown();
            return;
        }
        Log.Info("Sony Tray starting");
        _session = new HeadphonesSession();
        _viewModel = new MainViewModel(_session);
        _flyout = new FlyoutWindow { DataContext = _viewModel };

        var menu = new ContextMenu();
        var startupItem = new MenuItem { Header = "Start with Windows", IsCheckable = true, IsChecked = StartupManager.IsEnabled() };
        startupItem.Click += (_, _) => StartupManager.SetEnabled(startupItem.IsChecked);
        menu.Items.Add(startupItem);
        menu.Items.Add(new Separator());
        var exitItem = new MenuItem { Header = "Exit" };
        exitItem.Click += (_, _) => Shutdown();
        menu.Items.Add(exitItem);

        _trayIcon = new TaskbarIcon
        {
            Icon = TrayIconFactory.Create(connected: false),
            ToolTipText = "Sony Tray — not connected",
            ContextMenu = menu,
            LeftClickCommand = new RelayCommand(() => _flyout.ShowNearTray()),
        };
        _viewModel.ConnectionChanged += connected => Dispatcher.BeginInvoke(() =>
        {
            _trayIcon.Icon = TrayIconFactory.Create(connected);
            _trayIcon.ToolTipText = connected
                ? $"Sony Tray — connected, battery {_viewModel.BatteryText}"
                : "Sony Tray — not connected";
        });
        _viewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName != nameof(MainViewModel.BatteryText)) return;
            Dispatcher.BeginInvoke(() =>
            {
                if (_viewModel.IsConnected)
                    _trayIcon.ToolTipText = $"Sony Tray — connected, battery {_viewModel.BatteryText}";
            });
        };
        _session.Start();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_session is not null) _session.DisposeAsync().AsTask().GetAwaiter().GetResult();
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
