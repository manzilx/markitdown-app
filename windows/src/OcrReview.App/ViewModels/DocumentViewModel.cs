using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using OcrReview.App.Services;
using OcrReview.Core;
using OcrReview.Core.Abstractions;
using OcrReview.Core.Models;
using OcrReview.Core.Services;

namespace OcrReview.App.ViewModels;

public sealed class DocumentViewModel : ObservableObject
{
    private const double RenderWidth = 1700;

    private readonly OcrSettings _settings = OcrSettings.Load();
    private readonly SidecarClient _sidecar;
    private readonly SidecarProcessManager _sidecarManager;
    private readonly PdfRenderService _renderer = new();
    private readonly ISpellChecker _spell = new HunspellSpellChecker();
    private readonly WindowsOcrService _ocr;
    private readonly JobStore _jobStore = new();

    private string _sourcePath = "";
    private bool _isPdf;

    public DocumentViewModel()
    {
        _sidecar = new SidecarClient(_settings.SidecarUrl);
        _sidecarManager = new SidecarProcessManager(_sidecar, () => _settings.ProjectRoot);
        _ocr = new WindowsOcrService(_spell);
        _jobStore.RecentsChanged += () => RunOnUi(() => OnPropertyChanged(nameof(Recents)));
        BuildCommands();
    }

    public OcrSettings Settings => _settings;
    public SidecarClient Sidecar => _sidecar;
    public SidecarProcessManager SidecarManager => _sidecarManager;
    public IReadOnlyList<OcrDocument> Recents => _jobStore.Recents;

    // ---- Observable state ----

    private OcrDocument? _document;
    public OcrDocument? Document { get => _document; private set { if (SetProperty(ref _document, value)) NotifyDocumentDerived(); } }

    public bool HasDocument => _document != null;

    private BitmapSource? _currentPageImage;
    public BitmapSource? CurrentPageImage { get => _currentPageImage; private set => SetProperty(ref _currentPageImage, value); }

    private int _currentPageIndex;
    public int CurrentPageIndex { get => _currentPageIndex; private set { if (SetProperty(ref _currentPageIndex, value)) NotifyPageDerived(); } }

    private bool _isProcessing;
    public bool IsProcessing { get => _isProcessing; private set => SetProperty(ref _isProcessing, value); }

    private double _progress;
    public double Progress { get => _progress; private set => SetProperty(ref _progress, value); }

    private string? _errorMessage;
    public string? ErrorMessage { get => _errorMessage; set => SetProperty(ref _errorMessage, value); }

    private string _pageJumpText = "1";
    public string PageJumpText { get => _pageJumpText; set => SetProperty(ref _pageJumpText, value); }

    private bool _isFindVisible;
    public bool IsFindVisible { get => _isFindVisible; set => SetProperty(ref _isFindVisible, value); }

    private string _findText = "";
    public string FindText { get => _findText; set { if (SetProperty(ref _findText, value)) RefreshFindResults(); } }

    private string _replaceText = "";
    public string ReplaceText { get => _replaceText; set => SetProperty(ref _replaceText, value); }

    private List<FindMatch> _findMatches = new();
    public List<FindMatch> FindMatches { get => _findMatches; private set { SetProperty(ref _findMatches, value); OnPropertyChanged(nameof(FindSummary)); } }

    private int _currentFindMatchIndex;
    public int CurrentFindMatchIndex { get => _currentFindMatchIndex; private set { SetProperty(ref _currentFindMatchIndex, value); OnPropertyChanged(nameof(FindSummary)); } }

    public string FindSummary =>
        string.IsNullOrEmpty(FindText) ? "" :
        FindMatches.Count == 0 ? "No results" : $"{CurrentFindMatchIndex + 1} / {FindMatches.Count}";

    private Guid? _selectedBlockId;
    public Guid? SelectedBlockId { get => _selectedBlockId; private set { if (SetProperty(ref _selectedBlockId, value)) NotifySelectionDerived(); } }

    private bool _showHeatmap;
    public bool ShowHeatmap { get => _showHeatmap; set { if (SetProperty(ref _showHeatmap, value)) BumpOverlay(); } }

    private bool _isCommandPaletteVisible;
    public bool IsCommandPaletteVisible { get => _isCommandPaletteVisible; set => SetProperty(ref _isCommandPaletteVisible, value); }

    private bool _pdfModified;
    public bool PdfModified { get => _pdfModified; private set => SetProperty(ref _pdfModified, value); }

    private double _zoomLevel = 1.0;
    public double ZoomLevel { get => _zoomLevel; private set { if (SetProperty(ref _zoomLevel, value)) OnPropertyChanged(nameof(ZoomPercent)); } }
    public int ZoomPercent => (int)Math.Round(_zoomLevel * 100);

    private int _overlayVersion;
    public int OverlayVersion { get => _overlayVersion; private set => SetProperty(ref _overlayVersion, value); }

    // ---- Derived ----

    public int TotalPages => _renderer.HasDocument ? _renderer.PageCount : (_document?.TotalPageCount ?? 1);
    public OcrPage? CurrentPage => _document?.Page(CurrentPageIndex + 1);
    public IReadOnlyList<OcrBlock> CurrentBlocks => CurrentPage?.Blocks.Where(b => b.BboxNormalized != null).ToList() ?? new List<OcrBlock>();
    public IReadOnlyList<OcrBlock> LowConfidenceBlocks => CurrentPage?.LowConfidenceBlocks.ToList() ?? new List<OcrBlock>();
    public HashSet<Guid> CurrentRedactedBlockIds => new((CurrentPage?.Blocks ?? new()).Where(b => b.IsRedacted).Select(b => b.Id));

    public string EngineShortLabel => EngineCatalog.ShortLabel(_document?.Engine ?? _settings.Engine);
    public bool EngineIsLocal => EngineCatalog.IsLocal(_document?.Engine ?? _settings.Engine);
    public bool HasReviewIssues => (_document?.IssueCount ?? 0) > 0;
    public int IssueCount => _document?.IssueCount ?? 0;
    public string ReviewSummary => (_document?.OcrPageCount ?? 0) == 0 ? "" : (IssueCount == 0 ? "All clear" : $"{IssueCount} to review");
    public HashSet<int> OcrPageNumbers => new((_document?.Pages ?? new()).Select(p => p.PageNumber));
    public HashSet<int> IssuePageNumbers => new((_document?.Pages ?? new()).Where(p => p.LowConfidenceBlocks.Any()).Select(p => p.PageNumber));
    public bool PartialOcr => _document != null && _document.OcrPageCount < TotalPages;

