using System.Text.Json;

namespace OcrReview.Core.Services;

/// <summary>App settings persisted to a JSON file under %APPDATA%\OcrReview.</summary>
public sealed class OcrSettings
{
    public string Engine { get; set; } = EngineCatalog.DefaultEngine;
    public string SidecarUrl { get; set; } = OcrConstants.DefaultSidecarBaseUrl;
    public string ProjectRoot { get; set; } = "";

    private static string SettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "OcrReview", "settings.json");

    public static OcrSettings Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
                return JsonSerializer.Deserialize<OcrSettings>(File.ReadAllText(SettingsPath)) ?? new OcrSettings();
        }
        catch { /* ignore */ }
        return new OcrSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* ignore */ }
    }
}
