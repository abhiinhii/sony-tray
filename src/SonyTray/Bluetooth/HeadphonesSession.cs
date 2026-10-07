using System.IO;
using System.Runtime.InteropServices;
using SonyProtocol;
using SonyTray.Services;

namespace SonyTray.Bluetooth;

public enum SessionState { Disconnected, Connecting, Ready, BluetoothOff }

public sealed record DeviceCapabilities(
    NcAmbVariant NcVariant, bool HasNcMode, IReadOnlyList<BatteryKind> Batteries,
    bool HasEq, bool HasPowerOff, string DeviceName)
{
    public IReadOnlySet<BatteryKind> ThresholdBatteries { get; init; } = new HashSet<BatteryKind>();
}

public sealed class HeadphonesSession : IAsyncDisposable, IHeadphonesSession
{
    private const int AckRetries = 2;
    private static readonly TimeSpan MaxBackoff = TimeSpan.FromSeconds(30);
    private readonly CancellationTokenSource _cts = new();
    private readonly SemaphoreSlim _commandLock = new(1, 1);
    private readonly SemaphoreSlim _queryLock = new(1, 1);
    private readonly object _gate = new();
    private readonly Func<IHeadphonesTransport> _createTransport;
    private readonly Func<CancellationToken, Task<(string Id, string Name)?>> _findDevice;
    private readonly Func<CancellationToken, Task<bool>> _isBluetoothOff;
    private readonly SessionOptions _options;
    private Connection? _connection;
    private Task? _runTask;
    private long _connectionVersion;
    private int _disposed;

    // Waiters and sequence state belong to one transport, never to its replacement.
    private sealed class Connection
    {
        public Connection(IHeadphonesTransport transport, CancellationToken ct)
        {
            Transport = transport;
            Lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
            Token = Lifetime.Token;
        }
        public IHeadphonesTransport Transport { get; }
        public CancellationTokenSource Lifetime { get; }
        public CancellationToken Token { get; }
        public TaskCompletionSource Dropped { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource? Ack;
        public TaskCompletionSource? ProtocolInfo;
        public TaskCompletionSource<SupportFunctionsEvent>? SupportFunctions;
        public DeviceCapabilities? Capabilities;
        public byte Seq;
    }

    public HeadphonesSession() : this(() => new RfcommClient(), RfcommClient.FindDeviceIdAsync,
        RfcommClient.IsBluetoothOffAsync, new SessionOptions()) { }

    internal HeadphonesSession(Func<IHeadphonesTransport> createTransport,
        Func<CancellationToken, Task<(string Id, string Name)?>> findDevice,
        Func<CancellationToken, Task<bool>> isBluetoothOff, SessionOptions options)
    {
        _createTransport = createTransport;
        _findDevice = findDevice;
        _isBluetoothOff = isBluetoothOff;
        _options = options;
    }

    public long ConnectionVersion => Interlocked.Read(ref _connectionVersion);
    private volatile SessionState _state = SessionState.Disconnected;
    public SessionState State => _state;
    public event Action<SessionState>? StateChanged;
    public event Action<DeviceEvent>? DeviceUpdated;
    public event Action<DeviceCapabilities>? CapabilitiesResolved;

