using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace OcrReview.App;

public partial class App : Application
{
    public App()
    {
        // Capture *any* unhandled failure so a crash produces a readable log + dialog
        // instead of the window silently never appearing.
        DispatcherUnhandledException += OnDispatcherException;
        AppDomain.CurrentDomain.UnhandledException += (_, e) => OnFatalException(e.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, e) => { LogCrash(e.Exception, fatal: false); e.SetObserved(); };
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        LogEnvironment();
        base.OnStartup(e);
    }

    private void OnDispatcherException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        LogCrash(e.Exception, fatal: false);

        // If the exception fired before the main window existed (theme/XAML/startup
        // failure), "handling" it would leave an invisible zombie process — the app
        // would look like it never opened. Tell the user and exit cleanly instead.
        bool beforeWindow = MainWindow == null || !MainWindow.IsLoaded;
        ShowErrorDialog(
            beforeWindow
                ? "OCR Review could not start:\n\n" + e.Exception.Message +
                  "\n\nDetails were written to:\n%LOCALAPPDATA%\\OcrReview\\crash.log"
                : "OCR Review hit an error:\n\n" + e.Exception.Message +
                  "\n\nDetails were written to:\n%LOCALAPPDATA%\\OcrReview\\crash.log");
        e.Handled = true;
        if (beforeWindow)
        {
            Shutdown(1);
        }
    }

    private void OnFatalException(Exception? ex)
    {
        LogCrash(ex, fatal: true);
        // Best effort: a fatal CLR state can't always run WPF, so use the raw Win32
        // dialog — it works even when the framework is broken.
        ShowErrorDialog(
            "OCR Review crashed:\n\n" + (ex?.Message ?? "Unknown error") +
            "\n\nDetails were written to:\n%LOCALAPPDATA%\\OcrReview\\crash.log");
    }

    private static void ShowErrorDialog(string message)
    {
        try
        {
            const uint MB_OK = 0x0;
            const uint MB_ICONERROR = 0x10;
            const uint MB_TOPMOST = 0x40000;
            _ = MessageBoxW(IntPtr.Zero, message, "OCR Review", MB_OK | MB_ICONERROR | MB_TOPMOST);
        }
        catch
        {
            // Nothing more we can do.
        }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    private static string LogDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OcrReview");

    /// <summary>One breadcrumb per launch so machine-specific failures are diagnosable.</summary>
    private static void LogEnvironment()
    {
        try
        {
            Directory.CreateDirectory(LogDirectory);
            var stamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            File.AppendAllText(
                Path.Combine(LogDirectory, "crash.log"),
                $"=== {stamp} app.started os={Environment.OSVersion.Version} " +
                $"arch={RuntimeInformation.ProcessArchitecture} " +
                $"runtime={RuntimeInformation.FrameworkDescription} " +
                $"baseDir={AppContext.BaseDirectory} ===\n");
        }
        catch
        {
            // Logging must never block startup.
        }
    }

    private static void LogCrash(Exception? ex, bool fatal)
    {
        if (ex == null) return;
        try
        {
            Directory.CreateDirectory(LogDirectory);
            var stamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            File.AppendAllText(
                Path.Combine(LogDirectory, "crash.log"),
                $"=== {stamp} (fatal={fatal}) ===\n{ex}\n\n");
        }
        catch
        {
            // Nothing more we can do.
        }
    }
}
