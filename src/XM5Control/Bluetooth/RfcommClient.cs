using System.IO;
using System.Runtime.InteropServices;
using SonyProtocol;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Rfcomm;
using Windows.Devices.Enumeration;
using Windows.Networking.Sockets;
using Windows.Storage.Streams;
using XM5Control.Services;

namespace XM5Control.Bluetooth;

public sealed class RfcommClient : IAsyncDisposable
{
    public static readonly Guid ServiceUuid = new("956C7B26-D49A-4BA8-B03F-B17D393CB6E2");

    private StreamSocket? _socket;
    private Stream? _output;
    private CancellationTokenSource? _readCts;
    private readonly SemaphoreSlim _sendLock = new(1, 1);

    public event Action<Frame>? FrameReceived;
    public event Action<Exception?>? Disconnected;

    /// <summary>Finds the paired WH-1000XM5 (any paired device exposing the Sony MDR service).</summary>
    public static async Task<string?> FindDeviceIdAsync()
    {
        string selector = BluetoothDevice.GetDeviceSelectorFromPairingState(true);
        DeviceInformationCollection paired = await DeviceInformation.FindAllAsync(selector);
        foreach (DeviceInformation info in paired)
        {
            using BluetoothDevice device = await BluetoothDevice.FromIdAsync(info.Id);
            if (device is null) continue;
            RfcommDeviceServicesResult services = await device.GetRfcommServicesForIdAsync(
                RfcommServiceId.FromUuid(ServiceUuid), BluetoothCacheMode.Uncached);
            if (services.Services.Count > 0)
            {
                Log.Info($"Found Sony device: {info.Name} ({info.Id})");
                return info.Id;
            }
        }
        return null;
    }

    public async Task ConnectAsync(string deviceId, CancellationToken ct)
    {
        using BluetoothDevice device = await BluetoothDevice.FromIdAsync(deviceId);
        RfcommDeviceServicesResult services = await device.GetRfcommServicesForIdAsync(
            RfcommServiceId.FromUuid(ServiceUuid), BluetoothCacheMode.Uncached);
        if (services.Services.Count == 0)
            throw new IOException("Sony MDR RFCOMM service not reachable (headphones off?)");
        RfcommDeviceService service = services.Services[0];

        _socket = new StreamSocket();
        await _socket.ConnectAsync(service.ConnectionHostName, service.ConnectionServiceName).AsTask(ct);
        _output = _socket.OutputStream.AsStreamForWrite();
        Log.Info("RFCOMM socket connected");

        _readCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _ = Task.Run(() => ReadLoopAsync(_socket.InputStream.AsStreamForRead(), _readCts.Token));
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
    }

    public async Task SendFrameAsync(MessageType type, byte seq, byte[] payload, CancellationToken ct)
    {
        if (_output is null) throw new InvalidOperationException("Not connected");
        byte[] packed = Framing.Pack(type, seq, payload);
        await _sendLock.WaitAsync(ct);
        try
        {
            Log.Debug($">> {Convert.ToHexString(packed)}");
            await _output.WriteAsync(packed, ct);
            await _output.FlushAsync(ct);
        }
        finally
        {
            _sendLock.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
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
        _sendLock.Dispose();
    }
}
