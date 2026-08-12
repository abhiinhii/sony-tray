using System.Collections.ObjectModel;
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
    // 6-band devices (XM5-class): Clear Bass first, then 400/1k/2.5k/6.3k/16k Hz, range −10…+10.
    private static readonly (string Label, double Min, double Max)[] SixBandLayout =
    [
        ("CB", -10, 10), ("400", -10, 10), ("1k", -10, 10),
        ("2.5k", -10, 10), ("6.3k", -10, 10), ("16k", -10, 10),
    ];

    // 10-band devices: no Clear Bass, range −6…+6.
    private static readonly (string Label, double Min, double Max)[] TenBandLayout =
    [
        ("31", -6, 6), ("63", -6, 6), ("125", -6, 6), ("250", -6, 6), ("500", -6, 6),
        ("1k", -6, 6), ("2k", -6, 6), ("4k", -6, 6), ("8k", -6, 6), ("16k", -6, 6),
    ];

    private readonly HeadphonesSession _session;
    private readonly DispatcherTimer _ambientDebounce;
    private bool _suppressSend; // true while applying device state to the UI
    private NcAmbMode _mode = NcAmbMode.NoiseCancelling;
    private bool _isTenBandEq;

    public MainViewModel(HeadphonesSession session)
    {
        _session = session;
        _ambientDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        _ambientDebounce.Tick += (_, _) => { _ambientDebounce.Stop(); PushMode(); };
        PowerOffCommand = new RelayCommand(() => _ = PushAsync(() => _session.PowerOffAsync()));
        InitBands(SixBandLayout, new double[6]);
        session.StateChanged += s => OnUi(() => ApplyState(s));
        session.DeviceUpdated += e => OnUi(() => ApplyEvent(e));
        session.CapabilitiesResolved += c => OnUi(() => ApplyCapabilities(c));
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action<bool>? ConnectionChanged; // App updates the tray icon from this

    private bool _isConnected;
    public bool IsConnected { get => _isConnected; private set { Set(ref _isConnected, value); ConnectionChanged?.Invoke(value); } }

    public RelayCommand PowerOffCommand { get; }

    // Default true until capabilities resolve (matches pre-Task-15 XM5-only behavior).
    private bool _powerOffVisible = true;
    public bool PowerOffVisible { get => _powerOffVisible; private set => Set(ref _powerOffVisible, value); }

    private string _deviceName = "Sony Headphones";
    public string DeviceName { get => _deviceName; private set => Set(ref _deviceName, value); }

    // Default true so the NC chip is present before capabilities resolve (matches XM5 v1 behavior).
    private bool _hasNcChip = true;
    public bool HasNcChip { get => _hasNcChip; private set { Set(ref _hasNcChip, value); Raise(nameof(ModeChipColumns)); } }

    public int ModeChipColumns => HasNcChip ? 3 : 2;

    // Default true so the EQ section is visible before capabilities resolve (matches XM5 v1 behavior).
    private bool _hasEqSection = true;
    public bool HasEqSection { get => _hasEqSection; private set => Set(ref _hasEqSection, value); }

    private string _statusText = "Searching for headphones…";
    public string StatusText { get => _statusText; private set => Set(ref _statusText, value); }

    private string _batteryText = "–";
    public string BatteryText { get => _batteryText; private set => Set(ref _batteryText, value); }

    // Latest readings per announced battery kind — composed into BatteryText as they arrive.
    private int? _singleLevel;
    private ChargingStatus _singleCharging;
    private int? _leftLevel;
    private ChargingStatus _leftCharging;
    private int? _rightLevel;
    private ChargingStatus _rightCharging;
    private int? _cradleLevel;
    private ChargingStatus _cradleCharging;

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

    /// <summary>One entry per equalizer band/slider — 6 (Clear Bass + 5) or 10, driven by the device's EqEvent.</summary>
    public ObservableCollection<BandViewModel> EqBands { get; } = [];

    private void InitBands((string Label, double Min, double Max)[] layout, IReadOnlyList<double> values)
    {
        EqBands.Clear();
        for (int i = 0; i < layout.Length; i++)
            EqBands.Add(new BandViewModel(this, layout[i].Label, layout[i].Min, layout[i].Max, values[i]));
    }

    private void ApplyBandValues(IReadOnlyList<double> values)
    {
        for (int i = 0; i < values.Count && i < EqBands.Count; i++)
            EqBands[i].Value = values[i];
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
            if (_isTenBandEq)
            {
                int[] bands = EqBands.Select(b => (int)b.Value).ToArray();
                _ = PushAsync(() => _session.SetEqBands10Async(preset.Id, bands));
            }
            else
            {
                int clearBass = (int)EqBands[0].Value;
                int[] bands = EqBands.Skip(1).Select(b => (int)b.Value).ToArray();
                _ = PushAsync(() => _session.SetEqBandsAsync(preset.Id, clearBass, bands));
            }
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

    private void ApplyCapabilities(DeviceCapabilities caps)
    {
        DeviceName = caps.DeviceName;
        HasNcChip = caps.HasNcMode;
        HasEqSection = caps.HasEq;
        PowerOffVisible = caps.HasPowerOff;
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
                    _singleLevel = e.Level;
                    _singleCharging = e.Charging;
                    RecomputeBatteryText();
                    break;
                case LeftRightBatteryEvent e:
                    _leftLevel = e.LeftLevel;
                    _leftCharging = e.LeftCharging;
                    _rightLevel = e.RightLevel;
                    _rightCharging = e.RightCharging;
                    RecomputeBatteryText();
                    break;
                case CradleBatteryEvent e:
                    _cradleLevel = e.Level;
                    _cradleCharging = e.Charging;
                    RecomputeBatteryText();
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

    private static string FormatBatteryPart(int level, ChargingStatus charging) =>
        charging == ChargingStatus.Charging ? $"{level}% ⚡" : $"{level}%";

    private void RecomputeBatteryText()
    {
        string core;
        if (_leftLevel is int l && _rightLevel is int r)
            core = $"L {FormatBatteryPart(l, _leftCharging)} · R {FormatBatteryPart(r, _rightCharging)}";
        else if (_singleLevel is int s)
            core = FormatBatteryPart(s, _singleCharging);
        else
        {
            BatteryText = "–";
            return;
        }

        if (_cradleLevel is int c)
            core += $" · Case {FormatBatteryPart(c, _cradleCharging)}";

        BatteryText = core;
    }

    private void ApplyEqEvent(DeviceEvent evt)
    {
        switch (evt)
        {
            case EqStatusEvent e:
                EqAvailable = e.Available;
                break;
            case EqEvent e when e.Bands.Length == 5: // 6-band device: Clear Bass + 5
            {
                _isTenBandEq = false;
                SelectedEqPreset = EqPresets.FirstOrDefault(p => p.Id == e.Preset)
                    ?? new EqPresetChoice(e.Preset, $"Preset 0x{(byte)e.Preset:X2}");
                double[] values = [e.ClearBass, e.Bands[0], e.Bands[1], e.Bands[2], e.Bands[3], e.Bands[4]];
                if (EqBands.Count != SixBandLayout.Length) InitBands(SixBandLayout, values);
                else ApplyBandValues(values);
                break;
            }
            case EqEvent e when e.Bands.Length == 10: // 10-band device, no Clear Bass
            {
                _isTenBandEq = true;
                SelectedEqPreset = EqPresets.FirstOrDefault(p => p.Id == e.Preset)
                    ?? new EqPresetChoice(e.Preset, $"Preset 0x{(byte)e.Preset:X2}");
                double[] values = e.Bands.Select(b => (double)b).ToArray();
                if (EqBands.Count != TenBandLayout.Length) InitBands(TenBandLayout, values);
                else ApplyBandValues(values);
                break;
            }
            case EqEvent e:
                SelectedEqPreset = EqPresets.FirstOrDefault(p => p.Id == e.Preset)
                    ?? new EqPresetChoice(e.Preset, $"Preset 0x{(byte)e.Preset:X2}");
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

    /// <summary>One equalizer slider: label, allowed range, and current value (user scale).</summary>
    public sealed class BandViewModel : INotifyPropertyChanged
    {
        private readonly MainViewModel _owner;
        private double _value;

        internal BandViewModel(MainViewModel owner, string label, double min, double max, double initial)
        {
            _owner = owner;
            Label = label;
            Min = min;
            Max = max;
            _value = initial;
        }

        public string Label { get; }
        public double Min { get; }
        public double Max { get; }

        public double Value
        {
            get => _value;
            set
            {
                double clamped = Math.Clamp(Math.Round(value), Min, Max);
                if (_value == clamped) return;
                _value = clamped;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Value)));
                if (!_owner._suppressSend) _owner.DebounceBands();
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
    }
}
