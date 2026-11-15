using System.Collections.ObjectModel;
using System.Text;
using Avalonia.Controls;
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace Nes2MsxTr.App;

public partial class MainWindow : Window
{
    readonly Deps _deps = new();
    readonly ObservableCollection<RomItem> _roms = new();
    readonly StringBuilder _log = new();
    readonly DispatcherTimer _flush = new() { Interval = TimeSpan.FromMilliseconds(120) };
    readonly object _logLock = new();
    bool _logDirty, _logArmed = true, _openRequest;
    GridLength _logWidth = new(1, GridUnitType.Star);
    CancellationTokenSource? _cts;

    public MainWindow()
    {
        InitializeComponent();
        DepList.ItemsSource = _deps.All.ToList();
        RomList.ItemsSource = _roms;
        _flush.Tick += (_, _) => FlushLog();
        // a closed games panel gives its space back
        GamesPanel.PropertyChanged += (_, e) =>
        {
            if (e.Property == SlidePanel.IsOpenProperty)
                LeftGrid.RowDefinitions[1].Height = GamesPanel.IsOpen ? new GridLength(1, GridUnitType.Star) : GridLength.Auto;
        };
        LogToggle.Click += (_, _) => SetLog(!LogPanel.IsVisible);
        _flush.Start();

        var root = Deps.FindProject(AppContext.BaseDirectory) ?? Deps.FindProject(Environment.CurrentDirectory);
        RootBox.Text = root ?? "";
        RomsBox.Text = root != null ? Path.Combine(root, "sourcerom") : "";
        DestBox.Text = root != null ? Path.Combine(root, "published") : "";

        RootBtn.Click += async (_, _) => { if (await PickFolder() is { } f) { RootBox.Text = f; RomsBox.Text = Path.Combine(f, "sourcerom"); DestBox.Text = Path.Combine(f, "published"); await RecheckAsync(); LoadRoms(); } };
        RomsBtn.Click += async (_, _) => { if (await PickFolder() is { } f) { RomsBox.Text = f; LoadRoms(); } };
        RootBox.LostFocus += async (_, _) => { await RecheckAsync(); LoadRoms(); };
        RomsBox.LostFocus += (_, _) => LoadRoms();
        DestBtn.Click += async (_, _) => { if (await PickFolder() is { } f) { DestBox.Text = f; LoadRoms(); } };
        DestBox.LostFocus += (_, _) => LoadRoms();
        CheckBtn.Click += async (_, _) => await RecheckAsync();
        InstallBtn.Click += async (_, _) => await InstallAsync();
        AllBtn.Click += (_, _) => { foreach (var r in _roms) r.Selected = r.Supported; };
        NoneBtn.Click += (_, _) => { foreach (var r in _roms) r.Selected = false; };
        RefreshBtn.Click += (_, _) => LoadRoms();
        ClearBtn.Click += (_, _) => { lock (_logLock) { _log.Clear(); _logDirty = true; } };
        CancelBtn.Click += (_, _) => _cts?.Cancel();
        RunBtn.Click += async (_, _) => await ConvertAsync();
        Opened += async (_, _) => { await RecheckAsync(); LoadRoms(); };
    }

    // ----- log -----
    void Log(string s)
    {
        lock (_logLock)
        {
            _log.Append(s).Append('\n');
            if (_logArmed) { _logArmed = false; _openRequest = true; }   // the next action may open it again
            if (_log.Length > 600_000) _log.Remove(0, _log.Length - 400_000);
            _logDirty = true;
        }
    }

    void SetLog(bool open)
    {
        if (open == LogPanel.IsVisible) return;
        if (!open) _logWidth = BodyGrid.ColumnDefinitions[2].Width;
        BodyGrid.ColumnDefinitions[2].Width = open ? _logWidth : new GridLength(0);
        LogPanel.IsVisible = LogSplit.IsVisible = open;
        ExpandIcon.IsVisible = !open;
        CollapseIcon.IsVisible = open;
        _logArmed = false;
    }

    void FlushLog()
    {
        if (_openRequest) { _openRequest = false; SetLog(true); }
        string text;
        lock (_logLock) { if (!_logDirty) return; _logDirty = false; text = _log.ToString(); }
        LogText.Text = text;
        if (FollowChk.IsChecked == true) Dispatcher.UIThread.Post(() => LogScroll.ScrollToEnd(), DispatcherPriority.Background);
    }

    void Ui(Action a) => Dispatcher.UIThread.Post(a);

