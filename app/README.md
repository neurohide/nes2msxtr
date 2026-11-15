# nes2msxtr app

Cross-platform (.NET 8, Avalonia) front end for the converter.

- Checks python 3, z80asm, openMSX and the FS-A1GT system ROMs; **Install missing** uses Homebrew, apt or winget.
- Lists `sourcerom/*.nes` with SHA-1 and mapper; tick one or many.
- **Discover + convert + publish** runs `tools/discover.py`, then `tools/nes2msxtr.py`, and copies the ROM to `published/<name>.rom`. The log is on the right.

Run: `dotnet run --project app/Nes2MsxTr.App` (from the repo, which it finds by itself; otherwise use Browse).

Single-file builds:

    dotnet publish app/Nes2MsxTr.App -c Release -r osx-arm64 -o dist/app-osx-arm64
    dotnet publish app/Nes2MsxTr.App -c Release -r win-x64   -o dist/app-win-x64
    dotnet publish app/Nes2MsxTr.App -c Release -r linux-x64 -o dist/app-linux-x64

z80asm has no Windows package: use WSL there, or build it by hand.
