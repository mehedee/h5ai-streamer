using System.Runtime.InteropServices;
using Avalonia.Controls;
using Avalonia.Threading;
using Myra.App.Services;
using Myra.App.ViewModels;
using Myra.App.Views;
using Myra.Core;

static class LinuxCursorChecks
{
    public static async Task<int> StandaloneAsync(string root, Action<bool, string> check,
        Func<Func<bool>, int, Task> pump)
    {
        if (!OperatingSystem.IsLinux()) throw new InvalidOperationException("The native Linux checks need Linux.");
        var failures = 0;
        var work = Dispatcher.UIThread.InvokeAsync(async () =>
        {
            var services = new AppServices();
            var player = new PlayerViewModel(services);
            var folder = new Uri(new Uri(root), "Tracks/");
            var entry = new DirectoryEntry("Long Clip 2020.mp4", new Uri(folder, "Long%20Clip%202020.mp4"), EntryKind.File);
            var media = new GlobalSearchResult(Guid.NewGuid(), "Fixture", folder, entry, entry.Name, null);
            await RunAsync(player, media, (ok, message) =>
            {
                check(ok, message);
                if (!ok) failures++;
            }, pump);
        });
        while (!work.IsCompleted)
        {
            Dispatcher.UIThread.RunJobs();
            Thread.Sleep(20);
        }
        await work;
        Console.WriteLine(failures == 0 ? "ALL NATIVE LINUX CHECKS PASSED" : $"{failures} NATIVE LINUX CHECK(S) FAILED");
        return failures == 0 ? 0 : 1;
    }

    private static async Task RunAsync(PlayerViewModel player, GlobalSearchResult media,
        Action<bool, string> check, Func<Func<bool>, int, Task> pump)
    {
        var display = XOpenDisplay(IntPtr.Zero);
        if (display == IntPtr.Zero) throw new InvalidOperationException("The native Linux checks need an X11 display.");
        var view = new PlayerView { DataContext = player };
        var host = new Window { Content = view, Width = 1100, Height = 640, Title = "Myra Linux smoke" };
        try
        {
            host.Show();
            host.Position = new Avalonia.PixelPoint(0, 0);
            player.Load(media, new PlaybackSequence(media, [media.Entry], null), resume: false);
            await pump(() => player.State == PlayerState.Playing && player.HasVideoSurface && HasDisplayedVideo(), 10000);
            check(player.State == PlayerState.Playing && player.HasVideoSurface && HasDisplayedVideo(),
                "Linux native X11 video surface displays decoded fixture frames");
            MovePointer(100, 300);
            player.NotifyFullscreenChanged(true);
            await pump(() => !player.ControlsVisible, 4000);
            check(!player.ControlsVisible && !view.FindControl<Grid>("FullscreenChrome")!.IsVisible,
                "Linux fullscreen controls hide while the X11 pointer is still");
            MovePointer(300, 350);
            await pump(() => player.ControlsVisible, 1500);
            check(player.ControlsVisible && view.FindControl<Grid>("FullscreenChrome")!.IsVisible,
                "Linux X11 pointer movement over native video restores fullscreen controls");

        }
        finally
        {
            player.NotifyFullscreenChanged(false);
            player.StopPlayback();
            view.ReleaseVideo();
            player.Close();
            host.Close();
            XCloseDisplay(display);
        }

        void MovePointer(int x, int y)
        {
            XWarpPointer(display, 0, XDefaultRootWindow(display), 0, 0, 0, 0, x, y);
            XFlush(display);
        }

        bool HasDisplayedVideo()
        {
            using var current = player.MediaPlayer.Media;
            return current?.Statistics.DisplayedPictures > 0;
        }
    }

    [DllImport("libX11.so.6")]
    private static extern IntPtr XOpenDisplay(IntPtr name);
    [DllImport("libX11.so.6")]
    private static extern int XCloseDisplay(IntPtr display);
    [DllImport("libX11.so.6")]
    private static extern nuint XDefaultRootWindow(IntPtr display);
    [DllImport("libX11.so.6")]
    private static extern int XWarpPointer(IntPtr display, nuint source, nuint destination,
        int sourceX, int sourceY, uint width, uint height, int x, int y);
    [DllImport("libX11.so.6")]
    private static extern int XFlush(IntPtr display);
}