    public void Start()
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed != 0, this);
            _runTask ??= Task.Run(() => RunAsync(_cts.Token));
        }
    }

    private async Task RunAsync(CancellationToken ct)
    {
        TimeSpan backoff = _options.RetryDelay;
        while (!ct.IsCancellationRequested)
        {
            Connection? connection = null;
            try
            {
                lock (_gate)
                {
                    Interlocked.Increment(ref _connectionVersion);
                    SetState(SessionState.Connecting);
                }
                if (await _isBluetoothOff(ct))
                {
                    SetState(SessionState.BluetoothOff);
                    await Task.Delay(_options.BluetoothOffDelay, ct);
                    continue;
                }
                var found = await _findDevice(ct) ?? throw new IOException("No paired Sony headset reachable");
                connection = new Connection(_createTransport(), ct);
                Connection current = connection;
                current.Transport.FrameReceived += frame => OnFrame(current, frame);
                current.Transport.Disconnected += error => Retire(current, error?.Message ?? "Socket disconnected");
                lock (_gate)
                {
                    ct.ThrowIfCancellationRequested();
                    _connection = current;
                }
                await current.Transport.ConnectAsync(found.Id, current.Token);
                await InitializeAsync(current, string.IsNullOrWhiteSpace(found.Name) ? "Sony Headphones" : found.Name);
                lock (_gate)
                {
                    EnsureCurrent(current);
                    SetState(SessionState.Ready);
                }
                backoff = _options.RetryDelay;
                while (!current.Token.IsCancellationRequested)
                {
                    // A live socket/ACK is insufficient: require an MDR protocol response.
                    Task interval = Task.Delay(_options.RefreshInterval, current.Token);
                    if (await Task.WhenAny(current.Dropped.Task, interval) == current.Dropped.Task) break;
                    await interval;
                    await RefreshAsync(current);
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            catch (Exception ex) { Log.Info($"Session attempt ended: {ex.Message}"); }
            finally
            {
                if (connection is not null)
                {
                    Retire(connection, "Session ended");
                    connection.Lifetime.Cancel();
                    try { await connection.Transport.DisposeAsync(); }
                    catch (Exception ex) { Log.Info($"Transport cleanup failed: {ex.Message}"); }
                    // Queued commands hold the cached, already-canceled token. Disposing the
                    // source also releases its registration on the app lifetime token.
                    connection.Lifetime.Dispose();
                }
            }
            SetState(SessionState.Disconnected);
            try { await Task.Delay(backoff, ct); } catch (OperationCanceledException) { break; }
            backoff = backoff * 2 > MaxBackoff ? MaxBackoff : backoff * 2;
        }
        SetState(SessionState.Disconnected);
    }

    private void EnsureCurrent(Connection connection)
    {
        connection.Token.ThrowIfCancellationRequested();
        if (!ReferenceEquals(_connection, connection)) throw new InvalidOperationException("Connection replaced");
    }

    private Connection CaptureConnection()
    {
        lock (_gate)
        {
            Connection connection = _connection ?? throw new InvalidOperationException("Not connected");
            EnsureCurrent(connection);
            return connection;
        }
    }

    private void Retire(Connection connection, string reason)
    {
        lock (_gate)
        {
            if (!ReferenceEquals(_connection, connection)) return;
            _connection = null;
            connection.Capabilities = null;
            Interlocked.Increment(ref _connectionVersion);
            Log.Info($"Connection ended; will reconnect: {reason}");
            connection.Dropped.TrySetResult();
            connection.Lifetime.Cancel();
            SetState(SessionState.Disconnected);
        }
    }

    private async Task InitializeAsync(Connection connection, string name)
    {
        await _queryLock.WaitAsync(connection.Token);
        try
        {
            await RequestProtocolInfoAsync(connection);
            var support = new TaskCompletionSource<SupportFunctionsEvent>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_gate) { EnsureCurrent(connection); connection.SupportFunctions = support; }
            await SendCommandAsync(connection, Commands.GetSupportFunctions());
            SupportFunctionsEvent reply = await support.Task.WaitAsync(_options.ReplyTimeout, connection.Token);
            DeviceCapabilities caps = ResolveCapabilities(reply.Functions, name);
            lock (_gate)
            {
                EnsureCurrent(connection);
                connection.Capabilities = caps;
                CapabilitiesResolved?.Invoke(caps);
            }
            await RunCapabilityQueriesAsync(connection, caps);
        }
        finally { _queryLock.Release(); }
    }

    private async Task RequestProtocolInfoAsync(Connection connection)
    {
        var reply = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_gate) { EnsureCurrent(connection); connection.ProtocolInfo = reply; }
        await SendCommandAsync(connection, Commands.GetProtocolInfo());
        await reply.Task.WaitAsync(_options.ReplyTimeout, connection.Token);
    }

    internal static DeviceCapabilities ResolveCapabilities(IReadOnlySet<byte> functions, string name)
    {
        NcAmbVariant variant;
        bool hasNc;
        if (functions.Contains(0x6B)) { variant = NcAmbVariant.DualSeamless; hasNc = true; }
        else if (functions.Contains(0x6D)) { variant = NcAmbVariant.DualSeamlessNoiseAdaptive; hasNc = true; }
        else if (functions.Contains(0x67)) { variant = NcAmbVariant.AsmSeamless; hasNc = false; }
        else
        {
            Log.Info("No known NC/AMB function; falling back to XM5-style DualSeamless (0x17)");
            variant = NcAmbVariant.DualSeamless;
            hasNc = true;
        }
        var batteries = new List<BatteryKind>();
        var threshold = new HashSet<BatteryKind>();
        foreach (BatteryKind kind in Enum.GetValues<BatteryKind>())
        {
            byte basic = (byte)(0x20 + (byte)kind);
            byte withThreshold = (byte)(basic + 8);
            if (functions.Contains(basic)) batteries.Add(kind);
            else if (functions.Contains(withThreshold)) { batteries.Add(kind); threshold.Add(kind); }
        }
        return new DeviceCapabilities(variant, hasNc, batteries,
            functions.Contains(0x50) || functions.Contains(0x52) || functions.Contains(0x57),
            functions.Contains(0x23), name) { ThresholdBatteries = threshold };
    }

    private async Task RunCapabilityQueriesAsync(Connection connection, DeviceCapabilities caps)
    {
        await SendCommandAsync(connection, Commands.GetNcAmb(caps.NcVariant));
        if (caps.HasEq)
        {
            await SendCommandAsync(connection, Commands.GetEqStatus());
            await SendCommandAsync(connection, Commands.GetEq());
        }
        foreach (BatteryKind kind in caps.Batteries)
            await SendCommandAsync(connection, Commands.GetBattery(kind, caps.ThresholdBatteries.Contains(kind)));
    }

    private void OnFrame(Connection connection, Frame frame)
    {
        lock (_gate)
        {
            if (!ReferenceEquals(_connection, connection) || connection.Token.IsCancellationRequested) return;
            connection.Seq = frame.Seq;
            if (frame.Type == MessageType.Ack)
            {
                Interlocked.Exchange(ref connection.Ack, null)?.TrySetResult();
                return;
            }
            if (frame.Type != MessageType.DataMdr) return;
            _ = SendAckAsync(connection, frame.Seq);
            if (!ReferenceEquals(_connection, connection)) return; // synchronous ACK failure
            DeviceEvent? evt = PayloadParser.Parse(frame.Payload);
            if (evt is null) { Log.Debug($"Unhandled payload {Convert.ToHexString(frame.Payload)}"); return; }
            if (evt is ProtocolInfoEvent) connection.ProtocolInfo?.TrySetResult();
            if (evt is SupportFunctionsEvent support) connection.SupportFunctions?.TrySetResult(support);
            DeviceUpdated?.Invoke(evt);
        }
    }

    private async Task SendAckAsync(Connection connection, byte seq)
    {
        try
        {
            using var write = CancellationTokenSource.CreateLinkedTokenSource(connection.Token);
            write.CancelAfter(_options.AckTimeout);
            await connection.Transport.SendFrameAsync(MessageType.Ack, (byte)(1 - seq), [], write.Token).WaitAsync(write.Token);
        }
        catch (OperationCanceledException) when (connection.Token.IsCancellationRequested) { }
        catch (Exception ex) { Retire(connection, $"ACK send failed: {ex.Message}"); }
    }

    private async Task SendCommandAsync(Connection connection, byte[] payload)
    {
        await _commandLock.WaitAsync(connection.Token);
        try
        {
            for (int attempt = 0; attempt <= AckRetries; attempt++)
            {
                var ack = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                byte seq;
                lock (_gate) { EnsureCurrent(connection); connection.Ack = ack; seq = connection.Seq; }
                try
                {
                    // Bound the write as well as the ACK wait: a stalled native write must
                    // not monopolize the command lock indefinitely.
                    using var write = CancellationTokenSource.CreateLinkedTokenSource(connection.Token);
                    write.CancelAfter(_options.AckTimeout);
                    await connection.Transport.SendFrameAsync(MessageType.DataMdr, seq, payload, write.Token).WaitAsync(write.Token);
                    await ack.Task.WaitAsync(_options.AckTimeout, connection.Token);
                    return;
                }
                catch (OperationCanceledException) when (!connection.Token.IsCancellationRequested)
                {
                    // A partially completed write cannot safely be retried on this channel.
                    Retire(connection, "Command write timed out");
                    throw new TimeoutException("Device command write timed out");
                }
                catch (Exception ex) when (ex is TimeoutException or InvalidOperationException
                    or ObjectDisposedException or IOException or COMException)
                {
                    Log.Info($"Command attempt {attempt + 1} failed: {ex.Message}");
                }
                finally { Interlocked.CompareExchange(ref connection.Ack, null, ack); }
            }
            Retire(connection, "Command was not acknowledged");
            throw new TimeoutException("Device did not acknowledge the command; reconnecting");
        }
        finally { _commandLock.Release(); }
    }

    public Task SetNcAmbAsync(NcAmbMode mode, int ambientLevel, bool focusOnVoice)
    {
        Connection connection = CaptureConnection();
        return SendCommandAsync(connection, Commands.SetNcAmb(
            connection.Capabilities?.NcVariant ?? NcAmbVariant.DualSeamless, mode, ambientLevel, focusOnVoice));
    }

    public async Task SetEqPresetAsync(EqPreset preset)
    {
        Connection connection = CaptureConnection();
        await SendCommandAsync(connection, Commands.SetEqPreset(preset));
        await SendCommandAsync(connection, Commands.GetEq());
    }

    public Task SetEqBandsAsync(EqPreset preset, int clearBass, int[] bands) =>
        SendCommandAsync(CaptureConnection(), Commands.SetEqBands(preset, clearBass, bands));
    public Task SetEqBands10Async(EqPreset preset, int[] bands) =>
        SendCommandAsync(CaptureConnection(), Commands.SetEqBands10(preset, bands));
    public Task PowerOffAsync() => SendCommandAsync(CaptureConnection(), Commands.PowerOff());
    public Task RefreshAsync() => RefreshAsync(CaptureConnection());

    private async Task RefreshAsync(Connection connection)
    {
        await _queryLock.WaitAsync(connection.Token);
        try
        {
            await RequestProtocolInfoAsync(connection);
            DeviceCapabilities? caps = connection.Capabilities;
            if (caps is not null) await RunCapabilityQueriesAsync(connection, caps);
        }
        catch (OperationCanceledException) when (connection.Token.IsCancellationRequested) { throw; }
        catch (Exception ex) { Retire(connection, $"Refresh failed: {ex.Message}"); throw; }
        finally { _queryLock.Release(); }
    }

    private void SetState(SessionState state)
    {
        lock (_gate)
        {
            if (State == state) return;
            _state = state;
            StateChanged?.Invoke(state);
        }
    }

    public async ValueTask DisposeAsync()
    {
        Task? run;
        lock (_gate)
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            if (_connection is { } connection) Retire(connection, "Session stopped");
            run = _runTask;
        }
        await _cts.CancelAsync();
        if (run is not null) await run;
        // Semaphores may have canceled callers unwinding through finally; GC owns them.
        _cts.Dispose();
    }
}
