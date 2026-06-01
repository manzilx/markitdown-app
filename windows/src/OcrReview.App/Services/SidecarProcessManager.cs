using System.Diagnostics;
using System.IO;
using OcrReview.Core.Services;

namespace OcrReview.App.Services;

/// <summary>Auto-starts the Python MarkItDown sidecar (uv) on Windows for advanced engines and exports.</summary>
public sealed class SidecarProcessManager
{
    private readonly SidecarClient _client;
    private readonly Func<string> _projectRootGetter;
    private Process? _process;
    private bool _attempted;

    public bool IsRunning { get; private set; }
    public string StatusMessage { get; private set; } = "Sidecar not started";

    public SidecarProcessManager(SidecarClient client, Func<string> projectRootGetter)
    {
        _client = client;
        _projectRootGetter = projectRootGetter;
    }

    public async Task EnsureRunningAsync()
    {
        if (await _client.IsAvailableAsync())
        {
            IsRunning = true;
            StatusMessage = $"Sidecar running at {_client.BaseUrl}";
            return;
        }

        if (!_attempted)
        {
            _attempted = true;
            Start();
        }

        for (int i = 0; i < 30; i++)
        {
            await Task.Delay(500);
            if (await _client.IsAvailableAsync())
            {
                IsRunning = true;
                StatusMessage = $"Sidecar started at {_client.BaseUrl}";
                return;
            }
        }

        IsRunning = false;
        StatusMessage = "Could not start sidecar automatically. Check the project path in Settings.";
    }

    public async Task RestartAsync()
    {
        Stop();
        _attempted = false;
        await EnsureRunningAsync();
    }

    private void Start()
    {
        var root = ResolveProjectRoot();
        if (root == null)
        {
            StatusMessage = "MarkItDown project not found. Set the project path in Settings.";
            return;
        }

        var psi = new ProcessStartInfo
        {
            FileName = ResolveUv(),
            Arguments = "run uvicorn markitdown_api.main:app --host 127.0.0.1 --port 8001 --app-dir api",
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        try
        {
            _process = Process.Start(psi);
            StatusMessage = "Starting sidecar…";
        }
        catch (Exception ex)
        {
            StatusMessage = "Failed to launch sidecar: " + ex.Message;
        }
    }

    public void Stop()
    {
        try
        {
            if (_process is { HasExited: false }) _process.Kill(entireProcessTree: true);
        }
        catch { /* ignore */ }
        _process = null;
        IsRunning = false;
    }

    private string? ResolveProjectRoot()
    {
        var configured = _projectRootGetter();
        if (!string.IsNullOrWhiteSpace(configured) && Directory.Exists(Path.Combine(configured, "api", "markitdown_api")))
            return configured;

        var candidates = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "markitdown-app"),
            AppContext.BaseDirectory,
        };
        foreach (var candidate in candidates)
            if (Directory.Exists(Path.Combine(candidate, "api", "markitdown_api")))
                return candidate;
        return null;
    }

    private static string ResolveUv()
    {
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var candidates = new[]
        {
            Path.Combine(profile, ".local", "bin", "uv.exe"),
            Path.Combine(profile, ".cargo", "bin", "uv.exe"),
            @"C:\Program Files\uv\uv.exe",
        };
        foreach (var candidate in candidates)
            if (File.Exists(candidate)) return candidate;
        return "uv"; // fall back to PATH
    }
}
