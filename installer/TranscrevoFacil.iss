#define MyAppName "TranscrevoFácil"
#define MyAppVersion "0.2.0"
#define MyAppPublisher "TranscrevoFácil"
#define MyAppExeName "scripts\start-transcrevofacil.ps1"

[Setup]
AppId={{B87A868B-3E75-43BD-B884-25F73AB70BA3}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://github.com/yurimj/TranscrevoFacil
AppSupportURL=https://github.com/yurimj/TranscrevoFacil/issues
DefaultDirName={localappdata}\Programs\TranscrevoFacil
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist-installer
OutputBaseFilename=TranscrevoFacil-Setup-{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
LicenseFile=..\LICENSE
SetupIconFile=..\public\transcrevofacil-logo.ico
UninstallDisplayIcon={app}\public\transcrevofacil-logo.ico
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Criar atalho na Área de Trabalho"; GroupDescription: "Atalhos:"; Flags: unchecked

[Dirs]
Name: "{localappdata}\TranscrevoFacil\data\uploads"
Name: "{localappdata}\TranscrevoFacil\data\transcripts"
Name: "{localappdata}\TranscrevoFacil\logs"

[Files]
Source: "..\server.js"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\package.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\pnpm-lock.yaml"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\.env.example"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\SECURITY.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\premissas.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "dependencies.json"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "python-requirements.lock"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "python-requirements-cuda.lock"; DestDir: "{app}\installer"; Flags: ignoreversion
Source: "..\public\*"; DestDir: "{app}\public"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\scripts\install-runtime.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\start-transcrevofacil.ps1"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\scripts\transcribe_local.py"; DestDir: "{app}\scripts"; Flags: ignoreversion
Source: "..\lib\*"; DestDir: "{app}\lib"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\node_modules\*"; DestDir: "{app}\node_modules"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "assets\*"; DestDir: "{app}\installer-assets"; Flags: ignoreversion recursesubdirs createallsubdirs

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\start-transcrevofacil.ps1"""; Description: "Abrir o TranscrevoFácil"; Flags: postinstall nowait skipifsilent

[Icons]
Name: "{group}\TranscrevoFácil"; Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\scripts\start-transcrevofacil.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\public\transcrevofacil-logo.ico"
Name: "{autodesktop}\TranscrevoFácil"; Filename: "powershell.exe"; Parameters: "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\scripts\start-transcrevofacil.ps1"""; WorkingDir: "{app}"; IconFilename: "{app}\public\transcrevofacil-logo.ico"; Tasks: desktopicon

[UninstallDelete]
; runtime, .env, licenses e logs sao gerados por install-runtime.ps1 depois da copia do Inno,
; entao o desinstalador nao os conhece e precisa remove-los explicitamente. Dados do usuario
; (uploads/transcricoes em {localappdata}\TranscrevoFacil\data) sao preservados de proposito.
Type: filesandordirs; Name: "{app}\runtime"
Type: filesandordirs; Name: "{app}\node_modules"
Type: filesandordirs; Name: "{app}\installer-assets"
Type: filesandordirs; Name: "{app}\licenses"
Type: filesandordirs; Name: "{app}\logs"
Type: files; Name: "{app}\.env"
Type: filesandordirs; Name: "{localappdata}\TranscrevoFacil\logs"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  PowerShellExe: String;
  Parameters: String;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption := 'Preparando runtimes locais do TranscrevoFacil...';
    PowerShellExe := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
    Parameters := '-NoProfile -ExecutionPolicy Bypass -File "' +
      ExpandConstant('{app}\scripts\install-runtime.ps1') + '" -InstallRoot "' +
      ExpandConstant('{app}') + '" -AssetRoot "' +
      ExpandConstant('{app}\installer-assets') + '"';

    ResultCode := -1;
    if (not Exec(PowerShellExe, Parameters, ExpandConstant('{app}'),
      SW_HIDE, ewWaitUntilTerminated, ResultCode)) or (ResultCode <> 0) then
      RaiseException('A preparacao dos runtimes falhou. A instalacao nao foi concluida.' + #13#10#13#10 +
        'Codigo: ' + IntToStr(ResultCode) + #13#10 +
        'O motivo detalhado esta em:' + #13#10 +
        ExpandConstant('{app}\logs\install-runtime.log'));
  end;
end;