    public bool IsSelectedRegionRedacted =>
        _selectedBlockId is { } id && (CurrentPage?.Blocks.FirstOrDefault(b => b.Id == id)?.IsRedacted ?? false);

    public bool CanRevertSelection =>
        _selectedBlockId is { } id
            ? (CurrentPage?.Blocks.FirstOrDefault(b => b.Id == id)?.HasEdits ?? false)
            : (CurrentPage?.HasEdits ?? false);

    public string EditorModeLabel => _selectedBlockId != null ? "Editing selected region" : "Edit to fix OCR errors";

    public IReadOnlyList<SpellSuggestionRef> ActiveSpellIssues
    {
        get
        {
            var blocks = _selectedBlockId is { } id && CurrentPage?.Blocks.FirstOrDefault(b => b.Id == id) is { } b
                ? new List<OcrBlock> { b }
                : LowConfidenceBlocks.ToList();
            var refs = new List<SpellSuggestionRef>();
            foreach (var block in blocks)
                foreach (var issue in _spell.Issues(block.Text))
                    refs.Add(new SpellSuggestionRef(block.Id, issue));
            return refs;
        }
    }

    /// <summary>Two-way editor binding: edits the selected block or the whole page.</summary>
    public string CurrentText
    {
        get
        {
            if (_selectedBlockId is { } id && CurrentPage?.Blocks.FirstOrDefault(b => b.Id == id) is { } block)
                return block.Text;
            return CurrentPage?.DisplayText ?? "";
        }
        set
        {
            if (_selectedBlockId is { } id) UpdateBlockText(id, value);
            else UpdateCurrentPageText(value);
        }
    }

    public string CurrentPagePlaceholder =>
        CurrentPage != null ? "" : "No OCR for this page yet. Recognize it from the toolbar, or it runs when you open the page.";

    // ---- Commands ----

    public RelayCommand OpenCommand { get; private set; } = null!;
    public RelayCommand CloseCommand { get; private set; } = null!;
    public RelayCommand RecognizePageCommand { get; private set; } = null!;
    public RelayCommand RecognizeAllCommand { get; private set; } = null!;
    public RelayCommand ExportMarkdownCommand { get; private set; } = null!;
    public RelayCommand ExportDocxCommand { get; private set; } = null!;
    public RelayCommand ExportSearchablePdfCommand { get; private set; } = null!;
    public RelayCommand ExportTextCommand { get; private set; } = null!;
    public RelayCommand ExportRtfCommand { get; private set; } = null!;
    public RelayCommand CopyPageCommand { get; private set; } = null!;
    public RelayCommand CopyAllCommand { get; private set; } = null!;
    public RelayCommand ToggleFindCommand { get; private set; } = null!;
    public RelayCommand FindNextCommand { get; private set; } = null!;
    public RelayCommand FindPreviousCommand { get; private set; } = null!;
    public RelayCommand ReplaceCommand { get; private set; } = null!;
    public RelayCommand ReplaceAllCommand { get; private set; } = null!;
    public RelayCommand NextIssueCommand { get; private set; } = null!;
    public RelayCommand PreviousIssueCommand { get; private set; } = null!;
    public RelayCommand ToggleHeatmapCommand { get; private set; } = null!;
    public RelayCommand RevertSelectionCommand { get; private set; } = null!;
    public RelayCommand RevertPageCommand { get; private set; } = null!;
    public RelayCommand ToggleRedactionCommand { get; private set; } = null!;
    public RelayCommand RotateRightCommand { get; private set; } = null!;
    public RelayCommand RotateLeftCommand { get; private set; } = null!;
    public RelayCommand AppendCommand { get; private set; } = null!;
    public RelayCommand CombineCommand { get; private set; } = null!;
    public RelayCommand ExtractCommand { get; private set; } = null!;
    public RelayCommand DeletePageCommand { get; private set; } = null!;
    public RelayCommand NextPageCommand { get; private set; } = null!;
    public RelayCommand PreviousPageCommand { get; private set; } = null!;
    public RelayCommand ZoomInCommand { get; private set; } = null!;
    public RelayCommand ZoomOutCommand { get; private set; } = null!;
    public RelayCommand ZoomFitCommand { get; private set; } = null!;
    public RelayCommand ZoomActualCommand { get; private set; } = null!;
    public RelayCommand ShowPaletteCommand { get; private set; } = null!;
    public RelayCommand JumpToPageCommand { get; private set; } = null!;
    public RelayCommand OpenRecentCommand { get; private set; } = null!;
    public RelayCommand RemoveRecentCommand { get; private set; } = null!;
    public RelayCommand SelectBlockCommand { get; private set; } = null!;
    public RelayCommand ApplySpellFixCommand { get; private set; } = null!;
    public RelayCommand OpenSettingsCommand { get; private set; } = null!;
    public RelayCommand DenoiseCommand { get; private set; } = null!;
    public RelayCommand UndoDenoiseCommand { get; private set; } = null!;

