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
        Say("XM5 Control probe — Ctrl+C or Enter to exit.");
        await using var session = new HeadphonesSession();
        session.StateChanged += s => Say($"[state] {s}");
        session.DeviceUpdated += e => Say($"[event] {e}");
        session.Start();

        // Once Ready, exercise a round-trip: toggle ambient then restore NC.
        var readyOnce = new TaskCompletionSource();
        session.StateChanged += s => { if (s == SessionState.Ready) readyOnce.TrySetResult(); };
        Task first = await Task.WhenAny(readyOnce.Task, Task.Delay(15000));
        if (first != readyOnce.Task)
        {
            Say("FAIL: session did not become Ready within 15 s.");
            // Deviation from brief (authorized): non-interactive agents can't satisfy a blocking
            // Console.ReadLine(), so exit immediately with the failure code instead of waiting
            // for input.
            return 1;
        }
        Say("Ready. Watch your headphones: switching to Ambient…");
        await session.SetNcAmbAsync(NcAmbMode.Ambient, 15, focusOnVoice: false);
        await Task.Delay(2000);
        Say("…and back to Noise Cancelling.");
        await session.SetNcAmbAsync(NcAmbMode.NoiseCancelling, 15, focusOnVoice: false);
        Say("Round-trip complete. Events above should include NcAmbEvent updates.");
        // Deviation from brief (authorized): non-interactive agents can't satisfy a blocking
        // Console.ReadLine(), so exit on a short fixed delay instead of waiting for input.
        await Task.Delay(2000);
        return 0;
    }
}
