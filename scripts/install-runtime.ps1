param(
  [Parameter(Mandatory = $true)][string]$InstallRoot,
  [Parameter(Mandatory = $true)][string]$AssetRoot
)

$ErrorActionPreference = 'Stop'
$RuntimeRoot = Join-Path $InstallRoot 'runtime'
$PythonRoot = Join-Path $RuntimeRoot 'python'
$NodeRoot = Join-Path $RuntimeRoot 'node'
$WheelRoot = Join-Path $AssetRoot 'python-wheels'
$DependencyFile = Join-Path $InstallRoot 'installer\dependencies.json'
$Dependencies = Get-Content -Raw -LiteralPath $DependencyFile | ConvertFrom-Json
$PythonInstaller = Join-Path $AssetRoot $Dependencies.python.fileName
$NodeArchive = Join-Path $AssetRoot $Dependencies.node.fileName
$VcRedist = Join-Path $AssetRoot $Dependencies.vcRedist.fileName
$AssetManifest = Join-Path $AssetRoot 'manifest.sha256'

function Assert-File {
  param([string]$Path, [string]$Description)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "$Description nao foi encontrado no instalador: $Path"
  }
}

function Assert-ChildPath {
  param([string]$Parent, [string]$Child)
  $resolvedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
  $resolvedChild = [System.IO.Path]::GetFullPath($Child)
  if (-not $resolvedChild.StartsWith($resolvedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Caminho fora da raiz permitida: $resolvedChild"
  }
}

function Add-UserPath {
  param([string]$Directory)
  if (-not (Test-Path -LiteralPath $Directory)) { return }
  $current = [Environment]::GetEnvironmentVariable('Path', 'User')
  $entries = @($current -split ';' | Where-Object { $_ })
  if ($entries -notcontains $Directory) {
    [Environment]::SetEnvironmentVariable('Path', (($entries + $Directory) -join ';'), 'User')
  }
}

Assert-File $PythonInstaller 'Instalador do Python'
Assert-File $NodeArchive 'Runtime Node.js'
Assert-File $VcRedist 'Microsoft Visual C++ Runtime'
Assert-File (Join-Path $WheelRoot 'requirements.lock') 'Lock de pacotes Python'
Assert-File $AssetManifest 'Manifesto de integridade'

foreach ($line in Get-Content -LiteralPath $AssetManifest) {
  if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { throw "Linha invalida no manifesto de integridade: $line" }
  $expectedHash = $Matches[1]
  $relativePath = $Matches[2]
  $assetPath = Join-Path $AssetRoot $relativePath
  Assert-ChildPath -Parent $AssetRoot -Child $assetPath
  Assert-File $assetPath "Asset $relativePath"
  $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assetPath).Hash.ToLowerInvariant()
  if ($actualHash -ne $expectedHash) { throw "O arquivo $relativePath esta corrompido." }
}

New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null

$VulkanSource = Join-Path $AssetRoot 'whisper-vulkan'
$ModelsSource = Join-Path $AssetRoot 'models'
$FfmpegSource = Join-Path $AssetRoot 'ffmpeg\ffmpeg.exe'
if (-not (Test-Path -LiteralPath (Join-Path $VulkanSource 'whisper-cli.exe'))) { throw 'Runtime Vulkan ausente no instalador.' }
if (-not (Test-Path -LiteralPath (Join-Path $ModelsSource 'ggml-small.bin'))) { throw 'Modelo Vulkan ausente no instalador.' }
if (-not (Test-Path -LiteralPath $FfmpegSource)) { throw 'FFmpeg ausente no instalador.' }
New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeRoot 'whisper-vulkan'), (Join-Path $RuntimeRoot 'models'), (Join-Path $RuntimeRoot 'ffmpeg') | Out-Null
Copy-Item -Path (Join-Path $VulkanSource '*') -Destination (Join-Path $RuntimeRoot 'whisper-vulkan') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $ModelsSource 'ggml-small.bin') -Destination (Join-Path $RuntimeRoot 'models\ggml-small.bin') -Force
$FasterModelTarget = Join-Path $RuntimeRoot 'models\faster-whisper-small'
New-Item -ItemType Directory -Force -Path $FasterModelTarget | Out-Null
Copy-Item -Path (Join-Path $ModelsSource 'faster-whisper-small\*') -Destination $FasterModelTarget -Recurse -Force
Copy-Item -LiteralPath $FfmpegSource -Destination (Join-Path $RuntimeRoot 'ffmpeg\ffmpeg.exe') -Force
if (Test-Path -LiteralPath (Join-Path $AssetRoot 'licenses')) {
  $installedLicenses = Join-Path $InstallRoot 'licenses'
  New-Item -ItemType Directory -Force -Path $installedLicenses | Out-Null
  Copy-Item -Path (Join-Path $AssetRoot 'licenses\*') -Destination $installedLicenses -Recurse -Force
}

$vcProcess = Start-Process -FilePath $VcRedist -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru -WindowStyle Hidden
if ($vcProcess.ExitCode -notin 0, 1638, 3010) {
  throw "A instalacao do Visual C++ Runtime falhou com codigo $($vcProcess.ExitCode)."
}

