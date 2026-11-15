using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Nes2MsxTr.App;

/// <summary>Runs a process, streaming its stdout/stderr lines.</summary>
static class Proc
{
    public static async Task<int> RunAsync(string file, IEnumerable<string> args, string? dir, Action<string> log,
        CancellationToken ct, IDictionary<string, string>? env = null, int timeoutMs = 0)
    {
        var psi = new ProcessStartInfo(file)
        {
            WorkingDirectory = dir ?? Environment.CurrentDirectory,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            UseShellExecute = false, CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["PYTHONUNBUFFERED"] = "1";
        if (env != null) foreach (var (k, v) in env) psi.Environment[k] = v;
        using var p = new Process { StartInfo = psi };
        p.OutputDataReceived += (_, e) => { if (e.Data != null) log(e.Data); };
        p.ErrorDataReceived += (_, e) => { if (e.Data != null) log(e.Data); };
        try { p.Start(); }
        catch (Exception ex) { log($"cannot start {file}: {ex.Message}"); return -1; }
        p.StandardInput.Close();
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        if (timeoutMs > 0) cts.CancelAfter(timeoutMs);
        try { await p.WaitForExitAsync(cts.Token); }
        catch (OperationCanceledException)
        {
            try { p.Kill(true); } catch { }
            await p.WaitForExitAsync();
            if (ct.IsCancellationRequested) throw;
            log($"timed out: {file}");
            return -2;
        }
        p.WaitForExit();                    // flush the async readers
        return p.ExitCode;
    }

    public static string? Which(string cmd)
    {
        var exts = OperatingSystem.IsWindows() ? new[] { ".exe", ".cmd", ".bat", "" } : new[] { "" };
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            foreach (var e in exts)
            {
                var f = Path.Combine(dir.Trim('"'), cmd + e);
                if (File.Exists(f)) return f;
            }
        return null;
    }

    public static bool IsWindows => RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
}
