$ErrorActionPreference = "Stop"

Write-Host "Configurando Transcrevo Facil para transcricao local..."

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
& $pythonExe -m pip install faster-whisper

if (-not (Test-Path ".env")) {
  Copy-Item ".env.example" ".env"
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  Write-Host "Aviso: ffmpeg.exe nao esta no PATH. O faster-whisper usa PyAV e deve funcionar para muitos videos mesmo assim."
}

Write-Host "Pronto. Agora rode: npm install; npm run dev"
