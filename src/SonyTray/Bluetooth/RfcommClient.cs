using System.IO;
using System.Runtime.InteropServices;
using SonyProtocol;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Rfcomm;
using Windows.Devices.Enumeration;
using Windows.Networking.Sockets;
using Windows.Storage.Streams;
using SonyTray.Services;

namespace SonyTray.Bluetooth;

public sealed class RfcommClient : IHeadphonesTransport
{
    public static readonly Guid ServiceUuid = new("956C7B26-D49A-4BA8-B03F-B17D393CB6E2");

    private StreamSocket? _socket;
    private Stream? _output;
    private CancellationTokenSource? _readCts;
    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private Task? _readTask;
    private int _disposed;

    public event Action<Frame>? FrameReceived;
    public event Action<Exception?>? Disconnected;

    public RfcommClient() { }

    // Stream-based seam exercises the real framing, read loop, and send/dispose behavior
    // in tests without initializing WinRT or contacting any paired device.
    internal RfcommClient(Stream input, Stream output, CancellationToken ct)
    {
        _output = output;
        StartReadLoop(input, ct);
    }

    /// <summary>Finds the paired Sony headset (any paired device exposing the Sony MDR service).</summary>
    public static async Task<(string Id, string Name)?> FindDeviceIdAsync(CancellationToken ct = default)
    {
        using var discovery = CancellationTokenSource.CreateLinkedTokenSource(ct);
        discovery.CancelAfter(TimeSpan.FromSeconds(30));
        string selector = BluetoothDevice.GetDeviceSelectorFromPairingState(true);
        DeviceInformationCollection paired = await DeviceInformation.FindAllAsync(selector).AsTask(discovery.Token);
        var candidates = new List<(DeviceInformation Info, BluetoothDevice Device, bool Connected)>();
        try
        {
            foreach (DeviceInformation info in paired)
            {
                using var candidateTimeout = CancellationTokenSource.CreateLinkedTokenSource(discovery.Token);
                candidateTimeout.CancelAfter(TimeSpan.FromSeconds(5));
                try
                {
                    BluetoothDevice device = await BluetoothDevice.FromIdAsync(info.Id).AsTask(candidateTimeout.Token);
                    if (device is not null)
                        candidates.Add((info, device, device.ConnectionStatus == BluetoothConnectionStatus.Connected));
                }
                catch (OperationCanceledException) when (discovery.IsCancellationRequested) { throw; }
                catch (Exception ex) { Log.Info($"Paired device unavailable: {ex.Message}"); }
            }
            // Inventory before querying SDP, so an offline paired headset cannot win simply
            // because Windows enumerated it first. Identify Sony devices by their service UUID.
            var selected = await DeviceSelection.FindAsync(candidates.Select(c => new Candidate(c.Info, c.Device, c.Connected)),
                c => c.Connected, async (c, token) =>
                {
                    using var queryTimeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                    queryTimeout.CancelAfter(TimeSpan.FromSeconds(5));
                    var services = await c.Device.GetRfcommServicesForIdAsync(
                        RfcommServiceId.FromUuid(ServiceUuid), BluetoothCacheMode.Uncached).AsTask(queryTimeout.Token);
                    return services.Services.Count > 0;
                }, discovery.Token);
            if (selected is null) return null;
            Log.Info($"Found Sony device: {selected.Info.Name} (connected={selected.Connected})");
            return (selected.Info.Id, selected.Info.Name);
        }
        finally { foreach (var candidate in candidates) candidate.Device.Dispose(); }
    }

    private sealed record Candidate(DeviceInformation Info, BluetoothDevice Device, bool Connected);

    public async Task ConnectAsync(string deviceId, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        using BluetoothDevice device = await BluetoothDevice.FromIdAsync(deviceId).AsTask(timeout.Token);
        if (device is null) throw new IOException("Paired headset is unavailable");
        RfcommDeviceServicesResult services = await device.GetRfcommServicesForIdAsync(
            RfcommServiceId.FromUuid(ServiceUuid), BluetoothCacheMode.Uncached).AsTask(timeout.Token);
        if (services.Services.Count == 0)
            throw new IOException("Sony MDR RFCOMM service not reachable (headphones off?)");
        RfcommDeviceService service = services.Services[0];

        _socket = new StreamSocket();
        await _socket.ConnectAsync(service.ConnectionHostName, service.ConnectionServiceName).AsTask(timeout.Token);
        _output = _socket.OutputStream.AsStreamForWrite();
        Log.Info("RFCOMM socket connected");

        StartReadLoop(_socket.InputStream.AsStreamForRead(), ct);
    }

