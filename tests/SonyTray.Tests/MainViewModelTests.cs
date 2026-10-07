using System.Windows.Threading;
using SonyProtocol;
using SonyTray.Bluetooth;
using SonyTray.ViewModels;

namespace SonyTray.Tests;

public sealed class MainViewModelTests
{
    // Run the production WPF dispatcher and debounce timers, without creating Application,
    // windows, a tray icon, or any Bluetooth objects.
    private static Task OnSta(Action test)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try { test(); done.TrySetResult(); }
            catch (Exception ex) { done.TrySetException(ex); }
            finally { Dispatcher.CurrentDispatcher.InvokeShutdown(); }
        }) { IsBackground = true };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return done.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }

    private static void Pump(int milliseconds = 50)
    {
        var frame = new DispatcherFrame();
        var stop = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(milliseconds) };
        stop.Tick += (_, _) => { stop.Stop(); frame.Continue = false; };
        stop.Start(); Dispatcher.PushFrame(frame);
    }

    private sealed class FakeSession : IHeadphonesSession
    {
        public long ConnectionVersion { get; private set; }
        public SessionState State { get; private set; }
        public event Action<SessionState>? StateChanged;
        public event Action<DeviceEvent>? DeviceUpdated;
        public event Action<DeviceCapabilities>? CapabilitiesResolved;
        internal int Sends;
        internal int Refreshes;
        internal Func<Task> Send { get; set; } = () => Task.CompletedTask;
        internal void Connect(params BatteryKind[] batteries)
        {
            ConnectionVersion++;
            State = SessionState.Connecting; StateChanged?.Invoke(State);
            CapabilitiesResolved?.Invoke(new DeviceCapabilities(NcAmbVariant.DualSeamless, true, batteries, true, true, "Mock"));
            State = SessionState.Ready; StateChanged?.Invoke(State);
        }
        internal void Drop()
        {
            ConnectionVersion++; State = SessionState.Disconnected; StateChanged?.Invoke(State);
        }
        internal void Emit(DeviceEvent evt) => DeviceUpdated?.Invoke(evt);
        private Task Command() { Sends++; return Send(); }
        public Task SetNcAmbAsync(NcAmbMode mode, int ambientLevel, bool focusOnVoice) => Command();
        public Task SetEqPresetAsync(EqPreset preset) => Command();
        public Task SetEqBandsAsync(EqPreset preset, int clearBass, int[] bands) => Command();
        public Task SetEqBands10Async(EqPreset preset, int[] bands) => Command();
        public Task PowerOffAsync() => Command();
        public Task RefreshAsync() { Refreshes++; return Task.CompletedTask; }
    }

    [Fact]
    public Task Disconnect_ClearsBatteryPresetAndBands() => OnSta(() =>
    {
        var session = new FakeSession(); var vm = new MainViewModel(session, Dispatcher.CurrentDispatcher);
        session.Connect(BatteryKind.Single);
        session.Emit(new BatteryEvent(75, ChargingStatus.Charging));
        session.Emit(new EqEvent(EqPreset.Custom1, 5, [1, 2, 3, 4, 5]));
        Assert.True(vm.EqBandsEditable); Assert.Contains("75%", vm.BatteryText);
        session.Drop();
        Assert.False(vm.IsConnected); Assert.False(vm.EqBandsEditable);
        Assert.Equal("\u2013", vm.BatteryText); Assert.Null(vm.SelectedEqPreset);
        Assert.All(vm.EqBands, b => Assert.Equal(0, b.Value));
        Assert.Equal(0, session.Sends);
    });

    [Fact]
    public Task NewCapabilities_ResetOldEqUnavailable_EvenIfStatusReplyIsMissing() => OnSta(() =>
    {
        var session = new FakeSession(); var vm = new MainViewModel(session, Dispatcher.CurrentDispatcher);
        session.Connect(BatteryKind.Single); session.Emit(new EqStatusEvent(false));
        Assert.False(vm.EqAvailable);
        session.Drop(); session.Connect(BatteryKind.LeftRight);
        session.Emit(new EqEvent(EqPreset.Custom2, 0, [0, 0, 0, 0, 0]));
        Assert.True(vm.EqAvailable); Assert.True(vm.EqBandsEditable);
    });

    [Fact]
    public Task Reconnect_DoesNotMixOldBatteryLayouts() => OnSta(() =>
    {
        var session = new FakeSession(); var vm = new MainViewModel(session, Dispatcher.CurrentDispatcher);
        session.Connect(BatteryKind.Single, BatteryKind.Cradle);
        session.Emit(new BatteryEvent(90, ChargingStatus.NotCharging));
        session.Emit(new CradleBatteryEvent(80, ChargingStatus.NotCharging));
        session.Drop(); session.Connect(BatteryKind.LeftRight);
        session.Emit(new LeftRightBatteryEvent(50, ChargingStatus.NotCharging, 60, ChargingStatus.NotCharging));
        Assert.Contains("50%", vm.BatteryText); Assert.Contains("60%", vm.BatteryText);
        Assert.DoesNotContain("90%", vm.BatteryText); Assert.DoesNotContain("Case", vm.BatteryText);
    });

    [Fact]
    public Task DisconnectAndReconnect_CancelAmbientAndBandDebounces() => OnSta(() =>
    {
        var session = new FakeSession(); var vm = new MainViewModel(session, Dispatcher.CurrentDispatcher);
        session.Connect(BatteryKind.Single); session.Emit(new EqEvent(EqPreset.Custom1, 0, [0, 0, 0, 0, 0]));
        vm.AmbientLevel = 10; vm.EqBands[1].Value = 3;
        session.Drop(); session.Connect(BatteryKind.Single);
        session.Emit(new EqEvent(EqPreset.Custom1, 0, [0, 0, 0, 0, 0]));
        Pump(450);
        Assert.Equal(0, session.Sends);
    });

    [Fact]
    public Task CurrentConnectionEdits_StillSendThroughRealDebounces() => OnSta(() =>
    {
        var session = new FakeSession(); var vm = new MainViewModel(session, Dispatcher.CurrentDispatcher);
        session.Connect(BatteryKind.Single); session.Emit(new EqEvent(EqPreset.Custom1, 0, [0, 0, 0, 0, 0]));
        vm.AmbientLevel = 10; vm.EqBands[1].Value = 3;
        Pump(450);
        Assert.Equal(2, session.Sends);
    });

    [Fact]
    public Task DispatcherQueuedOldEvents_AreIgnoredAfterDisconnect() => OnSta(() =>
    {
        var session = new FakeSession(); var vm = new MainViewModel(session, Dispatcher.CurrentDispatcher);
        session.Connect(BatteryKind.Single);
        // Joining a dedicated producer ensures its callbacks are queued before advancing the
        // connection version. It does not wait for work on this STA dispatcher.
        var producer = new Thread(() => { session.Emit(new BatteryEvent(99, ChargingStatus.NotCharging)); session.Emit(new EqStatusEvent(false)); });
        producer.Start(); Assert.True(producer.Join(TimeSpan.FromSeconds(1)));
        session.Drop(); session.Connect(BatteryKind.Single);
        Pump();
        Assert.Equal("\u2013", vm.BatteryText); Assert.True(vm.EqAvailable);
    });

    [Fact]
    public Task OldCommandFailure_DoesNotOverwriteReplacementStatusOrRefreshIt() => OnSta(() =>
    {
        var failed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var session = new FakeSession { Send = () => failed.Task };
        var vm = new MainViewModel(session, Dispatcher.CurrentDispatcher);
        session.Connect(BatteryKind.Single);
        vm.SelectedEqPreset = vm.EqPresets.First(p => p.Id == EqPreset.Custom1);
        session.Drop(); session.Connect(BatteryKind.Single);
        failed.TrySetException(new TimeoutException("old connection"));
        Pump();
        Assert.Equal("Connected", vm.StatusText); Assert.Equal(0, session.Refreshes);
    });

    [Fact]
    public Task OldUiEdits_DoNotTargetReplacementBeforeItsDispatcherUpdates() => OnSta(() =>
    {
        var session = new FakeSession(); var vm = new MainViewModel(session, Dispatcher.CurrentDispatcher);
        session.Connect(BatteryKind.Single); session.Emit(new EqEvent(EqPreset.Custom1, 0, [0, 0, 0, 0, 0]));
        vm.AmbientLevel = 10; vm.EqBands[1].Value = 3;
        var producer = new Thread(() => { session.Drop(); session.Connect(BatteryKind.Single); });
        producer.Start(); Assert.True(producer.Join(TimeSpan.FromSeconds(1)));
        // The dispatcher still displays the previous Ready connection at this point.
        vm.FocusOnVoice = true; vm.PowerOffCommand.Execute(null);
        Assert.Equal(0, session.Sends);
        Pump(450);
        Assert.Equal(0, session.Sends);
    });

    [Fact]
    public Task DisconnectedEditsAndPowerOff_DoNotSend() => OnSta(() =>
    {
        var session = new FakeSession(); var vm = new MainViewModel(session, Dispatcher.CurrentDispatcher);
        vm.AmbientLevel = 9; vm.FocusOnVoice = true;
        vm.SelectedEqPreset = vm.EqPresets.First(p => p.Id == EqPreset.Custom1);
        vm.EqBands[0].Value = 4; vm.PowerOffCommand.Execute(null);
        Pump(450);
        Assert.Equal(0, session.Sends);
    });
}