    private void BuildCommands()
    {
        OpenCommand = new RelayCommand(() => _ = OpenDialogAsync());
        CloseCommand = new RelayCommand(CloseDocument, () => HasDocument);
        RecognizePageCommand = new RelayCommand(() => _ = RecognizePageAsync(CurrentPageIndex, force: true), () => _renderer.HasDocument && !IsProcessing);
        RecognizeAllCommand = new RelayCommand(() => _ = RecognizeAllAsync(), () => _renderer.HasDocument && !IsProcessing);
        ExportMarkdownCommand = new RelayCommand(ExportMarkdown, () => HasDocument);
        ExportDocxCommand = new RelayCommand(() => _ = ExportDocxAsync(), () => (Document?.OcrPageCount ?? 0) > 0 && !IsProcessing);
        ExportSearchablePdfCommand = new RelayCommand(() => _ = ExportSearchablePdfAsync(), () => (Document?.OcrPageCount ?? 0) > 0 && !IsProcessing);
        ExportTextCommand = new RelayCommand(ExportText, () => HasDocument);
        ExportRtfCommand = new RelayCommand(ExportRtf, () => HasDocument);
        CopyPageCommand = new RelayCommand(() => SetClipboard(CurrentPage?.ExportText ?? ""), () => HasDocument);
        CopyAllCommand = new RelayCommand(() => SetClipboard(Document is { } d ? ExportService.PlainText(d, TotalPages) : ""), () => HasDocument);
        ToggleFindCommand = new RelayCommand(() => { IsFindVisible = !IsFindVisible; if (IsFindVisible) RefreshFindResults(); }, () => HasDocument);
        FindNextCommand = new RelayCommand(FindNext, () => FindMatches.Count > 0);
        FindPreviousCommand = new RelayCommand(FindPrevious, () => FindMatches.Count > 0);
        ReplaceCommand = new RelayCommand(ReplaceCurrent, () => FindMatches.Count > 0);
        ReplaceAllCommand = new RelayCommand(ReplaceAll, () => FindMatches.Count > 0);
        NextIssueCommand = new RelayCommand(GoToNextIssue, () => HasReviewIssues);
        PreviousIssueCommand = new RelayCommand(GoToPreviousIssue, () => HasReviewIssues);
        ToggleHeatmapCommand = new RelayCommand(() => ShowHeatmap = !ShowHeatmap, () => HasDocument);
        RevertSelectionCommand = new RelayCommand(RevertSelection, () => CanRevertSelection);
        RevertPageCommand = new RelayCommand(RevertPage, () => CurrentPage?.HasEdits ?? false);
        ToggleRedactionCommand = new RelayCommand(ToggleRedaction, () => SelectedBlockId != null);
        RotateRightCommand = new RelayCommand(() => _ = RotateAsync(true), () => _isPdf);
        RotateLeftCommand = new RelayCommand(() => _ = RotateAsync(false), () => _isPdf);
        AppendCommand = new RelayCommand(() => _ = AppendAsync(), () => _isPdf);
        CombineCommand = new RelayCommand(() => _ = CombineAsync());
        ExtractCommand = new RelayCommand(ExtractPages, () => _isPdf);
        DeletePageCommand = new RelayCommand(() => _ = DeletePageAsync(), () => _isPdf && TotalPages > 1);
        NextPageCommand = new RelayCommand(() => GoToPage(CurrentPageIndex + 1), () => CurrentPageIndex < TotalPages - 1);
        PreviousPageCommand = new RelayCommand(() => GoToPage(CurrentPageIndex - 1), () => CurrentPageIndex > 0);
        ZoomInCommand = new RelayCommand(() => ZoomLevel = Math.Min(ZoomLevel * 1.2, 6));
        ZoomOutCommand = new RelayCommand(() => ZoomLevel = Math.Max(ZoomLevel / 1.2, 0.25));
        ZoomFitCommand = new RelayCommand(() => ZoomLevel = 1.0);
        ZoomActualCommand = new RelayCommand(() => ZoomLevel = 1.0);
        ShowPaletteCommand = new RelayCommand(() => IsCommandPaletteVisible = true);
        JumpToPageCommand = new RelayCommand(JumpToPageFromField);
        OpenRecentCommand = new RelayCommand(o => { if (o is OcrDocument d) OpenRecent(d); });
        RemoveRecentCommand = new RelayCommand(o => { if (o is OcrDocument d) { _jobStore.Delete(d.Id); OnPropertyChanged(nameof(Recents)); } });
        SelectBlockCommand = new RelayCommand(o => { if (o is Guid id) SelectBlock(id); });
        ApplySpellFixCommand = new RelayCommand(o => { if (o is SpellFixOption opt) ApplySpellFix(opt.Reference, opt.Suggestion); });
        OpenSettingsCommand = new RelayCommand(OpenSettings);
        DenoiseCommand = new RelayCommand(Denoise, () => CanDenoise);
        UndoDenoiseCommand = new RelayCommand(UndoDenoise, () => CanUndoDenoise);
    }

    // ---- Open / load ----

    public async Task OpenDialogAsync()
    {
        var dialog = new OpenFileDialog { Title = "Open Document", Filter = DocumentLoader.OpenFilter };
        if (dialog.ShowDialog() == true)
            await OpenAsync(dialog.FileName);
    }

    public async Task OpenAsync(string path)
    {
        ErrorMessage = null;
        IsProcessing = true;
        Progress = 0;
        try
        {
            await _renderer.LoadAsync(path);
            _sourcePath = path;
            _isPdf = _renderer.IsPdf;
            PdfModified = false;

            Document = new OcrDocument
            {
                Filename = Path.GetFileName(path),
                SourcePath = path,
                Engine = _settings.Engine,
                TotalPageCount = _renderer.PageCount,
            };
            CurrentPageIndex = 0;
            SelectedBlockId = null;
            ZoomLevel = 1.0;
            SyncPageJump();

            await RenderCurrentPageAsync();
            await RecognizePageAsync(0);
            if (Document != null) _jobStore.Save(Document);
            PrefetchAdjacent(0);
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            Document = null;
        }
        finally
        {
            IsProcessing = false;
        }
    }

    public async void OpenRecent(OcrDocument recent)
    {
        if (!File.Exists(recent.SourcePath))
        {
            ErrorMessage = "The original file could not be found.";
            return;
        }
        await _renderer.LoadAsync(recent.SourcePath);
        _sourcePath = recent.SourcePath;
        _isPdf = _renderer.IsPdf;
        PdfModified = false;
        Document = recent;
        CurrentPageIndex = 0;
        SelectedBlockId = null;
        ZoomLevel = 1.0;
        SyncPageJump();
        await RenderCurrentPageAsync();
    }

    public void CloseDocument()
    {
        _jobStore.Flush();
        Document = null;
        CurrentPageImage = null;
        _sourcePath = "";
        _isPdf = false;
        IsFindVisible = false;
        SelectedBlockId = null;
        PdfModified = false;
    }

