using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Threading;
using SonyProtocol;
using SonyTray.Bluetooth;
using SonyTray.Services;

// RelayCommand (used below) is declared directly under the SonyTray namespace in App.xaml.cs;
// it resolves here without a `using` because SonyTray.ViewModels is a nested namespace of SonyTray.
namespace SonyTray.ViewModels;

public sealed class MainViewModel : INotifyPropertyChanged
{
    private readonly HeadphonesSession _session;
    private readonly DispatcherTimer _ambientDebounce;
    private bool _suppressSend; // true while applying device state to the UI
    private NcAmbMode _mode = NcAmbMode.NoiseCancelling;

    public MainViewModel(HeadphonesSession session)
    {
        _session = session;
        _ambientDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        _ambientDebounce.Tick += (_, _) => { _ambientDebounce.Stop(); PushMode(); };
        PowerOffCommand = new RelayCommand(() => _ = PushAsync(() => _session.PowerOffAsync()));
        session.StateChanged += s => OnUi(() => ApplyState(s));
        session.DeviceUpdated += e => OnUi(() => ApplyEvent(e));
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action<bool>? ConnectionChanged; // App updates the tray icon from this

    private bool _isConnected;
    public bool IsConnected { get => _isConnected; private set { Set(ref _isConnected, value); ConnectionChanged?.Invoke(value); } }

    public RelayCommand PowerOffCommand { get; }

    // Default true until Task 15 wires this to device capabilities.
    private bool _powerOffVisible = true;
    public bool PowerOffVisible { get => _powerOffVisible; set => Set(ref _powerOffVisible, value); }

    private string _statusText = "Searching for headphones…";
    public string StatusText { get => _statusText; private set => Set(ref _statusText, value); }

    private string _batteryText = "–";
    public string BatteryText { get => _batteryText; private set => Set(ref _batteryText, value); }

    public bool IsNcSelected
    {
        get => _mode == NcAmbMode.NoiseCancelling;
        set { if (value) SelectMode(NcAmbMode.NoiseCancelling); }
    }

    public bool IsAmbientSelected
    {
        get => _mode == NcAmbMode.Ambient;
        set { if (value) SelectMode(NcAmbMode.Ambient); }
    }

    public bool IsOffSelected
    {
        get => _mode == NcAmbMode.Off;
        set { if (value) SelectMode(NcAmbMode.Off); }
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
        set { if (Set(ref _focusOnVoice, value) && !_suppressSend) PushMode(); }
    }

    public bool AmbientControlsEnabled => IsConnected && _mode == NcAmbMode.Ambient;

    private void SelectMode(NcAmbMode mode)
    {
        if (_mode == mode) return;
        _mode = mode;
        Raise(nameof(IsNcSelected));
        Raise(nameof(IsAmbientSelected));
        Raise(nameof(IsOffSelected));
        Raise(nameof(AmbientControlsEnabled));
        if (!_suppressSend) PushMode();
    }

    private void PushMode()
    {
        NcAmbMode mode = _mode;
        _ = PushAsync(() => _session.SetNcAmbAsync(mode, (int)AmbientLevel, FocusOnVoice));
    }

    public sealed record EqPresetChoice(EqPreset Id, string Name);

    public IReadOnlyList<EqPresetChoice> EqPresets { get; } =
    [
        new(EqPreset.Off, "Off"),
        new(EqPreset.Bright, "Bright"),
        new(EqPreset.Excited, "Excited"),
        new(EqPreset.Mellow, "Mellow"),
        new(EqPreset.Relaxed, "Relaxed"),
        new(EqPreset.Vocal, "Vocal"),
        new(EqPreset.TrebleBoost, "Treble Boost"),
        new(EqPreset.BassBoost, "Bass Boost"),
        new(EqPreset.Speech, "Speech"),
        new(EqPreset.Manual, "Manual"),
        new(EqPreset.Custom1, "Custom 1"),
        new(EqPreset.Custom2, "Custom 2"),
    ];

    private EqPresetChoice? _selectedEqPreset;
    public EqPresetChoice? SelectedEqPreset
    {
        get => _selectedEqPreset;
        set
        {
            if (Set(ref _selectedEqPreset, value))
            {
                _bandsDebounce?.Stop();
                Raise(nameof(EqBandsEditable));
                if (!_suppressSend && value is not null)
                    _ = PushAsync(() => _session.SetEqPresetAsync(value.Id));
            }
        }
    }

    private bool _eqAvailable = true;
    public bool EqAvailable { get => _eqAvailable; private set { Set(ref _eqAvailable, value); Raise(nameof(EqBandsEditable)); } }

    public bool EqBandsEditable =>
        IsConnected && EqAvailable && SelectedEqPreset is { Id: >= EqPreset.Manual };

    private readonly double[] _bands = new double[5];
    private double _clearBass;
    public double ClearBass { get => _clearBass; set { if (Set(ref _clearBass, Math.Clamp(Math.Round(value), -10, 10)) && !_suppressSend) DebounceBands(); } }
    public double Band1 { get => _bands[0]; set => SetBand(0, value); }
    public double Band2 { get => _bands[1]; set => SetBand(1, value); }
    public double Band3 { get => _bands[2]; set => SetBand(2, value); }
    public double Band4 { get => _bands[3]; set => SetBand(3, value); }
    public double Band5 { get => _bands[4]; set => SetBand(4, value); }

    private void SetBand(int i, double value, [CallerMemberName] string? name = null)
    {
        double clamped = Math.Clamp(Math.Round(value), -10, 10);
        if (_bands[i] == clamped) return;
        _bands[i] = clamped;
        Raise(name);
        if (!_suppressSend) DebounceBands();
    }

    private DispatcherTimer? _bandsDebounce;
    private void DebounceBands()
    {
        _bandsDebounce ??= CreateBandsDebounce();
        _bandsDebounce.Stop();
        _bandsDebounce.Start();
    }

    private DispatcherTimer CreateBandsDebounce()
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (SelectedEqPreset is not { Id: >= EqPreset.Manual } preset) return;
            _ = PushAsync(() => _session.SetEqBandsAsync(preset.Id, (int)ClearBass,
                [(int)Band1, (int)Band2, (int)Band3, (int)Band4, (int)Band5]));
        };
        return timer;
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
        Raise(nameof(EqBandsEditable));
    }

    private void ApplyEvent(DeviceEvent evt)
    {
        _suppressSend = true;
        try
        {
            switch (evt)
            {
                case NcAmbEvent e:
                    SelectMode(e.Mode);
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

    private void ApplyEqEvent(DeviceEvent evt)
    {
        switch (evt)
        {
            case EqStatusEvent e:
                EqAvailable = e.Available;
                break;
            case EqEvent e:
                SelectedEqPreset = EqPresets.FirstOrDefault(p => p.Id == e.Preset)
                    ?? new EqPresetChoice(e.Preset, $"Preset 0x{(byte)e.Preset:X2}");
                if (e.Bands.Length == 5)
                {
                    ClearBass = e.ClearBass;
                    Band1 = e.Bands[0]; Band2 = e.Bands[1]; Band3 = e.Bands[2];
                    Band4 = e.Bands[3]; Band5 = e.Bands[4];
                }
                break;
        }
    }

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
