using System.IO;
using System.Runtime.InteropServices;
using SonyProtocol;
using SonyTray.Services;

namespace SonyTray.Bluetooth;

public enum SessionState
{
    Disconnected,
    Connecting,
    Ready,
    BluetoothOff,
}

/// <summary>
/// What a connected device announced via its support-function RET, and the choices derived
/// from it (which NcAsm wire variant to speak, which battery layouts to query, etc.).
/// </summary>
public sealed record DeviceCapabilities(
    NcAmbVariant NcVariant,
    bool HasNcMode,
    IReadOnlyList<BatteryKind> Batteries,
    bool HasEq,
    bool HasPowerOff,
    string DeviceName);

public sealed class HeadphonesSession : IAsyncDisposable
{
    private static readonly TimeSpan AckTimeout = TimeSpan.FromSeconds(2);
    private const int AckRetries = 2;
    private static readonly TimeSpan MaxBackoff = TimeSpan.FromSeconds(30);

    private readonly CancellationTokenSource _cts = new();
    private readonly SemaphoreSlim _commandLock = new(1, 1); // one in-flight command at a time
    private volatile RfcommClient? _client;
    private volatile byte _seq;
    private TaskCompletionSource? _ackTcs; // consumed once-only via Interlocked (see OnFrame/SendCommandAsync)
    private volatile TaskCompletionSource? _protocolInfoTcs;
    private volatile TaskCompletionSource<SupportFunctionsEvent>? _supportFunctionsTcs;
    private volatile DeviceCapabilities? _capabilities;
    private string _deviceName = "Sony Headphones";
    private int _disposed;

    public SessionState State { get; private set; } = SessionState.Disconnected;
    public event Action<SessionState>? StateChanged;
    public event Action<DeviceEvent>? DeviceUpdated;

    /// <summary>Raised once per successful connection, right after the support-function RET is resolved.</summary>
    public event Action<DeviceCapabilities>? CapabilitiesResolved;

    public void Start() => _ = Task.Run(() => RunAsync(_cts.Token));