    private void StartReadLoop(Stream input, CancellationToken ct)
    {
        _readCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        CancellationToken readToken = _readCts.Token;
        _readTask = Task.Run(() => ReadLoopAsync(input, readToken));
    }

    private async Task ReadLoopAsync(Stream input, CancellationToken ct)
    {
        var reassembler = new FrameReassembler();
        var buffer = new byte[2048];
        try
        {
            while (!ct.IsCancellationRequested)
            {
                int read = await input.ReadAsync(buffer, ct);
                if (read == 0) break; // remote closed
                Log.Debug($"<< {Convert.ToHexString(buffer.AsSpan(0, read))}");
                reassembler.Feed(buffer.AsSpan(0, read));
                while (reassembler.TryDequeue(out Frame frame))
                    FrameReceived?.Invoke(frame);
            }
            Disconnected?.Invoke(null);
        }
        catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException or COMException)
        {
            // Cancellation is the graceful path; ObjectDisposedException/COMException show up
            // instead when DisposeAsync tears down the socket out from under a pending
            // ReadAsync (socket-first disposal, see DisposeAsync) — both are an expected,
            // intentional disconnect, not an error worth logging.
            Disconnected?.Invoke(null);
        }
        catch (Exception ex)
        {
            Log.Error($"Read loop ended: {ex.Message}");
            Disconnected?.Invoke(ex);
        }
        finally
        {
            try { input.Dispose(); }
            catch (Exception ex) when (ex is ObjectDisposedException or IOException or COMException) { }
        }
    }

    public async Task SendFrameAsync(MessageType type, byte seq, byte[] payload, CancellationToken ct)
    {
        byte[] packed = Framing.Pack(type, seq, payload);
        await _sendLock.WaitAsync(ct);
        try
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
            Stream output = _output ?? throw new InvalidOperationException("Not connected");
            Log.Debug($">> {Convert.ToHexString(packed)}");
            await output.WriteAsync(packed, ct);
            await output.FlushAsync(ct);
        }
        finally
        {
            _sendLock.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        // Dispose the socket FIRST: this aborts any pending WinRT I/O (in particular the read
        // loop's in-flight ReadAsync) at the transport level immediately. Disposing the
        // AsStreamForWrite/AsStreamForRead adapters first (or even just cancelling the read
        // loop's token) is not sufficient — the adapters can block trying to complete/flush a
        // pending native operation against a still-open socket, which was observed to hang
        // process shutdown for minutes. With the socket gone, the adapters' Dispose() calls
        // fault fast instead, so swallow the resulting ObjectDisposedException/IOException/
        // COMException at every disposal step — both so a throwing dispose can't skip the CTS
        // cancel and remaining cleanup, and because a COMException from the WinRT-backed
        // adapter after socket-first disposal would otherwise propagate through `await using`
        // and reintroduce the exit-hang/crash class this method exists to avoid.
        try { _socket?.Dispose(); } catch (Exception ex) when (ex is ObjectDisposedException or IOException or COMException) { }
        if (_readCts is not null)
        {
            await _readCts.CancelAsync();
            _readCts.Dispose();
        }
        try { _output?.Dispose(); } catch (Exception ex) when (ex is ObjectDisposedException or IOException or COMException) { }
        if (_readTask is not null)
        {
            try { await _readTask.WaitAsync(TimeSpan.FromSeconds(3)); }
            catch (TimeoutException) { Log.Info("RFCOMM read loop did not finish after socket disposal"); }
            catch (Exception ex) { Log.Info($"RFCOMM read loop cleanup failed: {ex.Message}"); }
        }
        // An in-flight send still releases this semaphore in finally after socket disposal.
        // Do not dispose it while that caller is unwinding.
    }

    internal static async Task<bool> IsBluetoothOffAsync(CancellationToken ct)
    {
        try
        {
            var adapter = await BluetoothAdapter.GetDefaultAsync().AsTask(ct);
            if (adapter is null) return false;
            var radio = await adapter.GetRadioAsync().AsTask(ct);
            return radio.State != Windows.Devices.Radios.RadioState.On;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception) { return false; }
    }
}
