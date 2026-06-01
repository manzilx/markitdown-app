using System.Text.Json;
using System.Text.Json.Serialization;
using OcrReview.Core.Models;

namespace OcrReview.Core.Services;

/// <summary>
/// Persists OCR jobs and a recents index. High-frequency edits go through
/// <see cref="ScheduleSave"/> which coalesces writes onto a background timer —
/// the document is serialized once on the calling thread (a consistent snapshot)
/// and the disk write is debounced.
/// </summary>
public sealed class JobStore
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private const int DebounceMs = 600;
    private const int MaxRecents = 12;

    private readonly string _dir;
    private readonly string _indexPath;
    private readonly object _gate = new();
    private readonly Dictionary<Guid, string> _pending = new();
    private List<OcrDocument> _recents = new();
    private Timer? _timer;

    /// <summary>Raised after a flush updates recents. May fire on a background thread.</summary>
    public event Action? RecentsChanged;

    public JobStore(string? rootDir = null)
    {
        _dir = rootDir ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "OcrReview", "jobs");
        Directory.CreateDirectory(_dir);
        _indexPath = Path.Combine(_dir, "recents.json");
        LoadRecents();
    }

    public IReadOnlyList<OcrDocument> Recents
    {
        get { lock (_gate) { return _recents.ToList(); } }
    }

    /// <summary>Debounced, coalesced save for frequent edits.</summary>
    public void ScheduleSave(OcrDocument document)
    {
        var json = JsonSerializer.Serialize(document, JsonOpts);
        lock (_gate)
        {
            _pending[document.Id] = json;
            _timer?.Dispose();
            _timer = new Timer(_ => Flush(), null, DebounceMs, Timeout.Infinite);
        }
    }

    /// <summary>Immediate save for infrequent, important changes.</summary>
    public void Save(OcrDocument document)
    {
        var json = JsonSerializer.Serialize(document, JsonOpts);
        lock (_gate) { _pending[document.Id] = json; }
        Flush();
    }

    public void Flush()
    {
        List<KeyValuePair<Guid, string>> items;
        lock (_gate)
        {
            _timer?.Dispose();
            _timer = null;
            if (_pending.Count == 0) return;
            items = _pending.ToList();
            _pending.Clear();
        }

        foreach (var kv in items)
        {
            try { File.WriteAllText(JobPath(kv.Key), kv.Value); }
            catch { /* best effort */ }

            var doc = TryDeserialize(kv.Value);
            if (doc != null) UpsertRecent(doc);
        }
        RecentsChanged?.Invoke();
    }

    public OcrDocument? Load(Guid id)
    {
        try
        {
            var path = JobPath(id);
            return File.Exists(path) ? TryDeserialize(File.ReadAllText(path)) : null;
        }
        catch { return null; }
    }

    public void Delete(Guid id)
    {
        lock (_gate)
        {
            _pending.Remove(id);
            _recents.RemoveAll(d => d.Id == id);
        }
        try { File.Delete(JobPath(id)); } catch { /* ignore */ }
        PersistIndex();
        RecentsChanged?.Invoke();
    }

    private void UpsertRecent(OcrDocument document)
    {
        lock (_gate)
        {
            _recents.RemoveAll(d => d.Id == document.Id);
            _recents.Insert(0, document);
            if (_recents.Count > MaxRecents)
                _recents = _recents.Take(MaxRecents).ToList();
        }
        PersistIndex();
    }

    private void LoadRecents()
    {
        try
        {
            if (!File.Exists(_indexPath)) return;
            var ids = JsonSerializer.Deserialize<List<Guid>>(File.ReadAllText(_indexPath)) ?? new List<Guid>();
            var loaded = ids.Select(Load).Where(d => d != null).Cast<OcrDocument>().ToList();
            lock (_gate) { _recents = loaded; }
        }
        catch { /* ignore */ }
    }

    private void PersistIndex()
    {
        try
        {
            List<Guid> ids;
            lock (_gate) { ids = _recents.Select(d => d.Id).ToList(); }
            File.WriteAllText(_indexPath, JsonSerializer.Serialize(ids));
        }
        catch { /* ignore */ }
    }

    private string JobPath(Guid id) => Path.Combine(_dir, $"{id}.json");

    private static OcrDocument? TryDeserialize(string json)
    {
        try { return JsonSerializer.Deserialize<OcrDocument>(json); }
        catch { return null; }
    }
}
