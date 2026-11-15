using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Nes2MsxTr.App;

public class Dep : INotifyPropertyChanged
{
    string _detail = "";
    bool? _ok;
    public string Name { get; init; } = "";
    public bool? Ok { get => _ok; set { _ok = value; Raise(); Raise(nameof(Mark)); } }
    public string Detail { get => _detail; set { _detail = value; Raise(); } }
    public string Mark => Ok switch { true => "✔", false => "✘", _ => "…" };
    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise([CallerMemberName] string? n = null) => PropertyChanged?.Invoke(this, new(n));
}

/// <summary>What the converter needs, how to find it and how to install it.</summary>
class Deps
{
    public Dep Project = new() { Name = "nes2msxtr project (tools/nes2msxtr.py)" };
    public Dep Python = new() { Name = "Python 3" };
    public Dep Z80Asm = new() { Name = "z80asm" };
    public Dep OpenMsx = new() { Name = "openMSX" };
    public Dep Roms = new() { Name = "FS-A1GT system ROMs + GFX9000 (openMSX)" };
    public IEnumerable<Dep> All => new[] { Project, Python, Z80Asm, OpenMsx, Roms };

    public string[] PythonCmd = { "python3" };
    public string OpenMsxPath = "openmsx";

    public static string? FindProject(string start)
    {
        for (var d = new DirectoryInfo(start); d != null; d = d.Parent)
            if (File.Exists(Path.Combine(d.FullName, "tools", "nes2msxtr.py"))) return d.FullName;
        return null;
    }

    public async Task CheckAsync(string? root, Action<string> log, CancellationToken ct)
    {
        foreach (var d in All) { d.Ok = null; d.Detail = "checking"; }
        Project.Ok = root != null && File.Exists(Path.Combine(root, "tools", "nes2msxtr.py"));
        Project.Detail = Project.Ok == true ? root! : "choose the project folder (the one with tools/ and runtime/)";

        // python: python3, python, py -3 (Windows launcher)
        Python.Ok = false; Python.Detail = "not found";
        foreach (var cand in new[] { new[] { "python3" }, new[] { "python" }, new[] { "py", "-3" } })
        {
            var exe = Proc.Which(cand[0]);
            if (exe == null) continue;
            var sb = new List<string>();
            var rc = await Proc.RunAsync(exe, cand.Skip(1).Append("--version"), null, sb.Add, ct, null, 15000);
            var v = string.Join(" ", sb).Trim();
            if (rc == 0 && v.StartsWith("Python 3"))
            {
                PythonCmd = new[] { exe }.Concat(cand.Skip(1)).ToArray();
                Python.Ok = true; Python.Detail = $"{v} ({exe})";
                break;
            }
        }

        var z = Proc.Which("z80asm");
        Z80Asm.Ok = z != null; Z80Asm.Detail = z ?? "not found";

        var om = FindOpenMsx();
        OpenMsx.Ok = om != null; OpenMsx.Detail = om ?? "not found";
        if (om != null) OpenMsxPath = om;

        if (om == null) { Roms.Ok = false; Roms.Detail = "needs openMSX first"; return; }
        var tmp = Path.Combine(Path.GetTempPath(), "nes2msxtr-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tmp);
        try
        {
            var tcl = Path.Combine(tmp, "exit.tcl");
            File.WriteAllText(tcl, "exit\n");
            var outp = new List<string>();
            var rc = await Proc.RunAsync(om, new[] { "-machine", "Panasonic_FS-A1GT", "-ext", "gfx9000", "-script", tcl },
                tmp, outp.Add, ct, null, 30000);
            Roms.Ok = rc == 0;
            Roms.Detail = rc == 0 ? "FS-A1GT and GFX9000 start" :
                "copy your own FS-A1GT dumps into the openMSX systemroms folder (copyrighted: not installed)  " +
                string.Join(" ", outp.Take(2));
        }
        finally { try { Directory.Delete(tmp, true); } catch { } }
    }

    static string? FindOpenMsx()
    {
        var e = Environment.GetEnvironmentVariable("OPENMSX");
        if (!string.IsNullOrEmpty(e) && File.Exists(e)) return e;
        var cands = new List<string>();
        if (OperatingSystem.IsMacOS()) cands.Add("/Applications/openMSX.app/Contents/MacOS/openmsx");
        if (OperatingSystem.IsWindows())
            foreach (var pf in new[] { Environment.GetEnvironmentVariable("ProgramFiles"), Environment.GetEnvironmentVariable("ProgramFiles(x86)") })
                if (pf != null) cands.Add(Path.Combine(pf, "openMSX", "openmsx.exe"));
        foreach (var c in cands) if (File.Exists(c)) return c;
        return Proc.Which("openmsx");
    }

    /// <summary>Installs what is missing (and can be installed by a package manager).</summary>
    public async Task InstallAsync(Action<string> log, CancellationToken ct)
    {
        var need = new List<string>();
        if (Python.Ok != true) need.Add("python");
        if (Z80Asm.Ok != true) need.Add("z80asm");
        if (OpenMsx.Ok != true) need.Add("openmsx");
        if (need.Count == 0) { log("nothing to install"); }
        else if (OperatingSystem.IsMacOS() && Proc.Which("brew") is { } brew)
        {
            var pk = need.Select(n => n == "python" ? "python3" : n).ToList();
            log($"brew install {string.Join(' ', pk)}");
            await Proc.RunAsync(brew, new[] { "install" }.Concat(pk), null, log, ct);
        }
        else if (OperatingSystem.IsLinux() && Proc.Which("apt-get") is { } apt)
        {
            var pk = need.Select(n => n == "python" ? "python3" : n).ToList();
            var su = Proc.Which("pkexec") ?? Proc.Which("sudo");
            if (su == null) log("no sudo/pkexec: run  apt-get install " + string.Join(' ', pk));
            else
            {
                log($"{Path.GetFileName(su)} apt-get install -y {string.Join(' ', pk)}");
                var a = su.EndsWith("sudo") ? new[] { "-n", "apt-get", "install", "-y" } : new[] { "apt-get", "install", "-y" };
                await Proc.RunAsync(su, a.Concat(pk), null, log, ct);
            }
        }
        else if (OperatingSystem.IsWindows() && Proc.Which("winget") is { } wg)
        {
            if (need.Contains("python"))
                await Proc.RunAsync(wg, new[] { "install", "-e", "--id", "Python.Python.3.12", "--accept-package-agreements", "--accept-source-agreements" }, null, log, ct);
            if (need.Contains("openmsx"))
                await Proc.RunAsync(wg, new[] { "install", "-e", "--id", "openMSX.openMSX", "--accept-package-agreements", "--accept-source-agreements" }, null, log, ct);
            if (need.Contains("z80asm"))
                log("z80asm has no Windows package: build Bas Wijnen's z80asm (savannah.nongnu.org/projects/z80asm) or run this app inside WSL");
        }
        else log("no supported package manager (Homebrew, apt, winget): install " + string.Join(", ", need) + " by hand");
        if (Roms.Ok != true) log("FS-A1GT system ROMs are copyrighted: copy your own dumps into openMSX's systemroms folder");
    }
}
