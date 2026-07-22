$ErrorActionPreference = "Stop"

Write-Host "Configurando TranscrevoFácil para transcricao local..."

$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
  $localPython = Join-Path $env:LOCALAPPDATA "Programs\Python\Python313\python.exe"
  if (Test-Path $localPython) {
    $pythonExe = $localPython
  } else {
    Write-Host "Python nao encontrado. Instale Python 3.10+ em https://www.python.org/downloads/."
    exit 1
  }
} else {
  $pythonExe = $python.Source
}

& $pythonExe -m pip install --upgrade pip
$requirementsLock = Join-Path $PSScriptRoot '..\installer\python-requirements.lock'
& $pythonExe -m pip install --require-hashes -r $requirementsLock
if ($LASTEXITCODE -ne 0) {
  throw 'A instalacao das dependencias Python verificadas falhou.'
}

$nvidiaAdapter = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '(?i)NVIDIA' } |
  Select-Object -First 1
if ($nvidiaAdapter) {
  $cudaRequirementsLock = Join-Path $PSScriptRoot '..\installer\python-requirements-cuda.lock'
  Write-Host 'GPU NVIDIA detectada. Instalando CUDA/cuDNN verificados...'
  & $pythonExe -m pip install --require-hashes -r $cudaRequirementsLock
  if ($LASTEXITCODE -ne 0) {
    Write-Warning 'O pacote NVIDIA nao foi instalado; o aplicativo continuara funcionando pela CPU.'
  }
}

if (-not (Test-Path ".env")) {
  Copy-Item ".env.example" ".env"
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  Write-Host "Aviso: ffmpeg.exe nao esta no PATH. O faster-whisper usa PyAV e deve funcionar para muitos videos mesmo assim."
}

Write-Host "Pronto. Agora rode: pnpm install; pnpm run dev"
