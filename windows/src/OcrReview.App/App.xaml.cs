using System;
using System.IO;
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
        AppDomain.CurrentDomain.UnhandledException += (_, e) => LogCrash(e.ExceptionObject as Exception, fatal: true);
        TaskScheduler.UnobservedTaskException += (_, e) => { LogCrash(e.Exception, fatal: false); e.SetObserved(); };
    }

    private void OnDispatcherException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        LogCrash(e.Exception, fatal: false);
        MessageBox.Show(
            "OCR Review hit an error:\n\n" + e.Exception.Message +
            "\n\nDetails were written to:\n%LOCALAPPDATA%\\OcrReview\\crash.log",
            "OCR Review", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }

    private static void LogCrash(Exception? ex, bool fatal)
    {
        if (ex == null) return;
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OcrReview");
            Directory.CreateDirectory(dir);
            var stamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            File.AppendAllText(
                Path.Combine(dir, "crash.log"),
                $"=== {stamp} (fatal={fatal}) ===\n{ex}\n\n");
        }
        catch
        {
            // Nothing more we can do.
        }
    }
}
