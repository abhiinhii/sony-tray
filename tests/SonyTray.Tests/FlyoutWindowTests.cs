using System.Collections;
using System.IO;
using System.Resources;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using SonyProtocol;
using SonyTray.Bluetooth;
using SonyTray.ViewModels;
using SonyTray.Views;

namespace SonyTray.Tests;

public sealed class FlyoutWindowTests
{
    private static readonly Color SelectedBlue = Color.FromRgb(0, 120, 212);

    // Exercise the production view and templates offscreen: no Application, native
    // window, notification icon, Bluetooth session, or interactive desktop is started.
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
        return done.Task.WaitAsync(TimeSpan.FromSeconds(10));
    }

    private static void Pump()
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle,
            new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
    }

    private static FrameworkElement Layout(FlyoutWindow window)
    {
        Pump();
        var root = Assert.IsAssignableFrom<FrameworkElement>(window.Content);
        root.Measure(new Size(window.Width, double.PositiveInfinity));
        root.Arrange(new Rect(0, 0, window.Width, root.DesiredSize.Height));
        root.UpdateLayout();
        Pump();
        return root;
    }

    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            DependencyObject child = VisualTreeHelper.GetChild(root, i);
            if (child is T match) yield return match;
            foreach (T descendant in Descendants<T>(child)) yield return descendant;
        }
    }

    private static RadioButton ModeButton(FrameworkElement root, string content) =>
        Assert.Single(Descendants<RadioButton>(root), b => Equals(b.Content, content));

    private static void AssertSelectedMode(FrameworkElement root, string selected)
    {
        foreach (string content in new[] { "Noise Cancel", "Ambient", "Off" })
        {
            RadioButton button = ModeButton(root, content);
            button.ApplyTemplate();
            var chip = Assert.IsType<Border>(button.Template.FindName("Chip", button));
            var brush = Assert.IsType<SolidColorBrush>(chip.Background);
            Assert.Equal(content == selected, button.IsChecked == true);
            if (content == selected) Assert.Equal(SelectedBlue, brush.Color);
            else Assert.NotEqual(SelectedBlue, brush.Color);
        }
    }

    private static (FakeSession Session, MainViewModel ViewModel, FlyoutWindow Window) CreateConnectedView()
    {
        var session = new FakeSession();
        var vm = new MainViewModel(session, Dispatcher.CurrentDispatcher);
        var window = new FlyoutWindow { DataContext = vm };
        session.Connect();
        Layout(window);
        return (session, vm, window);
    }

    [Fact]
    public Task HeadsetModeChanges_KeepExactlyOneChipBlueAfterRelayout() => OnSta(() =>
    {
        var (session, _, window) = CreateConnectedView();
        foreach (var (mode, label) in new[]
        {
            (NcAmbMode.Ambient, "Ambient"),
            (NcAmbMode.Off, "Off"),
            (NcAmbMode.NoiseCancelling, "Noise Cancel"),
        })
        {
            session.Emit(new NcAmbEvent(mode, 15, false));
            AssertSelectedMode(Layout(window), label);
            // Repeated tray openings reuse this view. Relayout must preserve the
            // selected state; rendering it needs no visible desktop window.
            FrameworkElement root = Layout(window);
            root.InvalidateMeasure();
            AssertSelectedMode(Layout(window), label);
        }
        Assert.Empty(session.ModeSends);
        Assert.False(window.IsVisible);
    });

    [Fact]
    public Task UserModeSelection_UpdatesBindingAndBlueChip() => OnSta(() =>
    {
        var (session, vm, window) = CreateConnectedView();
        session.Emit(new NcAmbEvent(NcAmbMode.Off, 12, false));
        FrameworkElement root = Layout(window);
        var peer = new RadioButtonAutomationPeer(ModeButton(root, "Ambient"));
        var provider = Assert.IsAssignableFrom<ISelectionItemProvider>(peer.GetPattern(PatternInterface.SelectionItem));
        provider.Select();
        Assert.True(vm.IsAmbientSelected);
        Assert.Equal(NcAmbMode.Ambient, Assert.Single(session.ModeSends));
        AssertSelectedMode(Layout(window), "Ambient");
        session.Emit(new NcAmbEvent(NcAmbMode.NoiseCancelling, 12, false));
        AssertSelectedMode(Layout(window), "Noise Cancel");
        Assert.False(window.IsVisible);
    });

    [Fact]
    public Task SixBandEq_ShowsNamedClearBassControlSeparateFromFiveFrequencies() => OnSta(() =>
    {
        var (session, _, window) = CreateConnectedView();
        session.Emit(new EqEvent(EqPreset.Custom1, 7, [1, 2, 3, 4, 5]));
        Layout(window);
        var panel = Assert.IsAssignableFrom<FrameworkElement>(window.FindName("ClearBassPanel"));
        var slider = Assert.IsType<Slider>(window.FindName("ClearBassSlider"));
        var frequencies = Assert.IsType<ItemsControl>(window.FindName("FrequencyBandsControl"));
        Assert.Equal(Visibility.Visible, panel.Visibility);
        Assert.Contains(Descendants<TextBlock>(panel), text => text.Text == "CLEAR BASS");
        Assert.Equal(-10, slider.Minimum);
        Assert.Equal(10, slider.Maximum);
        Assert.Equal(7, slider.Value);
        Assert.True(slider.IsEnabled);
        var bands = frequencies.Items.Cast<MainViewModel.BandViewModel>().ToArray();
        Assert.Equal(new[] { "400", "1k", "2.5k", "6.3k", "16k" }, bands.Select(b => b.Label));
        Assert.Equal(new double[] { 1, 2, 3, 4, 5 }, bands.Select(b => b.Value));
        Assert.False(window.IsVisible);
    });

    [Fact]
    public Task TenBandEq_HidesClearBassAndDisplaysAllTenFrequencies() => OnSta(() =>
    {
        var (session, _, window) = CreateConnectedView();
        session.Emit(new EqEvent(EqPreset.Custom2, 0, [1, 2, 3, 4, 5, 6, -1, -2, -3, -4]));
        Layout(window);
        var panel = Assert.IsAssignableFrom<FrameworkElement>(window.FindName("ClearBassPanel"));
        var frequencies = Assert.IsType<ItemsControl>(window.FindName("FrequencyBandsControl"));
        Assert.Equal(Visibility.Collapsed, panel.Visibility);
        var bands = frequencies.Items.Cast<MainViewModel.BandViewModel>().ToArray();
        Assert.Equal(new[] { "31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k" }, bands.Select(b => b.Label));
        Assert.Equal(new double[] { 1, 2, 3, 4, 5, 6, -1, -2, -3, -4 }, bands.Select(b => b.Value));
        Assert.False(window.IsVisible);
    });

    [Fact]
    public Task ClearBassSlider_RebindsAfterSixTenSixBandTransition() => OnSta(() =>
    {
        var (session, vm, window) = CreateConnectedView();
        session.Emit(new EqEvent(EqPreset.Custom1, 7, [1, 2, 3, 4, 5]));
        Layout(window);
        var firstBass = vm.EqBands[0];
        var slider = Assert.IsType<Slider>(window.FindName("ClearBassSlider"));
        Assert.Equal(7, slider.Value);
        session.Emit(new EqEvent(EqPreset.Custom2, 0, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
        Layout(window);
        var panel = Assert.IsAssignableFrom<FrameworkElement>(window.FindName("ClearBassPanel"));
        Assert.Equal(Visibility.Collapsed, panel.Visibility);
        session.Emit(new EqEvent(EqPreset.Custom1, -3, [0, 1, 2, 3, 4]));
        Layout(window);
        Assert.Equal(Visibility.Visible, panel.Visibility);
        Assert.Equal(-3, slider.Value);
        Assert.NotSame(firstBass, vm.EqBands[0]);
        slider.SetCurrentValue(System.Windows.Controls.Primitives.RangeBase.ValueProperty, 4d);
        Pump();
        Assert.Equal(4, vm.EqBands[0].Value);
        Assert.Equal(7, firstBass.Value);
        Assert.False(window.IsVisible);
    });

    [Fact]
    public Task ClearBassSlider_RebindsAfterDisconnectAndNewBandReply() => OnSta(() =>
    {
        var (session, vm, window) = CreateConnectedView();
        session.Emit(new EqEvent(EqPreset.Manual, 6, [1, 2, 3, 4, 5]));
        Layout(window);
        var previousBass = vm.EqBands[0];
        var slider = Assert.IsType<Slider>(window.FindName("ClearBassSlider"));
        session.Drop();
        Layout(window);
        var panel = Assert.IsAssignableFrom<FrameworkElement>(window.FindName("ClearBassPanel"));
        Assert.Equal(Visibility.Collapsed, panel.Visibility);
        Assert.False(slider.IsEnabled);
        session.Connect();
        Layout(window);
        Assert.Equal(Visibility.Collapsed, panel.Visibility);
        Assert.False(slider.IsEnabled);
        session.Emit(new EqEvent(EqPreset.Manual, -8, [5, 4, 3, 2, 1]));
        Layout(window);
        Assert.Equal(Visibility.Visible, panel.Visibility);
        Assert.True(slider.IsEnabled);
        Assert.Equal(-8, slider.Value);
        slider.SetCurrentValue(System.Windows.Controls.Primitives.RangeBase.ValueProperty, -2d);
        Pump();
        Assert.Equal(-2, vm.EqBands[0].Value);
        Assert.Equal(6, previousBass.Value);
        Assert.False(window.IsVisible);
    });
    [Theory]
    [InlineData(100)]
    [InlineData(150)]
    [InlineData(200)]
    public Task ClearBassLabel_FitsInFlyoutAtRenderScale(int percent) => OnSta(() =>
    {
        var (session, _, window) = CreateConnectedView();
        session.Emit(new EqEvent(EqPreset.Manual, 3, [0, 0, 0, 0, 0]));
        FrameworkElement root = Layout(window);
        var panel = Assert.IsAssignableFrom<FrameworkElement>(window.FindName("ClearBassPanel"));
        TextBlock label = Assert.Single(Descendants<TextBlock>(panel), text => text.Text == "CLEAR BASS");
        Assert.True(label.ActualWidth >= label.DesiredSize.Width);
        Assert.True(label.ActualHeight >= label.DesiredSize.Height);
        Rect bounds = label.TransformToAncestor(root).TransformBounds(new Rect(label.RenderSize));
        Assert.True(bounds.Left >= 0 && bounds.Top >= 0);
        Assert.True(bounds.Right <= root.ActualWidth && bounds.Bottom <= root.ActualHeight);
        double scale = percent / 100.0;
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.Width * scale),
            (int)Math.Ceiling(root.DesiredSize.Height * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        bitmap.Render(root);
        Assert.True(bitmap.PixelWidth > 0 && bitmap.PixelHeight > 0);
        Assert.False(window.IsVisible);
    });

    [Fact]
    public void ApplicationIcon_IsPackagedAsNonemptyWpfResource()
    {
        var assembly = typeof(FlyoutWindow).Assembly;
        using Stream resource = Assert.IsAssignableFrom<Stream>(assembly.GetManifestResourceStream("SonyTray.g.resources"));
        using var reader = new ResourceReader(resource);
        object? iconResource = reader.Cast<DictionaryEntry>()
            .Single(entry => Equals(entry.Key, "assets/app.ico")).Value;
        var iconStream = Assert.IsAssignableFrom<Stream>(iconResource);
        Assert.True(iconStream.Length > 22);
        using var icon = new System.Drawing.Icon(iconStream);
        Assert.True(icon.Width > 0 && icon.Height > 0);
    }

    private sealed class FakeSession : IHeadphonesSession
    {
        public long ConnectionVersion { get; private set; }
        public SessionState State { get; private set; }
        public event Action<SessionState>? StateChanged;
        public event Action<DeviceEvent>? DeviceUpdated;
        public event Action<DeviceCapabilities>? CapabilitiesResolved;
        internal List<NcAmbMode> ModeSends { get; } = [];
        internal void Connect()
        {
            ConnectionVersion++;
            State = SessionState.Connecting; StateChanged?.Invoke(State);
            CapabilitiesResolved?.Invoke(new DeviceCapabilities(NcAmbVariant.DualSeamless, true,
                [BatteryKind.Single], true, true, "Mock headphones"));
            State = SessionState.Ready; StateChanged?.Invoke(State);
        }
        internal void Drop()
        {
            ConnectionVersion++;
            State = SessionState.Disconnected;
            StateChanged?.Invoke(State);
        }
        internal void Emit(DeviceEvent evt) => DeviceUpdated?.Invoke(evt);
        public Task SetNcAmbAsync(NcAmbMode mode, int ambientLevel, bool focusOnVoice)
        {
            ModeSends.Add(mode);
            return Task.CompletedTask;
        }
        public Task SetEqPresetAsync(EqPreset preset) => Task.CompletedTask;
        public Task SetEqBandsAsync(EqPreset preset, int clearBass, int[] bands) => Task.CompletedTask;
        public Task SetEqBands10Async(EqPreset preset, int[] bands) => Task.CompletedTask;
        public Task PowerOffAsync() => Task.CompletedTask;
        public Task RefreshAsync() => Task.CompletedTask;
    }
}