    private async Task RenderCurrentPageAsync()
    {
        CurrentPageImage = await _renderer.RenderPageAsync(CurrentPageIndex, RenderWidth);
        BumpOverlay();
    }

    public void GoToPage(int index)
    {
        var clamped = Math.Min(Math.Max(index, 0), Math.Max(TotalPages - 1, 0));
        CurrentPageIndex = clamped;
        SelectedBlockId = null;
        SyncPageJump();
        _ = AfterPageChangeAsync(clamped);
    }

    private async Task AfterPageChangeAsync(int index)
    {
        await RenderCurrentPageAsync();
        if (Document?.Page(index + 1) == null) await RecognizePageAsync(index);
        PrefetchAdjacent(index);
    }

    public void JumpToPageFromField()
    {
        if (int.TryParse(PageJumpText.Trim(), out int number) && number >= 1)
            GoToPage(number - 1);
    }

    private void SyncPageJump() => PageJumpText = (CurrentPageIndex + 1).ToString();

    // ---- OCR ----

    private async Task RecognizePageAsync(int index, bool force = false)
    {
        if (Document is not { } doc) return;
        if (!force && doc.Page(index + 1) != null) return;

        IsProcessing = true;
        try
        {
            var page = await RecognizeSinglePageAsync(index, _settings.Engine);
            var existing = doc.Pages.FindIndex(p => p.PageNumber == page.PageNumber);
            if (existing >= 0) doc.Pages[existing] = page;
            else doc.Pages.Add(page);
            doc.Pages.Sort((a, b) => a.PageNumber.CompareTo(b.PageNumber));
            doc.Engine = _settings.Engine;
            _jobStore.Save(doc);
            if (page.PageNumber == CurrentPageIndex + 1) SelectedBlockId = null;
            NotifyDocumentDerived();
            RefreshFindResults();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
        }
        finally
        {
            IsProcessing = false;
        }
    }

    private async Task<OcrPage> RecognizeSinglePageAsync(int index, string engine)
    {
        if (engine == EngineCatalog.DefaultEngine)
        {
            var bitmap = await _renderer.RenderPageSoftwareBitmapAsync(index)
                ?? throw new InvalidOperationException("Could not render the page for OCR.");
            return await _ocr.RecognizeAsync(bitmap, index + 1);
        }

        // Sidecar engines.
        await EnsureSidecarAsync();
        var png = await _renderer.RenderPagePngAsync(index)
            ?? throw new InvalidOperationException("Could not render the page for OCR.");
        var filename = _isPdf ? $"page-{index + 1}.png" : Path.GetFileName(_sourcePath);
        var markdown = await _sidecar.ConvertAsync(png, filename, engine);
        return new OcrPage { PageNumber = index + 1, OcrText = markdown.Trim() };
    }

