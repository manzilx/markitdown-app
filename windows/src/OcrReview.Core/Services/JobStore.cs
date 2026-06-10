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
    /// <summary>Serializes disk writes so a timer-thread flush and a UI-thread flush
    /// can't interleave writes to the same job file (last-finisher-wins corruption).</summary>
    private readonly object _ioGate = new();
    private readonly Dictionary<Guid, string> _pending = new();
    private List<OcrDocument> _recents = new();
    private Timer? _timer;
    private DateTime _oldestPendingUtc;
    /// <summary>Continuous typing re-arms the debounce forever; cap how long an edit
    /// can sit unsaved so a crash mid-session loses at most this much work.</summary>
    private static readonly TimeSpan MaxPendingAge = TimeSpan.FromSeconds(3);

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
        bool flushNow;
        lock (_gate)
        {
            if (_pending.Count == 0) _oldestPendingUtc = DateTime.UtcNow;
            _pending[document.Id] = json;
            flushNow = DateTime.UtcNow - _oldestPendingUtc >= MaxPendingAge;
            if (!flushNow)
            {
                _timer?.Dispose();
                _timer = new Timer(_ => Flush(), null, DebounceMs, Timeout.Infinite);
            }
        }
        if (flushNow) Flush();
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

        lock (_ioGate)
        {
            foreach (var kv in items)
            {
                // Atomic write: a crash or power loss mid-write must not leave a
                // truncated job file (which deserializes to null and silently drops
                // the document with all its OCR and edits).
                try
                {
                    var path = JobPath(kv.Key);
                    var temp = path + ".tmp";
                    File.WriteAllText(temp, kv.Value);
                    File.Move(temp, path, overwrite: true);
                }
                catch { /* best effort */ }

                var doc = TryDeserialize(kv.Value);
                if (doc != null) UpsertRecent(doc);
            }
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
