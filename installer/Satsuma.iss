; Inno Setup script for Satsuma.
; Build the app first:
;   dotnet publish src/Satsuma -c Release -r win-x64 --self-contained true -o dist/Satsuma
; then compile this file with ISCC (Inno Setup 6). The installer lands in dist/release.

#define AppName "Satsuma"
#define AppVersion "1.0.2"
#define AppPublisher "swattyy"
#define AppURL "https://github.com/swattyy/satsuma"
#define AppExe "Satsuma.exe"

[Setup]
AppId={{98756352-419F-48C4-A1FB-505BE7DB68FE}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
VersionInfoVersion={#AppVersion}
VersionInfoDescription={#AppName} Setup
; Per-user install into %LOCALAPPDATA%\Programs, so no admin prompt.
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputDir=..\dist\release
OutputBaseFilename=Satsuma-Setup-{#AppVersion}
SetupIconFile=..\src\Satsuma\Assets\Satsuma.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
WizardImageFile=art\wizard-100.bmp,art\wizard-150.bmp,art\wizard-200.bmp,art\wizard-250.bmp
WizardSmallImageFile=art\small-100.bmp,art\small-150.bmp,art\small-200.bmp,art\small-250.bmp
Compression=lzma2/ultra64
SolidCompression=yes
; Close a running copy when updating.
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "..\dist\Satsuma\*"; DestDir: "{app}"; Excludes: "READ ME FIRST.txt"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; The app adds this value itself when "Start Satsuma when I sign in" is on. Remove it on uninstall.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Satsuma"; Flags: uninsdeletevalue dontcreatekey

[Run]
Filename: "{app}\{#AppExe}"; Description: "Open Satsuma"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im {#AppExe}"; Flags: runhidden; RunOnceId: "StopSatsuma"

[UninstallDelete]
; Logs and the practice picture. Settings in %APPDATA%\Satsuma are kept.
Type: filesandordirs; Name: "{localappdata}\Satsuma"
