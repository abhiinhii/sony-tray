using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Threading;
using SonyProtocol;
using XM5Control.Bluetooth;
using XM5Control.Services;

namespace XM5Control.ViewModels;

public sealed class MainViewModel : INotifyPropertyChanged
{
    private readonly HeadphonesSession _session;
    private readonly DispatcherTimer _ambientDebounce;
    private bool _suppressSend; // true while applying device state to the UI

    public MainViewModel(HeadphonesSession session)
    {
        _session = session;
        _ambientDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        _ambientDebounce.Tick += (_, _) => { _ambientDebounce.Stop(); PushMode(); };
        session.StateChanged += s => OnUi(() => ApplyState(s));
        session.DeviceUpdated += e => OnUi(() => ApplyEvent(e));
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action<bool>? ConnectionChanged; // App updates the tray icon from this

    private bool _isConnected;
    public bool IsConnected { get => _isConnected; private set { Set(ref _isConnected, value); ConnectionChanged?.Invoke(value); } }

    private string _statusText = "Searching for headphones…";
    public string StatusText { get => _statusText; private set => Set(ref _statusText, value); }

    private string _batteryText = "–";
    public string BatteryText { get => _batteryText; private set => Set(ref _batteryText, value); }

    private bool _isNcSelected;
    public bool IsNcSelected
    {
        get => _isNcSelected;
        set { if (Set(ref _isNcSelected, value) && value) ModeChanged(); }
    }

    private bool _isAmbientSelected;
    public bool IsAmbientSelected
    {
        get => _isAmbientSelected;
        set
        {
            if (Set(ref _isAmbientSelected, value))
            {
                Raise(nameof(AmbientControlsEnabled));
                if (value) ModeChanged();
            }
        }
    }

    private bool _isOffSelected;
    public bool IsOffSelected
    {
        get => _isOffSelected;
        set { if (Set(ref _isOffSelected, value) && value) ModeChanged(); }
    }

    private double _ambientLevel = 15;
    public double AmbientLevel
    {
        get => _ambientLevel;
        set
        {
            if (Set(ref _ambientLevel, Math.Clamp(Math.Round(value), 1, 20)) && !_suppressSend)
            {
                _ambientDebounce.Stop();
                _ambientDebounce.Start();
            }
        }
    }

    private bool _focusOnVoice;
    public bool FocusOnVoice
    {
        get => _focusOnVoice;
        set { if (Set(ref _focusOnVoice, value)) ModeChanged(); }
    }

    public bool AmbientControlsEnabled => IsConnected && IsAmbientSelected;

    private void ModeChanged()
    {
        if (_suppressSend) return;
        PushMode();
    }

    private void PushMode()
    {
        NcAmbMode mode = IsAmbientSelected ? NcAmbMode.Ambient
            : IsNcSelected ? NcAmbMode.NoiseCancelling : NcAmbMode.Off;
        _ = PushAsync(() => _session.SetNcAmbAsync(mode, (int)AmbientLevel, FocusOnVoice));
    }

    /// <summary>Optimistic send; on failure re-sync UI from the device so it never lies.</summary>
    private async Task PushAsync(Func<Task> send)
    {
        try
        {
            await send();
        }
        catch (Exception ex) when (ex is TimeoutException or InvalidOperationException)
        {
            Log.Error($"Command failed: {ex.Message}");
            StatusText = "Command failed — resyncing…";
            try { await _session.RefreshAsync(); } catch { /* reconnect loop will recover */ }
        }
    }

    private void ApplyState(SessionState state)
    {
        IsConnected = state == SessionState.Ready;
        StatusText = state switch
        {
            SessionState.Ready => "Connected",
            SessionState.Connecting => "Connecting…",
            SessionState.BluetoothOff => "Bluetooth is off",
            _ => "Not connected — is the headset on?",
        };
        Raise(nameof(AmbientControlsEnabled));
    }

    private void ApplyEvent(DeviceEvent evt)
    {
        _suppressSend = true;
        try
        {
            switch (evt)
            {
                case NcAmbEvent e:
                    IsNcSelected = e.Mode == NcAmbMode.NoiseCancelling;
                    IsAmbientSelected = e.Mode == NcAmbMode.Ambient;
                    IsOffSelected = e.Mode == NcAmbMode.Off;
                    if (e.AmbientLevel >= 1) AmbientLevel = e.AmbientLevel;
                    FocusOnVoice = e.FocusOnVoice;
                    break;
                case BatteryEvent e:
                    BatteryText = e.Charging == ChargingStatus.Charging ? $"{e.Level}% ⚡" : $"{e.Level}%";
                    break;
                default:
                    ApplyEqEvent(evt); // Task 9
                    break;
            }
        }
        finally
        {
            _suppressSend = false;
        }
    }

    // Replaced with real EQ handling in Task 9.
    private void ApplyEqEvent(DeviceEvent evt) { }

    private static void OnUi(Action action)
    {
        Dispatcher dispatcher = Application.Current.Dispatcher;
        if (dispatcher.CheckAccess()) action();
        else dispatcher.BeginInvoke(action);
    }

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }

    private void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
