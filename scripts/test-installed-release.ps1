param(
  [Parameter(Mandatory = $true)][string]$InstallerPath
)

$ErrorActionPreference = 'Stop'
$InstallerPath = [System.IO.Path]::GetFullPath($InstallerPath)
$InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\TranscrevoFacil'
$DataRoot = Join-Path $env:LOCALAPPDATA 'TranscrevoFacil\data'
$TestPort = 39876
$ServerProcess = $null

if (-not (Test-Path -LiteralPath $InstallerPath)) {
  throw "Instalador nao encontrado: $InstallerPath"
}

$setup = Start-Process -FilePath $InstallerPath `
  -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NODESKTOPICON' `
  -Wait -PassThru -WindowStyle Hidden
if ($setup.ExitCode -ne 0) {
  throw "A instalacao silenciosa falhou com codigo $($setup.ExitCode)."
}

$NodeExe = Join-Path $InstallRoot 'runtime\node\node.exe'
$PythonExe = Join-Path $InstallRoot 'runtime\python\python.exe'
$FfmpegExe = Join-Path $InstallRoot 'runtime\ffmpeg\ffmpeg.exe'
$WhisperCppExe = Join-Path $InstallRoot 'runtime\whisper-vulkan\whisper-cli.exe'
$GgmlModel = Join-Path $InstallRoot 'runtime\models\ggml-small.bin'
$EnvFile = Join-Path $InstallRoot '.env'
foreach ($required in $NodeExe, $PythonExe, $FfmpegExe, $WhisperCppExe, $GgmlModel, $EnvFile) {
  if (-not (Test-Path -LiteralPath $required)) { throw "Arquivo instalado ausente: $required" }
}

foreach ($line in Get-Content -LiteralPath $EnvFile) {
  if (-not $line -or $line.TrimStart().StartsWith('#')) { continue }
  $parts = $line.Split('=', 2)
  if ($parts.Count -eq 2) {
    [Environment]::SetEnvironmentVariable($parts[0], $parts[1], 'Process')
  }
}
$env:HOST = '127.0.0.1'
$env:PORT = [string]$TestPort

& $PythonExe -c 'import ctranslate2, faster_whisper; print(ctranslate2.__version__)'
if ($LASTEXITCODE -ne 0) { throw 'O runtime Python instalado nao importou Whisper/CTranslate2.' }
& $FfmpegExe -hide_banner -version | Select-Object -First 1
if ($LASTEXITCODE -ne 0) { throw 'O FFmpeg instalado nao iniciou.' }
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $WhisperCppExe --help 2>&1 | Out-Null
$whisperCliExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction
if ($whisperCliExit -ne 0) { throw 'O runtime Vulkan instalado (whisper-cli.exe) nao iniciou.' }

$LogRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$stdoutLog = Join-Path $LogRoot 'transcrevofacil-smoke-output.log'
$stderrLog = Join-Path $LogRoot 'transcrevofacil-smoke-error.log'
try {
  $ServerProcess = Start-Process -FilePath $NodeExe -ArgumentList 'server.js' `
    -WorkingDirectory $InstallRoot -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog

  $deadline = (Get-Date).AddSeconds(60)
  $healthy = $false
  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-RestMethod -Uri "http://127.0.0.1:$TestPort/api/health" -TimeoutSec 2
      if ($response.ok -eq $true -and $response.app -eq 'transcrevofacil') {
        $healthy = $true
        break
      }
    } catch {
      Start-Sleep -Milliseconds 750
    }
  }
  if (-not $healthy) {
    $details = if (Test-Path -LiteralPath $stderrLog) { Get-Content -Raw -LiteralPath $stderrLog } else { 'sem log' }
    throw "O servidor instalado nao passou no health check: $details"
  }
} finally {
  if ($ServerProcess -and -not $ServerProcess.HasExited) {
    Stop-Process -Id $ServerProcess.Id -Force
    $ServerProcess.WaitForExit()
  }
}

# Exercita tambem o caminho real do atalho: uma porta ocupada por outro programa,
# abertura com o servidor parado e reutilizacao quando 3000 volta a ficar livre.
$PortBlocker = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 3000)
$LauncherServerId = $null
$Launcher = Join-Path $InstallRoot 'scripts\start-transcrevofacil.ps1'
$PowerShellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Invoke-InstalledLauncher {
  $process = Start-Process -FilePath $PowerShellExe -WindowStyle Hidden -PassThru `
    -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $Launcher + '" -NoBrowser -NonInteractive')
  if (-not $process.WaitForExit(90000)) { throw 'O inicializador instalado excedeu o prazo.' }
  if ($process.ExitCode -ne 0) { throw "O inicializador instalado falhou: $($process.ExitCode)." }
}
try {
  $PortBlocker.Start()
  Invoke-InstalledLauncher
  $stateFile = Join-Path $env:LOCALAPPDATA 'TranscrevoFacil\launcher-state.json'
  $state = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
  $LauncherPort = [int]$state.port
  if ($LauncherPort -eq 3000) { throw 'O inicializador usou a porta de outro programa.' }
  $LauncherServerId = (Get-NetTCPConnection -State Listen -LocalPort $LauncherPort).OwningProcess
  $health = Invoke-RestMethod "http://127.0.0.1:$LauncherPort/api/health" -TimeoutSec 3
  if (-not $health.ok -or $health.app -ne 'transcrevofacil') { throw 'O atalho nao iniciou o aplicativo.' }
  $PortBlocker.Stop()
  Invoke-InstalledLauncher
  $reopened = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
  if ($reopened.port -ne $LauncherPort) { throw 'A reabertura criou outra instancia ao liberar a porta 3000.' }
  $reopenedId = (Get-NetTCPConnection -State Listen -LocalPort $LauncherPort).OwningProcess
  if ($reopenedId -ne $LauncherServerId) { throw 'A reabertura substituiu o servidor ativo.' }
} finally {
  $PortBlocker.Stop()
  if ($LauncherServerId) { Stop-Process -Id $LauncherServerId -Force -ErrorAction SilentlyContinue }
}

New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null
$Sentinel = Join-Path $DataRoot 'uninstall-preserves-user-data.txt'
[System.IO.File]::WriteAllText($Sentinel, 'preservar', [System.Text.UTF8Encoding]::new($false))
$Uninstaller = Join-Path $InstallRoot 'unins000.exe'
if (-not (Test-Path -LiteralPath $Uninstaller)) { throw 'Desinstalador nao encontrado.' }
$uninstall = Start-Process -FilePath $Uninstaller `
  -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' `
  -Wait -PassThru -WindowStyle Hidden
if ($uninstall.ExitCode -ne 0) { throw "A desinstalacao falhou com codigo $($uninstall.ExitCode)." }
if (-not (Test-Path -LiteralPath $Sentinel)) { throw 'A desinstalacao removeu dados do usuario.' }

Write-Host 'Instalacao limpa, health check e preservacao de dados validados.'
