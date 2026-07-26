#ifndef AppVersion
  #error AppVersion must be supplied by Build-Installer.ps1.
#endif
#ifndef BuildId
  #define BuildId AppVersion
#endif
#ifndef SourceDir
  #error SourceDir must point to the standalone publish directory.
#endif
#ifndef ProjectRoot
  #error ProjectRoot must point to the DMDClock repository root.
#endif
#ifndef OutputDir
  #error OutputDir must point to the installer staging directory.
#endif
#ifndef OutputBaseFilename
  #error OutputBaseFilename must be supplied by Build-Installer.ps1.
#endif

#define AppGuid "{{D01CC10C-1283-4C72-AD7C-BEA19B81B762}"
#define AppExeName "DmdClock.App.exe"
#define AppScrName "DMDClock.scr"
#define ProjectUrl "https://github.com/DrWize/DMDClock-Windows-x64"
#define SceneSourceUrl "https://github.com/sigmafx/DotClk-Resources/tree/master/Scenes"

[Setup]
AppId={#AppGuid}
AppName=DMDClock
AppVerName=DMDClock {#AppVersion}
AppVersion={#AppVersion}
AppPublisher=Alien Tech
AppPublisherURL={#ProjectUrl}
AppSupportURL={#ProjectUrl}/issues
AppUpdatesURL={#ProjectUrl}/releases
AppComments=Application build {#BuildId}
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany=Alien Tech
VersionInfoDescription=DMDClock Windows x64 installer
VersionInfoProductName=DMDClock
VersionInfoProductVersion={#AppVersion}.0
DefaultDirName={localappdata}\Programs\DMDClock
DefaultGroupName=DMDClock
AllowNoIcons=yes
DisableProgramGroupPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
SetupIconFile={#ProjectRoot}\assets\icons\dmdclock.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern dynamic
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
UsePreviousAppDir=yes
UsePreviousGroup=yes
UsePreviousTasks=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked
Name: "autostart"; Description: "Start DMDClock when I sign in"; GroupDescription: "Startup:"; Flags: unchecked
Name: "activatescreensaver"; Description: "Make DMDClock the active Windows screensaver"; GroupDescription: "Screen saver:"; Flags: unchecked checkedonce

[Files]
Source: "{#SourceDir}\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\{#AppScrName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\build-info.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\SCN-COMPATIBILITY.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\SHA256SUMS.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\i18n\*"; DestDir: "{app}\i18n"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\fonts\*"; DestDir: "{app}\fonts"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\scenes\scene-metadata.json"; DestDir: "{app}\scenes"; Flags: ignoreversion
Source: "{#ProjectRoot}\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\DMDClock"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{group}\Configure DMDClock"; Filename: "{app}\{#AppScrName}"; Parameters: "/c"; WorkingDir: "{app}"
Name: "{group}\Preview DMDClock screen saver"; Filename: "{app}\{#AppScrName}"; Parameters: "/s"; WorkingDir: "{app}"
Name: "{group}\Screen Saver Settings"; Filename: "{sys}\control.exe"; Parameters: "desk.cpl,,1"
Name: "{group}\Get DotClk scenes"; Filename: "{#SceneSourceUrl}"
Name: "{group}\User setup and scene instructions"; Filename: "{app}\docs\USER-SETUP.md"
Name: "{group}\Uninstall DMDClock"; Filename: "{uninstallexe}"
Name: "{autodesktop}\DMDClock"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{userstartup}\DMDClock"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: autostart

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch DMDClock"; Flags: nowait postinstall skipifsilent
Filename: "{sys}\control.exe"; Parameters: "desk.cpl,,1"; Description: "Open Windows Screen Saver Settings"; Tasks: activatescreensaver; Flags: nowait postinstall skipifsilent
Filename: "{#SceneSourceUrl}"; Description: "Open the original DotClk scene download page"; Flags: shellexec postinstall skipifsilent unchecked

[Code]
const
  DesktopKey = 'Control Panel\Desktop';
  InstallerStateKey = 'Software\Alien Tech\DMDClock\Installer';
  ScreenSaverValue = 'SCRNSAVE.EXE';
  ScreenSaverActiveValue = 'ScreenSaveActive';

procedure SavePreviousScreenSaver;
var
  CurrentPath: string;
  CurrentActive: string;
  ValueExists: Boolean;
begin
  if RegValueExists(HKCU, InstallerStateKey, 'PreviousScreenSaverRecorded') then
    exit;

  ValueExists := RegQueryStringValue(HKCU, DesktopKey, ScreenSaverValue, CurrentPath);
  RegWriteDWordValue(HKCU, InstallerStateKey, 'PreviousScreenSaverExists', Ord(ValueExists));
  if ValueExists then
    RegWriteStringValue(HKCU, InstallerStateKey, 'PreviousScreenSaver', CurrentPath);

  ValueExists := RegQueryStringValue(HKCU, DesktopKey, ScreenSaverActiveValue, CurrentActive);
  RegWriteDWordValue(HKCU, InstallerStateKey, 'PreviousScreenSaverActiveExists', Ord(ValueExists));
  if ValueExists then
    RegWriteStringValue(HKCU, InstallerStateKey, 'PreviousScreenSaverActive', CurrentActive);

  RegWriteDWordValue(HKCU, InstallerStateKey, 'PreviousScreenSaverRecorded', 1);
end;

procedure ActivateDmdClockScreenSaver;
begin
  SavePreviousScreenSaver;
  RegWriteStringValue(
    HKCU, DesktopKey, ScreenSaverValue, ExpandConstant('{app}\{#AppScrName}'));
  RegWriteStringValue(HKCU, DesktopKey, ScreenSaverActiveValue, '1');
end;

procedure RestorePreviousScreenSaver;
var
  CurrentPath: string;
  PreviousPath: string;
  PreviousActive: string;
  ValueExists: Cardinal;
begin
  if not RegQueryStringValue(HKCU, DesktopKey, ScreenSaverValue, CurrentPath) then
    CurrentPath := '';

  if CompareText(CurrentPath, ExpandConstant('{app}\{#AppScrName}')) <> 0 then
  begin
    RegDeleteKeyIncludingSubkeys(HKCU, InstallerStateKey);
    exit;
  end;

  if RegQueryDWordValue(
       HKCU, InstallerStateKey, 'PreviousScreenSaverExists', ValueExists) and
     (ValueExists = 1) and
     RegQueryStringValue(
       HKCU, InstallerStateKey, 'PreviousScreenSaver', PreviousPath) then
    RegWriteStringValue(HKCU, DesktopKey, ScreenSaverValue, PreviousPath)
  else
    RegDeleteValue(HKCU, DesktopKey, ScreenSaverValue);

  if RegQueryDWordValue(
       HKCU, InstallerStateKey, 'PreviousScreenSaverActiveExists', ValueExists) and
     (ValueExists = 1) and
     RegQueryStringValue(
       HKCU, InstallerStateKey, 'PreviousScreenSaverActive', PreviousActive) then
    RegWriteStringValue(HKCU, DesktopKey, ScreenSaverActiveValue, PreviousActive)
  else
    RegDeleteValue(HKCU, DesktopKey, ScreenSaverActiveValue);

  RegDeleteKeyIncludingSubkeys(HKCU, InstallerStateKey);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('activatescreensaver') then
    ActivateDmdClockScreenSaver;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RestorePreviousScreenSaver;
end;
