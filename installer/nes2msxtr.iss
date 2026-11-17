; Windows installer (Inno Setup 6). Build it with installer\windows.ps1, which
; stages dist\win-x64 (the app next to the project files) and runs ISCC.
; Installs per user, without admin rights, into a folder the app can write
; (build\, published\, sourcerom\ are created there).

#ifndef Version
  #define Version "1.3"
#endif

[Setup]
AppName=nes2msxtr
AppVersion={#Version}
AppPublisher=neurohide
DefaultDirName={localappdata}\Programs\nes2msxtr
DefaultGroupName=nes2msxtr
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
SetupIconFile=icon.ico
UninstallDisplayIcon={app}\nes2msxtr-app.exe
OutputDir=..\dist
OutputBaseFilename=nes2msxtr-{#Version}-win-x64-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[Files]
Source: "..\dist\win-x64\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Dirs]
Name: "{app}\sourcerom"
Name: "{app}\published"

[Icons]
Name: "{group}\nes2msxtr"; Filename: "{app}\nes2msxtr-app.exe"
Name: "{userdesktop}\nes2msxtr"; Filename: "{app}\nes2msxtr-app.exe"; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked

[Run]
Filename: "{app}\nes2msxtr-app.exe"; Description: "Start nes2msxtr"; Flags: nowait postinstall skipifsilent