    private async Task RunAsync(CancellationToken ct)
    {
        TimeSpan backoff = TimeSpan.FromSeconds(2);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                SetState(SessionState.Connecting);
                if (await IsBluetoothOffAsync())
                {
                    SetState(SessionState.BluetoothOff);
                    await Task.Delay(TimeSpan.FromSeconds(3), ct);
                    continue;
                }
                (string Id, string Name)? found = await RfcommClient.FindDeviceIdAsync();
                if (found is null)
                    throw new IOException("No paired Sony headset reachable");
                string deviceId = found.Value.Id;
                _deviceName = string.IsNullOrWhiteSpace(found.Value.Name) ? "Sony Headphones" : found.Value.Name;

                var client = new RfcommClient();
                var dropped = new TaskCompletionSource();
                client.FrameReceived += OnFrame;
                client.Disconnected += _ => dropped.TrySetResult();
                try
                {
                    await client.ConnectAsync(deviceId, ct);
                }
                catch
                {
                    // ConnectAsync threw or was canceled: `client` never made it into the
                    // `_client` field, so none of the catch blocks below would dispose it.
                    // Dispose it here before propagating so the socket/read-loop don't leak.
                    await client.DisposeAsync();
                    throw;
                }
                _client = client;
                _seq = 0;

                await InitAsync(ct);
                SetState(SessionState.Ready);
                backoff = TimeSpan.FromSeconds(2); // success resets backoff

                await dropped.Task.WaitAsync(ct); // hold until the socket drops
                await client.DisposeAsync();
                _client = null;
                Log.Info("Connection dropped; will reconnect");
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                Log.Info($"Connect attempt failed: {ex.Message}");
                if (_client is not null) { await _client.DisposeAsync(); _client = null; }
            }
            SetState(SessionState.Disconnected);
            try { await Task.Delay(backoff, ct); } catch (OperationCanceledException) { break; }
            backoff = backoff * 2 > MaxBackoff ? MaxBackoff : backoff * 2;
        }
    }

    private async Task InitAsync(CancellationToken ct)
    {
        _protocolInfoTcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await SendCommandAsync(SonyProtocol.Commands.GetProtocolInfo(), ct);
        await _protocolInfoTcs.Task.WaitAsync(TimeSpan.FromSeconds(3), ct);

        _supportFunctionsTcs = new TaskCompletionSource<SupportFunctionsEvent>(TaskCreationOptions.RunContinuationsAsynchronously);
        await SendCommandAsync(SonyProtocol.Commands.GetSupportFunctions(), ct);
        SupportFunctionsEvent sfe = await _supportFunctionsTcs.Task.WaitAsync(TimeSpan.FromSeconds(3), ct);

        DeviceCapabilities caps = ResolveCapabilities(sfe.Functions, _deviceName);
        _capabilities = caps;
        CapabilitiesResolved?.Invoke(caps);

        await RunCapabilityQueriesAsync(caps, ct);
    }

    /// <summary>
    /// Maps announced function ids (Table 1) to the wire variant/queries to use. Falls back to
    /// the XM5-like DualSeamless variant with NC support if the device didn't announce any of the
    /// known NcAsm function ids — better to guess XM5-compatible than to refuse to talk at all.
    /// </summary>
    private static DeviceCapabilities ResolveCapabilities(IReadOnlySet<byte> functions, string deviceName)
    {
        NcAmbVariant ncVariant;
        bool hasNcMode;
        if (functions.Contains(0x6B)) { ncVariant = NcAmbVariant.DualSeamless; hasNcMode = true; }
        else if (functions.Contains(0x6D)) { ncVariant = NcAmbVariant.DualSeamlessNoiseAdaptive; hasNcMode = true; }
        else if (functions.Contains(0x67)) { ncVariant = NcAmbVariant.AsmSeamless; hasNcMode = false; }
        else
        {
            Log.Info("Device did not announce a known NC/AMB function id (0x6B/0x6D/0x67); " +
                     "falling back to XM5-style DualSeamless (0x17)");
            ncVariant = NcAmbVariant.DualSeamless;
            hasNcMode = true;
        }

        var batteries = new List<BatteryKind>();
        if (functions.Contains(0x20) || functions.Contains(0x28)) batteries.Add(BatteryKind.Single);
        if (functions.Contains(0x21) || functions.Contains(0x29)) batteries.Add(BatteryKind.LeftRight);
        if (functions.Contains(0x22) || functions.Contains(0x2A)) batteries.Add(BatteryKind.Cradle);

        bool hasEq = functions.Contains(0x50) || functions.Contains(0x52) || functions.Contains(0x57);
        bool hasPowerOff = functions.Contains(0x23);

        return new DeviceCapabilities(ncVariant, hasNcMode, batteries, hasEq, hasPowerOff, deviceName);
    }

    private async Task RunCapabilityQueriesAsync(DeviceCapabilities caps, CancellationToken ct)
    {
        await SendCommandAsync(SonyProtocol.Commands.GetNcAmb(caps.NcVariant), ct);
        if (caps.HasEq)
        {
            await SendCommandAsync(SonyProtocol.Commands.GetEqStatus(), ct);
            await SendCommandAsync(SonyProtocol.Commands.GetEq(), ct);
        }
        foreach (BatteryKind kind in caps.Batteries)
            await SendCommandAsync(SonyProtocol.Commands.GetBattery(kind), ct);
    }

    private void OnFrame(Frame frame)
    {
        _seq = frame.Seq;
        switch (frame.Type)
        {
            case MessageType.Ack:
                // Consume once-only: whichever attempt currently owns _ackTcs gets this ACK,
                // and the field is cleared atomically so a duplicate/late ACK can't complete a
                // later attempt's TCS too (see the era-scoped clearing in SendCommandAsync).
                Interlocked.Exchange(ref _ackTcs, null)?.TrySetResult();
                break;
            case MessageType.DataMdr:
                ObserveFault(
                    _client?.SendFrameAsync(MessageType.Ack, (byte)(1 - frame.Seq), [], _cts.Token),
                    "ACK send");
                DeviceEvent? evt = PayloadParser.Parse(frame.Payload);
                if (evt is null)
                {
                    Log.Debug($"Unhandled payload {Convert.ToHexString(frame.Payload)}");
                    return;
                }
                if (evt is ProtocolInfoEvent) _protocolInfoTcs?.TrySetResult();
                if (evt is SupportFunctionsEvent sfe) _supportFunctionsTcs?.TrySetResult(sfe);
                DeviceUpdated?.Invoke(evt);
                break;
        }
    }

    /// <summary>Fire-and-forget helper that logs (instead of silently swallowing) a faulted task.</summary>
    private static void ObserveFault(Task? task, string context) =>
        task?.ContinueWith(
            t => Log.Info($"{context} failed: {t.Exception?.GetBaseException().Message}"),
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously);

    /// <summary>Sends one DATA_MDR command and awaits the device ACK (with retries).</summary>
    private async Task SendCommandAsync(byte[] payload, CancellationToken ct)
    {
        await _commandLock.WaitAsync(ct);
        try
        {
            for (int attempt = 0; attempt <= AckRetries; attempt++)
            {
                // Fresh, era-scoped TCS per attempt: OnFrame consumes it exactly once via
                // Interlocked.Exchange, so a late ACK for an earlier attempt can't complete a
                // later one.
                var ackTcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                _ackTcs = ackTcs;
                try
                {
                    // Re-read _client on every attempt (not once, before the loop): a disconnect
                    // between attempts must surface as a failed attempt here, not as an
                    // InvalidOperationException/ObjectDisposedException that breaks the
                    // documented "throws TimeoutException after retries" contract.
                    RfcommClient client = _client ?? throw new InvalidOperationException("Not connected");
                    await client.SendFrameAsync(MessageType.DataMdr, _seq, payload, ct);
                    await ackTcs.Task.WaitAsync(AckTimeout, ct);
                    return;
                }
                catch (Exception ex) when (ex is TimeoutException or InvalidOperationException
                    or ObjectDisposedException or IOException or COMException)
                {
                    // Only clear the field if it's still *this* attempt's TCS — if an ACK raced
                    // in and Interlocked.Exchange already consumed/cleared it, leave that alone.
                    Interlocked.CompareExchange(ref _ackTcs, null, ackTcs);
                    Log.Info($"Command attempt {attempt + 1} failed ({ex.GetType().Name}: {ex.Message}) for {Convert.ToHexString(payload)}");
                }
            }
            throw new TimeoutException("Device did not acknowledge the command (possible disconnect)");
        }
        finally
        {
            _commandLock.Release();
        }
    }

    // Signature stays mode/level/voice for the VM — the session applies whatever variant the
    // connected device announced.
    public Task SetNcAmbAsync(NcAmbMode mode, int ambientLevel, bool focusOnVoice)
    {
        NcAmbVariant variant = _capabilities?.NcVariant ?? NcAmbVariant.DualSeamless;
        return SendCommandAsync(SonyProtocol.Commands.SetNcAmb(variant, mode, ambientLevel, focusOnVoice), _cts.Token);
    }

    public async Task SetEqPresetAsync(EqPreset preset)
    {
        await SendCommandAsync(SonyProtocol.Commands.SetEqPreset(preset), _cts.Token);
        await SendCommandAsync(SonyProtocol.Commands.GetEq(), _cts.Token); // reference re-queries after preset change
    }

    /// <summary>6-band devices (XM5-class): Clear Bass + 5 bands.</summary>
    public Task SetEqBandsAsync(EqPreset preset, int clearBass, int[] bands) =>
        SendCommandAsync(SonyProtocol.Commands.SetEqBands(preset, clearBass, bands), _cts.Token);

    /// <summary>10-band devices: no Clear Bass.</summary>
    public Task SetEqBands10Async(EqPreset preset, int[] bands) =>
        SendCommandAsync(SonyProtocol.Commands.SetEqBands10(preset, bands), _cts.Token);

    // Device ACKs then drops the RFCOMM link; the reconnect loop's normal path handles the drop.
    public Task PowerOffAsync() =>
        SendCommandAsync(SonyProtocol.Commands.PowerOff(), _cts.Token);

    public Task RefreshAsync()
    {
        DeviceCapabilities? caps = _capabilities;
        return caps is null ? Task.CompletedTask : RunCapabilityQueriesAsync(caps, _cts.Token);
    }

    private static async Task<bool> IsBluetoothOffAsync()
    {
        try
        {
            Windows.Devices.Bluetooth.BluetoothAdapter adapter =
                await Windows.Devices.Bluetooth.BluetoothAdapter.GetDefaultAsync();
            if (adapter is null) return false; // no adapter at all — treat as generic not-connected
            Windows.Devices.Radios.Radio radio = await adapter.GetRadioAsync();
            return radio.State != Windows.Devices.Radios.RadioState.On;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private void SetState(SessionState state)
    {
        if (State == state) return;
        State = state;
        StateChanged?.Invoke(state);
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return; // idempotent: second call is a no-op
        await _cts.CancelAsync();
        if (_client is not null) await _client.DisposeAsync();
        _commandLock.Dispose();
        _cts.Dispose();
    }
}
