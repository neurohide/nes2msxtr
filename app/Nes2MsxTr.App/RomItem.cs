using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;

namespace Nes2MsxTr.App;

public class RomItem : INotifyPropertyChanged
{
    bool _sel;
    string _status = "";
    bool _published;
    public string Path { get; init; } = "";
    public string Name => System.IO.Path.GetFileNameWithoutExtension(Path);
    public string Sha1 { get; init; } = "";
    public string Info { get; init; } = "";
    public bool Supported { get; init; }
    public bool Selected { get => _sel; set { _sel = value; Raise(); } }
    public string Status { get => _status; set { _status = value; Raise(); } }
    public bool Published { get => _published; set { _published = value; Raise(); Raise(nameof(PublishedMark)); } }
    public string PublishedMark => Published ? "published" : "";

    int _crashes;
    /// <summary>crash-N.txt / .omr traces saved in build/&lt;game&gt;/ by a run that stopped</summary>
    public int Crashes { get => _crashes; set { _crashes = value; Raise(); Raise(nameof(FixMark)); } }
    public string FixMark => Crashes > 0 ? $"ready to fix ({Crashes})" : "";

    public void RefreshCrashes(string? root)
    {
        var dir = root == null ? null : System.IO.Path.Combine(root, "build", Name);
        Crashes = dir != null && Directory.Exists(dir)
            ? Directory.EnumerateFiles(dir, "crash-*.txt").Count() : 0;
    }

    /// <summary>File name in published/: "Bubble Bobble (USA).nes" -> bubblebobble.rom</summary>
    public string Slug
    {
        get
        {
            var n = Name; var i = n.IndexOf(" (", StringComparison.Ordinal);
            if (i > 0) n = n[..i];
            var s = new string(n.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
            return (s.Length > 0 ? s : "game") + ".rom";
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    void Raise([CallerMemberName] string? n = null) => PropertyChanged?.Invoke(this, new(n));

    public static RomItem? Load(string path)
    {
        try
        {
            var d = File.ReadAllBytes(path);
            if (d.Length < 16 || d[0] != 'N' || d[1] != 'E' || d[2] != 'S' || d[3] != 0x1A) return null;
            int mapper = (d[6] >> 4) | (d[7] & 0xF0);
            string kind = mapper switch { 0 => "NROM", 1 => "MMC1", 2 => "UxROM", 4 => "MMC3", _ => $"mapper {mapper}" };
            return new RomItem
            {
                Path = path,
                Sha1 = Convert.ToHexString(SHA1.HashData(d)).ToLowerInvariant(),
                Info = $"{kind}, PRG {d[4] * 16}K, CHR {(d[5] == 0 ? "RAM" : d[5] * 8 + "K")}",
                Supported = mapper is 0 or 1 or 2 or 4,
            };
        }
        catch { return null; }
    }
}
