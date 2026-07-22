$ErrorActionPreference = 'Stop'

$AppRoot = Split-Path -Parent $PSScriptRoot
$RuntimeRoot = Join-Path $AppRoot 'runtime'
$UserDataRoot = Join-Path $env:LOCALAPPDATA 'TranscrevoFacil'
$LogRoot = Join-Path $UserDataRoot 'logs'
$HealthPath = '/api/health'
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

trap {
  $message = "O TranscrevoFacil nao conseguiu iniciar.`n`n$($_.Exception.Message)"
  try {
    [System.IO.File]::AppendAllText((Join-Path $LogRoot 'launcher-error.log'), "$(Get-Date -Format o) $message`r`n")
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show($message, 'TranscrevoFacil - reparo necessario', 'OK', 'Error') | Out-Null
  } catch {
    # Se a interface do Windows falhar, o arquivo de log ainda registra o erro original.
  }
  exit 1
}

function Add-SessionPath {
  param([string]$Directory)
  if ($Directory -and (Test-Path -LiteralPath $Directory)) {
    $entries = $env:PATH -split ';'
    if ($entries -notcontains $Directory) {
      $env:PATH = "$Directory;$env:PATH"
    }
  }
}

function Test-AppHealth {
  param([int]$Port)
  try {
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port$HealthPath" -TimeoutSec 2
    return $health.ok -eq $true -and $health.app -eq 'transcrevofacil'
  } catch {
    return $false
  }
}

function Test-PortFree {
  param([int]$Port)
  $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
  return -not [bool]$listener
}

function Find-AppPort {
  param([int]$PreferredPort)
  if (Test-AppHealth -Port $PreferredPort) {
    return @{ Port = $PreferredPort; Running = $true }
  }
  if (Test-PortFree -Port $PreferredPort) {
    return @{ Port = $PreferredPort; Running = $false }
  }

  foreach ($candidate in 3001..3099) {
    if (Test-AppHealth -Port $candidate) {
      return @{ Port = $candidate; Running = $true }
    }
    if (Test-PortFree -Port $candidate) {
      return @{ Port = $candidate; Running = $false }
    }
  }
  throw 'Nao encontrei uma porta livre entre 3000 e 3099.'
}

$NodeExe = Join-Path $RuntimeRoot 'node\node.exe'
$PythonExe = Join-Path $RuntimeRoot 'python\python.exe'
$FfmpegExe = Join-Path $RuntimeRoot 'ffmpeg\ffmpeg.exe'
$WhisperCppExe = Join-Path $RuntimeRoot 'whisper-vulkan\whisper-cli.exe'
$WhisperCppModel = Join-Path $RuntimeRoot 'models\ggml-small.bin'
$FasterWhisperModel = Join-Path $RuntimeRoot 'models\faster-whisper-small'

if (-not (Test-Path -LiteralPath $NodeExe)) {
  throw 'O runtime Node.js nao foi encontrado. Execute Reparar no instalador do TranscrevoFacil.'
}
if (-not (Test-Path -LiteralPath $PythonExe)) {
  throw 'O runtime Python nao foi encontrado. Execute Reparar no instalador do TranscrevoFacil.'
}
if (-not (Test-Path -LiteralPath $FfmpegExe)) {
  throw 'O FFmpeg nao foi encontrado. Execute Reparar no instalador do TranscrevoFacil.'
}

& $NodeExe --version | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'O runtime Node.js esta corrompido. Execute Reparar no instalador.' }
& $PythonExe -c 'import faster_whisper, ctranslate2' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'O runtime Python/Whisper esta incompleto. Execute Reparar no instalador.' }
& $FfmpegExe -version 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'O FFmpeg esta corrompido. Execute Reparar no instalador.' }

Add-SessionPath -Directory (Split-Path $NodeExe)
Add-SessionPath -Directory (Split-Path $PythonExe)
Add-SessionPath -Directory (Split-Path $FfmpegExe)
if (Test-Path -LiteralPath $WhisperCppExe) { Add-SessionPath -Directory (Split-Path $WhisperCppExe) }

$env:PYTHON_BIN = $PythonExe
$env:FFMPEG_BIN = $FfmpegExe
$env:HOST = '127.0.0.1'
$env:DATA_ROOT = Join-Path $UserDataRoot 'data'
$env:WHISPER_CPP_BIN = $WhisperCppExe
$env:WHISPER_CPP_MODEL = $WhisperCppModel
if (Test-Path -LiteralPath $FasterWhisperModel) { $env:WHISPER_MODEL = $FasterWhisperModel }

$selection = Find-AppPort -PreferredPort 3000
$Port = [int]$selection.Port
$Url = "http://127.0.0.1:$Port"

if (-not $selection.Running) {
  $env:PORT = [string]$Port
  $stdoutLog = Join-Path $LogRoot 'server-output.log'
  $stderrLog = Join-Path $LogRoot 'server-error.log'
  Start-Process -FilePath $NodeExe `
    -ArgumentList 'server.js' `
    -WorkingDirectory $AppRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog

  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline -and -not (Test-AppHealth -Port $Port)) {
    Start-Sleep -Milliseconds 750
  }
  if (-not (Test-AppHealth -Port $Port)) {
    throw "O servidor nao iniciou. Consulte $stderrLog ou execute Reparar no instalador."
  }
}

Start-Process $Url
