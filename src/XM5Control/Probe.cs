using System.Runtime.InteropServices;
using SonyProtocol;
using XM5Control.Bluetooth;

namespace XM5Control;

/// <summary>`XM5Control.exe --probe` — console connectivity test without the UI.</summary>
public static class Probe
{
    [DllImport("kernel32.dll")]
    private static extern bool AllocConsole();

    // Deviation from brief (authorized): route console lines through Log.Info too, so a
    // non-interactive agent can verify the probe from the log file without attaching to the
    // allocated console.
    private static void Say(string s)
    {
        Console.WriteLine(s);
        XM5Control.Services.Log.Info("[probe] " + s);
    }

    public static async Task<int> RunAsync()
    {
        AllocConsole();
        Say("Searching for a paired WH-1000XM5…");
        string? deviceId = await RfcommClient.FindDeviceIdAsync();
        if (deviceId is null)
        {
            Say("FAIL: no paired device exposes the Sony MDR service. Are the headphones paired and on?");
            return 1;
        }

        await using var client = new RfcommClient();
        byte seq = 0;
        var done = new TaskCompletionSource();
        client.FrameReceived += frame =>
        {
            seq = frame.Seq;
            if (frame.Type == MessageType.DataMdr)
            {
                _ = client.SendFrameAsync(MessageType.Ack, (byte)(1 - frame.Seq), [], CancellationToken.None);
                DeviceEvent? evt = PayloadParser.Parse(frame.Payload);
                Say($"RECV {Convert.ToHexString(frame.Payload)}  =>  {evt?.ToString() ?? "(unparsed)"}");
                if (evt is ProtocolInfoEvent) done.TrySetResult();
            }
        };
        client.Disconnected += ex => Say($"Disconnected: {ex?.Message ?? "clean"}");

        Say("Connecting…");
        await client.ConnectAsync(deviceId, CancellationToken.None);
        await client.SendFrameAsync(MessageType.DataMdr, seq, SonyProtocol.Commands.GetProtocolInfo(), CancellationToken.None);

        Task finished = await Task.WhenAny(done.Task, Task.Delay(5000));
        Say(finished == done.Task
            ? "OK: protocol info received. Exiting."
            : "FAIL: no protocol info within 5 s. Exiting.");
        // Deviation from brief (authorized): non-interactive agents can't satisfy a blocking
        // Console.ReadLine(), so exit on a short fixed delay instead of waiting for input.
        await Task.Delay(2000);
        return finished == done.Task ? 0 : 1;
    }
}