    private async Task RecognizeAllAsync()
    {
        if (Document is not { } doc) return;
        if (TotalPages > 50 &&
            MessageBox.Show($"Recognize all {TotalPages} pages? This may take a while.",
                "Recognize All", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK)
            return;

        IsProcessing = true;
        Progress = 0;
        try
        {
            var pages = new List<OcrPage>();
            for (int i = 0; i < TotalPages; i++)
            {
                pages.Add(await RecognizeSinglePageAsync(i, _settings.Engine));
                Progress = (double)(i + 1) / TotalPages;
            }
            doc.Pages = pages;
            doc.Engine = _settings.Engine;
            _jobStore.Save(doc);
            NotifyDocumentDerived();
            RefreshFindResults();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
        }
        finally
        {
            IsProcessing = false;
            Progress = 1;
        }
    }

    private void PrefetchAdjacent(int index)
    {
        if (_settings.Engine != EngineCatalog.DefaultEngine) return;
        int next = index + 1;
        if (next >= TotalPages || Document?.Page(next + 1) != null) return;
        _ = Task.Run(async () =>
        {
            try
            {
                var bitmap = await _renderer.RenderPageSoftwareBitmapAsync(next);
                if (bitmap == null) return;
                var page = await _ocr.RecognizeAsync(bitmap, next + 1);
                RunOnUi(() => MergePrefetched(page));
            }
            catch { /* best effort */ }
        });
    }

    private void MergePrefetched(OcrPage page)
    {
        if (Document is not { } doc || doc.Page(page.PageNumber) != null) return;
        doc.Pages.Add(page);
        doc.Pages.Sort((a, b) => a.PageNumber.CompareTo(b.PageNumber));
        _jobStore.ScheduleSave(doc);
        NotifyDocumentDerived();
    }

    // ---- Editing ----

    private void UpdateCurrentPageText(string text)
    {
        if (Document is not { } doc) return;
        SelectedBlockId = null;
        int pageNumber = CurrentPageIndex + 1;
        var page = doc.Page(pageNumber);
        if (page != null) page.SetDisplayText(text);
        else { doc.Pages.Add(new OcrPage { PageNumber = pageNumber, OcrText = "", EditedText = text }); doc.Pages.Sort((a, b) => a.PageNumber.CompareTo(b.PageNumber)); }
        _jobStore.ScheduleSave(doc);
        RefreshFindResults();
        NotifyEditDerived();
    }

    private void UpdateBlockText(Guid blockId, string text)
    {
        if (CurrentPage is not { } page) return;
        var block = page.Blocks.FirstOrDefault(b => b.Id == blockId);
        if (block == null) return;
        block.Text = text;
        page.SyncEditedTextFromBlocks();
        if (Document is { } doc) _jobStore.ScheduleSave(doc);
        RefreshFindResults();
        NotifyEditDerived();
    }

    public void SelectBlock(Guid? id)
    {
        SelectedBlockId = id;
    }

    private void RevertSelection()
    {
        if (CurrentPage is not { } page) return;
        if (_selectedBlockId is { } id && page.Blocks.FirstOrDefault(b => b.Id == id) is { } block)
        {
            block.RevertToOriginal();
            page.SyncEditedTextFromBlocks();
        }
        else
        {
            page.RevertToOriginal();
        }
        if (Document is { } doc) _jobStore.ScheduleSave(doc);
        RefreshFindResults();
        NotifyTextReplaced();
    }

    private void RevertPage()
    {
        if (CurrentPage is not { } page || !page.HasEdits) return;
        if (MessageBox.Show($"Revert page {CurrentPageIndex + 1} to original OCR? Edits will be discarded.",
            "Revert Page", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        page.RevertToOriginal();
        SelectedBlockId = null;
        if (Document is { } doc) _jobStore.ScheduleSave(doc);
        RefreshFindResults();
        NotifyTextReplaced();
    }

    // ---- Denoise ----

    public bool CanDenoise => (Document?.OcrPageCount ?? 0) > 0 && !IsProcessing;

    private string? _denoiseUndoJson;
    public bool CanUndoDenoise => _denoiseUndoJson != null;

    private void Denoise()
    {
        if (Document is not { } document) return;
        if (document.OcrPageCount == 0)
        {
            ErrorMessage = "Run OCR on at least one page before denoising.";
            return;
        }

        var plan = DenoiseService.MakePlan(document);
        if (plan.RemovedLineCount == 0)
        {
            MessageBox.Show("Denoise found no repeated headers, footers, or page numbers in the OCR'd pages.",
                "Denoise", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var lines = plan.RemovedLineCount;
        var pages = plan.AffectedPageCount;
        var prompt =
            $"Remove {lines} repeated header/footer/page-number line{(lines == 1 ? "" : "s")} " +
            $"across {pages} page{(pages == 1 ? "" : "s")}?\n\n" +
            $"Detected noise: {plan.CandidatePreview}\n\n" +
            "This applies as editable text — use Undo Denoise or page-level Revert to restore the original OCR.";
        if (MessageBox.Show(prompt, "Denoise OCR Text", MessageBoxButton.OKCancel, MessageBoxImage.Question)
            != MessageBoxResult.OK) return;

        // Whole-document snapshot for one-click undo (mirrors the macOS undo).
        _denoiseUndoJson = JsonSerializer.Serialize(document);
        OnPropertyChanged(nameof(CanUndoDenoise));

        var result = DenoiseService.Apply(plan, document, plan.AllCandidateKeys);
        SelectedBlockId = null;
        _jobStore.Save(result.Document);
        RefreshFindResults();
        NotifyTextReplaced();
        ErrorMessage = $"Denoise removed {lines} noisy line{(lines == 1 ? "" : "s")} across {pages} page{(pages == 1 ? "" : "s")}. Use Undo Denoise to restore.";
    }

    private void UndoDenoise()
    {
        if (_denoiseUndoJson is not { } json) return;
        var restored = JsonSerializer.Deserialize<OcrDocument>(json);
        _denoiseUndoJson = null;
        OnPropertyChanged(nameof(CanUndoDenoise));
        if (restored == null || Document?.Id != restored.Id) return;

        Document = restored;
        SelectedBlockId = null;
        _jobStore.Save(restored);
        RefreshFindResults();
        NotifyTextReplaced();
        ErrorMessage = "Denoise undone — original OCR text restored.";
    }

    public void ApplySpellFix(SpellSuggestionRef reference, string replacement)
    {
        if (CurrentPage is not { } page) return;
        var block = page.Blocks.FirstOrDefault(b => b.Id == reference.BlockId);
        if (block == null) return;
        block.Text = _spell.Replace(block.Text, reference.Issue, replacement);
        page.SyncEditedTextFromBlocks();
        SelectedBlockId = reference.BlockId;
        if (Document is { } doc) _jobStore.ScheduleSave(doc);
        RefreshFindResults();
        NotifyTextReplaced();
    }

    private void ToggleRedaction()
    {
        if (_selectedBlockId is not { } id || CurrentPage is not { } page) return;
        var block = page.Blocks.FirstOrDefault(b => b.Id == id);
        if (block == null) return;
        block.IsRedacted = !block.IsRedacted;
        if (Document is { } doc) _jobStore.ScheduleSave(doc);
        RefreshFindResults();
        NotifyEditDerived();
    }

    // ---- Review navigation ----

    private List<(int Page, Guid Block)> IssueRefs()
    {
        var result = new List<(int, Guid)>();
        if (Document is not { } doc) return result;
        foreach (var page in doc.Pages.OrderBy(p => p.PageNumber))
            foreach (var block in page.IssuesInReadingOrder)
                result.Add((page.PageNumber, block.Id));
        return result;
    }

    private void GoToNextIssue()
    {
        var refs = IssueRefs();
        if (refs.Count == 0) return;
        int current = CurrentPageIndex + 1;
        int start;
        int idx = refs.FindIndex(r => r.Page == current && r.Block == _selectedBlockId);
        if (idx >= 0) start = (idx + 1) % refs.Count;
        else { int f = refs.FindIndex(r => r.Page >= current); start = f >= 0 ? f : 0; }
        FocusIssue(refs[start]);
    }

    private void GoToPreviousIssue()
    {
        var refs = IssueRefs();
        if (refs.Count == 0) return;
        int current = CurrentPageIndex + 1;
        int start;
        int idx = refs.FindIndex(r => r.Page == current && r.Block == _selectedBlockId);
        if (idx >= 0) start = (idx - 1 + refs.Count) % refs.Count;
        else { int f = refs.FindLastIndex(r => r.Page <= current); start = f >= 0 ? f : refs.Count - 1; }
        FocusIssue(refs[start]);
    }

    private void FocusIssue((int Page, Guid Block) reference)
    {
        if (reference.Page - 1 != CurrentPageIndex)
        {
            CurrentPageIndex = Math.Min(Math.Max(reference.Page - 1, 0), Math.Max(TotalPages - 1, 0));
            SyncPageJump();
            _ = RenderCurrentPageAsync();
        }
        SelectedBlockId = reference.Block;
    }

    // ---- Find / replace ----

    public void RefreshFindResults()
    {
        if (Document is not { } doc) { FindMatches = new(); CurrentFindMatchIndex = 0; return; }
        FindMatches = FindService.Find(doc, FindText);
        if (FindMatches.Count == 0 || CurrentFindMatchIndex >= FindMatches.Count) CurrentFindMatchIndex = 0;
    }

    private void FindNext()
    {
        if (FindMatches.Count == 0) return;
        CurrentFindMatchIndex = (CurrentFindMatchIndex + 1) % FindMatches.Count;
        GoToPage(FindMatches[CurrentFindMatchIndex].PageNumber - 1);
    }

    private void FindPrevious()
    {
        if (FindMatches.Count == 0) return;
        CurrentFindMatchIndex = (CurrentFindMatchIndex - 1 + FindMatches.Count) % FindMatches.Count;
        GoToPage(FindMatches[CurrentFindMatchIndex].PageNumber - 1);
    }

    private void ReplaceCurrent()
    {
        if (Document is not { } doc || CurrentFindMatchIndex >= FindMatches.Count) return;
        var match = FindMatches[CurrentFindMatchIndex];
        var page = doc.Page(match.PageNumber);
        if (page == null) return;
        page.SetDisplayText(FindService.ReplaceAt(page.DisplayText, match.Start, match.Length, ReplaceText));
        _jobStore.ScheduleSave(doc);
        RefreshFindResults();
        NotifyTextReplaced();
    }

    private void ReplaceAll()
    {
        if (Document is not { } doc || string.IsNullOrWhiteSpace(FindText)) return;
        foreach (var page in doc.Pages)
            page.SetDisplayText(FindService.ReplaceAll(page.DisplayText, FindText, ReplaceText));
        _jobStore.ScheduleSave(doc);
        RefreshFindResults();
        NotifyTextReplaced();
    }

    // ---- Exports ----

    private string FilenameStem()
    {
        var name = Document?.Filename ?? "document";
        return Path.GetFileNameWithoutExtension(name);
    }

    private void ExportMarkdown()
    {
        if (Document is not { } doc) return;
        var path = AskSave($"{FilenameStem()}.md", "Markdown (*.md)|*.md");
        if (path != null) File.WriteAllText(path, ExportService.Markdown(doc, TotalPages));
    }

    private void ExportText()
    {
        if (Document is not { } doc) return;
        var path = AskSave($"{FilenameStem()}.txt", "Text (*.txt)|*.txt");
        if (path != null) File.WriteAllText(path, ExportService.PlainText(doc, TotalPages));
    }

    private void ExportRtf()
    {
        if (Document is not { } doc) return;
        var path = AskSave($"{FilenameStem()}.rtf", "Rich Text (*.rtf)|*.rtf");
        if (path != null) File.WriteAllText(path, ExportService.Rtf(doc, TotalPages));
    }

    private async Task ExportDocxAsync()
    {
        if (Document is not { } doc) return;
        var path = AskSave($"{FilenameStem()}.docx", "Word (*.docx)|*.docx");
        if (path == null) return;
        IsProcessing = true;
        try
        {
            await EnsureSidecarAsync();
            var data = await _sidecar.ExportDocxAsync(doc, FilenameStem());
            await File.WriteAllBytesAsync(path, data);
        }
        catch (Exception ex) { ErrorMessage = ex.Message; }
        finally { IsProcessing = false; }
    }

    private async Task ExportSearchablePdfAsync()
    {
        if (Document is not { } doc) return;
        var path = AskSave($"{FilenameStem()}_searchable.pdf", "PDF (*.pdf)|*.pdf");
        if (path == null) return;
        IsProcessing = true;
        try
        {
            await EnsureSidecarAsync();
            var file = await File.ReadAllBytesAsync(_sourcePath);
            var data = await _sidecar.ExportSearchablePdfAsync(file, Path.GetFileName(_sourcePath), doc);
            await File.WriteAllBytesAsync(path, data);
        }
        catch (Exception ex) { ErrorMessage = ex.Message; }
        finally { IsProcessing = false; }
    }

    // ---- Page tools ----

    private async Task RotateAsync(bool clockwise)
    {
        await ApplyEditAsync(temp => PdfEditService.Rotate(_sourcePath, CurrentPageIndex, clockwise, temp), remap: null);
    }

    private async Task DeletePageAsync()
    {
        if (TotalPages <= 1) return;
        if (MessageBox.Show($"Delete page {CurrentPageIndex + 1}? Its OCR text is removed too.",
            "Delete Page", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        int deleted = CurrentPageIndex + 1;
        await ApplyEditAsync(
            temp => PdfEditService.Delete(_sourcePath, CurrentPageIndex, temp),
            remap: doc => doc.Pages = PageStructureService.RemapAfterDelete(doc.Pages, deleted));
        if (CurrentPageIndex >= TotalPages) CurrentPageIndex = Math.Max(0, TotalPages - 1);
        SyncPageJump();
        await RenderCurrentPageAsync();
    }

    public async void MovePage(int from, int to)
    {
        if (!_isPdf || from == to) return;
        await ApplyEditAsync(
            temp => PdfEditService.Move(_sourcePath, from, to, temp),
            remap: doc => doc.Pages = PageStructureService.RemapAfterMove(doc.Pages, from, to, doc.TotalPageCount));
        await RenderCurrentPageAsync();
    }

    private async Task AppendAsync()
    {
        var dialog = new OpenFileDialog { Title = "Append PDFs", Filter = "PDF (*.pdf)|*.pdf", Multiselect = true };
        if (dialog.ShowDialog() != true || dialog.FileNames.Length == 0) return;
        await ApplyEditAsync(temp => PdfEditService.Append(_sourcePath, dialog.FileNames, temp), remap: null);
    }

    private async Task CombineAsync()
    {
        var dialog = new OpenFileDialog { Title = "Combine PDFs", Filter = "PDF (*.pdf)|*.pdf", Multiselect = true };
        if (dialog.ShowDialog() != true || dialog.FileNames.Length < 2) return;
        var outPath = AskSave("combined.pdf", "PDF (*.pdf)|*.pdf");
        if (outPath == null) return;
        try { PdfEditService.Combine(dialog.FileNames, outPath); await OpenAsync(outPath); }
        catch (Exception ex) { ErrorMessage = ex.Message; }
    }

    private void ExtractPages()
    {
        var input = Views.Prompt.Show(
            "Enter a page range (e.g. 3-10 or 5). The original stays unchanged.",
            "Extract Pages", $"{CurrentPageIndex + 1}-{CurrentPageIndex + 1}");
        if (string.IsNullOrWhiteSpace(input)) return;
        var range = PdfEditService.ParseRange(input, TotalPages);
        if (range == null) { ErrorMessage = "Invalid page range. Use e.g. 3-10 or 5."; return; }
        var outPath = AskSave($"pages_{range.Value.Start}-{range.Value.End}.pdf", "PDF (*.pdf)|*.pdf");
        if (outPath == null) return;
        try { PdfEditService.Extract(_sourcePath, range.Value.Start, range.Value.End, outPath); }
        catch (Exception ex) { ErrorMessage = ex.Message; }
    }

    private async Task ApplyEditAsync(Action<string> edit, Action<OcrDocument>? remap)
    {
        if (Document is not { } doc) return;
        try
        {
            var temp = Path.Combine(Path.GetTempPath(), $"ocrreview-{Guid.NewGuid():N}.pdf");
            edit(temp);
            await _renderer.LoadAsync(temp);
            _sourcePath = temp;
            PdfModified = true;
            remap?.Invoke(doc);
            doc.TotalPageCount = _renderer.PageCount;
            _jobStore.ScheduleSave(doc);
            _thumbsVersion++;
            NotifyDocumentDerived();
            OnPropertyChanged(nameof(ThumbnailsVersion));
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
        }
    }

    private int _thumbsVersion;
    public int ThumbnailsVersion => _thumbsVersion;

    // ---- Rendering helpers for the page view ----

    public Task<BitmapSource?> RenderThumbnailAsync(int index) => _renderer.RenderPageAsync(index, 150);

    // ---- Sidecar ----

    private async Task EnsureSidecarAsync()
    {
        _sidecar.BaseUrl = _settings.SidecarUrl;
        if (await _sidecar.IsAvailableAsync()) return;
        await _sidecarManager.EnsureRunningAsync();
        if (!await _sidecar.IsAvailableAsync())
            throw new SidecarException(
                "Couldn't start the Python helper that this feature needs.\n\n" +
                "Word (.docx) export, searchable-PDF export, and the advanced cloud OCR engines use it. " +
                "Everything else — recognizing text, editing, denoise, and exporting to Markdown, plain text, or RTF — works without it.\n\n" +
                "The helper (ocr-sidecar.exe) ships next to OcrReview.exe. If it won't start, the usual causes are " +
                "antivirus blocking it (allow ocr-sidecar.exe), the file being missing (re-extract the download and keep both files together), " +
                "or port 8001 being in use. You can also point Settings → Python helper at a project checkout.");
    }

    // ---- Settings ----

    private void OpenSettings()
    {
        var window = new Views.SettingsWindow(this) { Owner = Application.Current?.MainWindow };
        window.ShowDialog();
    }

    public void ApplySettings(string engine, string sidecarUrl, string projectRoot)
    {
        _settings.Engine = engine;
        _settings.SidecarUrl = sidecarUrl;
        _settings.ProjectRoot = projectRoot;
        _settings.Save();
        _sidecar.BaseUrl = sidecarUrl;
        OnPropertyChanged(nameof(EngineShortLabel));
        OnPropertyChanged(nameof(EngineIsLocal));
    }

    public async Task<List<SidecarEngineInfo>> FetchEnginesAsync()
    {
        try
        {
            _sidecar.BaseUrl = _settings.SidecarUrl;
            if (!await _sidecar.IsAvailableAsync()) await _sidecarManager.EnsureRunningAsync();
            return await _sidecar.FetchEnginesAsync();
        }
        catch
        {
            return new List<SidecarEngineInfo>();
        }
    }

    // ---- Command palette ----

    public IReadOnlyList<PaletteItem> BuildPaletteItems()
    {
        bool hasDoc = HasDocument;
        bool hasSource = _renderer.HasDocument;
        bool hasOcr = (Document?.OcrPageCount ?? 0) > 0;
        bool hasPdf = _isPdf;
        var items = new List<PaletteItem>();
        void Add(string title, string glyph, string group, string? shortcut, bool enabled, Action action) =>
            items.Add(new PaletteItem { Title = title, Glyph = glyph, Group = group, Shortcut = shortcut, IsEnabled = enabled, Action = action });

        Add("Open Document…", "", "File", "Ctrl+O", true, () => _ = OpenDialogAsync());
        if (hasDoc) Add("Back to Library", "", "File", null, true, CloseDocument);
        Add("Settings…", "", "File", null, true, OpenSettings);
        Add("Recognize This Page", "", "OCR", "Ctrl+R", hasSource && !IsProcessing, () => _ = RecognizePageAsync(CurrentPageIndex, true));
        Add("Recognize All Pages…", "", "OCR", null, hasSource && !IsProcessing, () => _ = RecognizeAllAsync());
        Add("Export Markdown…", "", "Export", "Ctrl+Shift+E", hasDoc, ExportMarkdown);
        Add("Export Word…", "", "Export", "Ctrl+Alt+E", hasOcr, () => _ = ExportDocxAsync());
        Add("Export Searchable PDF…", "", "Export", null, hasOcr, () => _ = ExportSearchablePdfAsync());
        Add("Export Plain Text…", "", "Export", null, hasDoc, ExportText);
        Add("Export Rich Text…", "", "Export", null, hasDoc, ExportRtf);
        Add("Copy Page Text", "", "Export", null, hasDoc, () => SetClipboard(CurrentPage?.ExportText ?? ""));
        Add("Copy All Text", "", "Export", null, hasDoc, () => SetClipboard(Document is { } d ? ExportService.PlainText(d, TotalPages) : ""));
        Add("Find & Replace", "", "Edit", "Ctrl+F", hasDoc, () => { IsFindVisible = true; RefreshFindResults(); });
        Add("Denoise Repeated Headers/Footers…", "", "Edit", "Ctrl+Shift+D", CanDenoise, Denoise);
        if (CanUndoDenoise) Add("Undo Denoise", "", "Edit", null, true, UndoDenoise);
        Add("Next Issue", "", "Review", "Alt+Down", HasReviewIssues, GoToNextIssue);
        Add("Previous Issue", "", "Review", "Alt+Up", HasReviewIssues, GoToPreviousIssue);
        Add(ShowHeatmap ? "Hide Confidence Heatmap" : "Show Confidence Heatmap", "", "Review", "Ctrl+Alt+H", hasDoc, () => ShowHeatmap = !ShowHeatmap);
        Add(IsSelectedRegionRedacted ? "Un-redact Region" : "Redact Region", "", "Review", null, SelectedBlockId != null, ToggleRedaction);
        Add("Revert Page to OCR…", "", "Review", null, hasDoc, RevertPage);
        Add("Rotate Page Right", "", "Pages", null, hasPdf, () => _ = RotateAsync(true));
        Add("Rotate Page Left", "", "Pages", null, hasPdf, () => _ = RotateAsync(false));
        Add("Append PDFs…", "", "Pages", null, hasPdf, () => _ = AppendAsync());
        Add("Combine PDFs…", "", "Pages", null, true, () => _ = CombineAsync());
        Add("Extract Pages…", "", "Pages", null, hasPdf, ExtractPages);
        Add("Delete This Page…", "", "Pages", null, hasPdf && TotalPages > 1, () => _ = DeletePageAsync());
        Add("Zoom In", "", "View", "Ctrl++", hasDoc, () => ZoomInCommand.Execute(null));
        Add("Zoom Out", "", "View", "Ctrl+-", hasDoc, () => ZoomOutCommand.Execute(null));
        Add("Fit to Window", "", "View", "Ctrl+0", hasDoc, () => ZoomFitCommand.Execute(null));
        Add("Next Page", "", "View", null, CurrentPageIndex < TotalPages - 1, () => GoToPage(CurrentPageIndex + 1));
        Add("Previous Page", "", "View", null, CurrentPageIndex > 0, () => GoToPage(CurrentPageIndex - 1));
        return items;
    }

    // ---- Helpers ----

    private static string? AskSave(string suggested, string filter)
    {
        var dialog = new SaveFileDialog { FileName = suggested, Filter = filter };
        return dialog.ShowDialog() == true ? dialog.FileName : null;
    }

    private static void SetClipboard(string text)
    {
        try { if (!string.IsNullOrEmpty(text)) Clipboard.SetText(text); } catch { /* ignore */ }
    }

    public void FlushSaves() => _jobStore.Flush();

    private static void RunOnUi(Action action)
    {
        var app = Application.Current;
        if (app?.Dispatcher != null && !app.Dispatcher.CheckAccess()) app.Dispatcher.Invoke(action);
        else action();
    }

    private void BumpOverlay() => OverlayVersion++;

    private void NotifyDocumentDerived()
    {
        OnPropertyChanged(nameof(HasDocument));
        OnPropertyChanged(nameof(TotalPages));
        OnPropertyChanged(nameof(EngineShortLabel));
        OnPropertyChanged(nameof(EngineIsLocal));
        OnPropertyChanged(nameof(HasReviewIssues));
        OnPropertyChanged(nameof(IssueCount));
        OnPropertyChanged(nameof(ReviewSummary));
        OnPropertyChanged(nameof(OcrPageNumbers));
        OnPropertyChanged(nameof(IssuePageNumbers));
        OnPropertyChanged(nameof(PartialOcr));
        NotifyPageDerived();
    }

    private void NotifyPageDerived()
    {
        OnPropertyChanged(nameof(CurrentPage));
        OnPropertyChanged(nameof(CurrentBlocks));
        OnPropertyChanged(nameof(LowConfidenceBlocks));
        OnPropertyChanged(nameof(CurrentRedactedBlockIds));
        OnPropertyChanged(nameof(CurrentText));
        OnPropertyChanged(nameof(CurrentPagePlaceholder));
        OnPropertyChanged(nameof(ActiveSpellIssues));
        OnPropertyChanged(nameof(CanRevertSelection));
        BumpOverlay();
    }

    private void NotifySelectionDerived()
    {
        OnPropertyChanged(nameof(CurrentText));
        OnPropertyChanged(nameof(EditorModeLabel));
        OnPropertyChanged(nameof(IsSelectedRegionRedacted));
        OnPropertyChanged(nameof(CanRevertSelection));
        OnPropertyChanged(nameof(ActiveSpellIssues));
        BumpOverlay();
    }

    /// <summary>
    /// Notifies derived state after an edit. Deliberately does NOT raise CurrentText,
    /// so edits originating from the editor TextBox don't reset the caret.
    /// Callers that change text programmatically raise CurrentText themselves.
    /// </summary>
    private void NotifyEditDerived()
    {
        OnPropertyChanged(nameof(CurrentBlocks));
        OnPropertyChanged(nameof(CurrentRedactedBlockIds));
        OnPropertyChanged(nameof(LowConfidenceBlocks));
        OnPropertyChanged(nameof(ActiveSpellIssues));
        OnPropertyChanged(nameof(HasReviewIssues));
        OnPropertyChanged(nameof(IssueCount));
        OnPropertyChanged(nameof(ReviewSummary));
        OnPropertyChanged(nameof(IssuePageNumbers));
        OnPropertyChanged(nameof(CanRevertSelection));
        BumpOverlay();
    }

    /// <summary>For programmatic text changes (spell fix, revert, replace) — also refreshes the editor.</summary>
    private void NotifyTextReplaced()
    {
        NotifyEditDerived();
        OnPropertyChanged(nameof(CurrentText));
    }
}

public sealed class SpellSuggestionRef
{
    public Guid BlockId { get; }
    public SpellIssue Issue { get; }
    public string Word => Issue.Word;
    public IReadOnlyList<SpellFixOption> Options { get; }

    public SpellSuggestionRef(Guid blockId, SpellIssue issue)
    {
        BlockId = blockId;
        Issue = issue;
        Options = issue.Suggestions.Select(s => new SpellFixOption(this, s)).ToList();
    }
}

public sealed class SpellFixOption
{
    public SpellSuggestionRef Reference { get; }
    public string Suggestion { get; }

    public SpellFixOption(SpellSuggestionRef reference, string suggestion)
    {
        Reference = reference;
        Suggestion = suggestion;
    }
}