$PythonExe = Join-Path $PythonRoot 'python.exe'
if (-not (Test-Path -LiteralPath $PythonExe)) {
  $arguments = @(
    '/quiet',
    'InstallAllUsers=0',
    'Include_launcher=0',
    'Include_test=0',
    'Include_pip=1',
    'PrependPath=0',
    "TargetDir=$PythonRoot"
  )
  $pythonProcess = Start-Process -FilePath $PythonInstaller -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
  if (($pythonProcess.ExitCode -notin @(0, 3010)) -or -not (Test-Path -LiteralPath $PythonExe)) {
    throw "A instalacao do Python falhou com codigo $($pythonProcess.ExitCode)."
  }
}

$NodeExe = Join-Path $NodeRoot 'node.exe'
if (-not (Test-Path -LiteralPath $NodeExe)) {
  $nodeTemporary = Join-Path $RuntimeRoot 'node-extract'
  if (Test-Path -LiteralPath $nodeTemporary) { [System.IO.Directory]::Delete($nodeTemporary, $true) }
  Expand-Archive -LiteralPath $NodeArchive -DestinationPath $nodeTemporary -Force
  $nodeSource = Get-ChildItem -LiteralPath $nodeTemporary -Directory | Select-Object -First 1
  Move-Item -LiteralPath $nodeSource.FullName -Destination $NodeRoot
  [System.IO.Directory]::Delete($nodeTemporary, $true)
}
if (-not (Test-Path -LiteralPath $NodeExe)) { throw 'O runtime Node.js foi extraido, mas node.exe nao foi encontrado.' }

& $PythonExe -m pip install --no-index --find-links $WheelRoot --require-hashes --upgrade -r (Join-Path $WheelRoot 'requirements.lock')
if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel instalar o Whisper e os runtimes CUDA locais.' }

& $PythonExe -c 'import ctranslate2, faster_whisper; print(ctranslate2.__version__)'
if ($LASTEXITCODE -ne 0) { throw 'A validacao do faster-whisper/CTranslate2 falhou.' }

$FfmpegDirectory = Join-Path $RuntimeRoot 'ffmpeg'
Add-UserPath (Split-Path $PythonExe)
Add-UserPath (Join-Path $PythonRoot 'Scripts')
Add-UserPath $NodeRoot
Add-UserPath $FfmpegDirectory
Add-UserPath (Join-Path $RuntimeRoot 'whisper-vulkan')

$EnvPath = Join-Path $InstallRoot '.env'
$FfmpegExe = Join-Path $FfmpegDirectory 'ffmpeg.exe'
$WhisperCppExe = Join-Path $RuntimeRoot 'whisper-vulkan\whisper-cli.exe'
$WhisperCppModel = Join-Path $RuntimeRoot 'models\ggml-small.bin'
$FasterWhisperModel = Join-Path $RuntimeRoot 'models\faster-whisper-small'
$configuration = @(
  'PORT=3000',
  'HOST=127.0.0.1',
  "DATA_ROOT=$(Join-Path $env:LOCALAPPDATA 'TranscrevoFacil\data')",
  'UPLOAD_LIMIT_MB=2048',
  "PYTHON_BIN=$PythonExe",
  "FFMPEG_BIN=$FfmpegExe",
  'THUMBNAIL_FRAME_COUNT=80',
  "WHISPER_MODEL=$FasterWhisperModel",
  'WHISPER_DEVICE=cpu',
  'WHISPER_COMPUTE_TYPE=float32',
  'WHISPER_GPU_COMPUTE_TYPE=float32',
  'WHISPER_CPU_THREADS=0',
  'WHISPER_NUM_WORKERS=1',
  "WHISPER_CPP_BIN=$WhisperCppExe",
  "WHISPER_CPP_MODEL=$WhisperCppModel"
)
[System.IO.File]::WriteAllLines($EnvPath, $configuration, [System.Text.UTF8Encoding]::new($false))

$manifest = [ordered]@{
  installedAt = (Get-Date).ToUniversalTime().ToString('o')
  python = (& $PythonExe --version 2>&1 | Out-String).Trim()
  node = (& $NodeExe --version 2>&1 | Out-String).Trim()
  ffmpeg = $FfmpegExe
  whisperCpp = $WhisperCppExe
  fasterWhisperModel = $FasterWhisperModel
  dependenciesReviewedAt = $Dependencies.reviewedAt
}
[System.IO.File]::WriteAllText((Join-Path $RuntimeRoot 'installed.json'), ($manifest | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))

& $NodeExe --version
if ($LASTEXITCODE -ne 0) { throw 'A validacao do Node.js empacotado falhou.' }
& $FfmpegExe -hide_banner -version
if ($LASTEXITCODE -ne 0) { throw 'A validacao do FFmpeg empacotado falhou.' }

Assert-ChildPath -Parent $InstallRoot -Child $AssetRoot
if (Test-Path -LiteralPath $AssetRoot) {
  [System.IO.Directory]::Delete([System.IO.Path]::GetFullPath($AssetRoot), $true)
}