    async Task<string?> PickFolder()
    {
        var r = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { AllowMultiple = false });
        return r.Count > 0 ? r[0].TryGetLocalPath() : null;
    }

    string? Root => Directory.Exists(RootBox.Text) && File.Exists(Path.Combine(RootBox.Text!, "tools", "nes2msxtr.py")) ? RootBox.Text : null;

    // ----- dependencies -----
    async Task RecheckAsync()
    {
        _logArmed = true;
        CheckBtn.IsEnabled = InstallBtn.IsEnabled = false;
        try { await _deps.CheckAsync(Root, Log, CancellationToken.None); }
        finally { CheckBtn.IsEnabled = InstallBtn.IsEnabled = true; }
        RunBtn.IsEnabled = _deps.Project.Ok == true && _deps.Python.Ok == true && _deps.Z80Asm.Ok == true
                           && _deps.OpenMsx.Ok == true && _deps.Roms.Ok == true;
    }

    async Task InstallAsync()
    {
        _logArmed = true;
        CheckBtn.IsEnabled = InstallBtn.IsEnabled = false;
        try { await _deps.InstallAsync(Log, CancellationToken.None); }
        finally { CheckBtn.IsEnabled = InstallBtn.IsEnabled = true; }
        await RecheckAsync();
    }

    // ----- games -----
    void LoadRoms()
    {
        _roms.Clear();
        var dir = RomsBox.Text;
        if (string.IsNullOrWhiteSpace(dir) || !Directory.Exists(dir)) return;
        var root = Root;
        var pub = string.IsNullOrWhiteSpace(DestBox.Text) ? null : DestBox.Text;
        var files = Directory.EnumerateFiles(dir, "*.nes").OrderBy(f => f, StringComparer.OrdinalIgnoreCase).ToList();
        Task.Run(() =>
        {
            foreach (var f in files)
            {
                var r = RomItem.Load(f);
                if (r == null) continue;
                r.Published = pub != null && File.Exists(Path.Combine(pub, r.Slug));
                r.RefreshCrashes(root);
                if (!r.Supported) r.Status = "unsupported";
                Ui(() => _roms.Add(r));
            }
        });
    }

    // ----- conversion -----
    async Task ConvertAsync()
    {
        var root = Root;
        if (root == null) return;
        var dest = string.IsNullOrWhiteSpace(DestBox.Text) ? Path.Combine(root, "published") : DestBox.Text!;
        var todo = _roms.Where(r => r.Selected && r.Supported).ToList();
        if (todo.Count == 0) { Log("select at least one ROM"); return; }
        _logArmed = true;
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;
        RunBtn.IsEnabled = false; CancelBtn.IsEnabled = true; Progress.Value = 0;
        foreach (var r in todo) r.Status = "queued";
        int done = 0, failed = 0;
        try
        {
            foreach (var r in todo)
            {
                Log($"==== {r.Name}  sha1 {r.Sha1}");
                var ok = await ConvertOneAsync(root, dest, r, ct);
                r.Status = ok ? "done" : "failed";
                r.RefreshCrashes(root);
                if (!ok) failed++;
                Progress.Value = (double)++done / todo.Count;
            }
            Log($"==== finished: {todo.Count - failed} published, {failed} failed");
        }
        catch (OperationCanceledException) { Log("==== cancelled"); foreach (var r in todo.Where(r => r.Status is "queued" or "discover" or "build")) r.Status = "cancelled"; }
        finally { CancelBtn.IsEnabled = false; RunBtn.IsEnabled = true; _cts = null; }
    }

    async Task<bool> ConvertOneAsync(string root, string destDir, RomItem r, CancellationToken ct)
    {
        var outDir = Path.Combine(root, "build", r.Name);
        Directory.CreateDirectory(outDir);
        var entries = Path.Combine(outDir, $"entries.{r.Sha1}.txt");
        if (!File.Exists(entries))
        {
            var sample = new[] { Path.Combine(root, "samples", $"entries.{r.Sha1}.txt"), Path.Combine(root, "samples", $"{r.Name}.entries.txt") }
                .FirstOrDefault(File.Exists);
            if (sample != null) { File.Copy(sample, entries); Log($"using {Path.GetRelativePath(root, sample)} (jump targets found by playing)"); }
        }

        var py = _deps.PythonCmd;
        Task<int> Py(IEnumerable<string> a, IDictionary<string, string>? env = null) =>
            Proc.RunAsync(py[0], py.Skip(1).Concat(a), root, Log, ct, env);

        if (DiscoverChk.IsChecked == true)
        {
            Ui(() => r.Status = "discover");
            var env = new Dictionary<string, string>
            {
                ["DISCOVER_PLAY"] = PlayBox.SelectedIndex == 0 ? "1" : "2",
                ["OPENMSX"] = _deps.OpenMsxPath,
            };
            var rc = await Py(new[] { Path.Combine("tools", "discover.py"), r.Path, outDir,
                ((int)(SecsNum.Value ?? 100)).ToString(), ((int)(RoundsNum.Value ?? 14)).ToString() }, env);
            if (rc != 0) Log($"discover exited with {rc} (continuing with the entries found so far)");
        }

        Ui(() => r.Status = "build");
        var rc2 = await Py(new[] { Path.Combine("tools", "nes2msxtr.py"), r.Path, outDir });
        var built = Path.Combine(outDir, r.Name + ".rom");
        if (rc2 != 0 || !File.Exists(built)) { Log($"conversion failed (exit {rc2})"); return false; }

        Directory.CreateDirectory(destDir);
        var target = Path.Combine(destDir, r.Slug);
        File.Copy(built, target, true);
        Log($"published {target}");
        Ui(() => r.Published = true);
        if (CleanChk.IsChecked == true) CleanTraces(root, outDir);
        return true;
    }

    /// <summary>Crash traces (crash-N.*) and openMSX run dumps left in the build folder.</summary>
    static readonly string[] DumpFiles =
    {
        "cpu.txt", "omsx.log", "screen.png", "video.txt", "msx_ram.bin", "msx_vars.bin", "mapper_ram.bin",
        "psg_regs.bin", "v9990_pal.bin", "v9990_regs.bin", "v9990_vram.bin",
    };

    void CleanTraces(string root, string outDir)
    {
        int n = 0;
        try
        {
            foreach (var f in Directory.EnumerateFiles(outDir, "crash-*")) { File.Delete(f); n++; }
            foreach (var name in DumpFiles)
            {
                var f = Path.Combine(outDir, name);
                if (File.Exists(f)) { File.Delete(f); n++; }
            }
            foreach (var d in Directory.EnumerateDirectories(outDir, ".discover*")) { Directory.Delete(d, true); n++; }
        }
        catch (Exception ex) { Log($"cleanup: {ex.Message}"); }
        Log($"cleaned {n} trace/dump items in {Path.GetRelativePath(root, outDir)}");
    }
}
