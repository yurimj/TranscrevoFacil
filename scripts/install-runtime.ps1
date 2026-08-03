param(
  [Parameter(Mandatory = $true)][string]$InstallRoot,
  [Parameter(Mandatory = $true)][string]$AssetRoot
)

$ErrorActionPreference = 'Stop'
$LogRoot = Join-Path $InstallRoot 'logs'
$LogPath = Join-Path $LogRoot 'install-runtime.log'
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

# O Inno executa este script com SW_HIDE e so mostra o codigo de saida, entao sem transcricao
# qualquer falha aqui chega ao usuario como "Codigo: 1" sem nenhuma pista do motivo.
try { Start-Transcript -LiteralPath $LogPath -Force | Out-Null } catch { }

trap {
  # Stop-Transcript primeiro: enquanto a transcricao esta ativa ela mantem o arquivo aberto,
  # e o append da mensagem falharia em silencio justamente no caso que precisamos registrar.
  $failure = $_
  try { Stop-Transcript | Out-Null } catch { }
  try {
    [System.IO.File]::AppendAllText(
      $LogPath,
      "$(Get-Date -Format o) FALHA: $($failure.Exception.Message)`r`n",
      [System.Text.UTF8Encoding]::new($false))
  } catch { }
  exit 1
}

$RuntimeRoot = Join-Path $InstallRoot 'runtime'
$PythonRoot = Join-Path $RuntimeRoot 'python'
$NodeRoot = Join-Path $RuntimeRoot 'node'
$WheelRoot = Join-Path $AssetRoot 'python-wheels'
$DependencyFile = Join-Path $InstallRoot 'installer\dependencies.json'
$CudaRequirementsLock = Join-Path $InstallRoot 'installer\python-requirements-cuda.lock'
$Dependencies = Get-Content -Raw -LiteralPath $DependencyFile | ConvertFrom-Json
$PythonArchive = Join-Path $AssetRoot $Dependencies.python.fileName
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

function Test-NvidiaAdapter {
  try {
    return [bool](Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -match '(?i)NVIDIA' } | Select-Object -First 1)
  } catch {
    return $false
  }
}

function Copy-WheelLicenseFiles {
  param([string]$WheelDirectory, [string]$Destination)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  foreach ($wheel in Get-ChildItem -LiteralPath $WheelDirectory -Filter '*.whl') {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($wheel.FullName)
    try {
      foreach ($entry in $zip.Entries) {
        if ($entry.Name -and $entry.FullName -match '(?i)(^|/)(LICENSE[^/]*|COPYING[^/]*|NOTICE[^/]*)$') {
          $safeName = ($entry.FullName -replace '[^A-Za-z0-9._-]', '_')
          $target = Join-Path $Destination "$($wheel.BaseName)-$safeName"
          [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
      }
    } finally {
      $zip.Dispose()
    }
  }
}

Assert-File $PythonArchive 'Runtime portatil do Python'
Assert-File $NodeArchive 'Runtime Node.js'
Assert-File $VcRedist 'Microsoft Visual C++ Runtime'
Assert-File (Join-Path $WheelRoot 'requirements.lock') 'Lock de pacotes Python'
Assert-File $CudaRequirementsLock 'Lock do pacote NVIDIA opcional'
Assert-File $AssetManifest 'Manifesto de integridade'

# O manifesto so prova que os arquivos presentes estao integros; ele nao percebe um componente
# que nunca foi empacotado. A lista declarada cobre essa lacuna antes do trabalho pesado comecar.
if (-not $Dependencies.requiredAssets) {
  throw 'O pacote do instalador nao declara requiredAssets. Baixe novamente o instalador do TranscrevoFacil.'
}
$missingAssets = foreach ($requiredAsset in $Dependencies.requiredAssets) {
  $requiredPath = Join-Path $AssetRoot $requiredAsset
  Assert-ChildPath -Parent $AssetRoot -Child $requiredPath
  if (-not (Test-Path -LiteralPath $requiredPath)) { $requiredAsset }
}
if ($missingAssets) {
  throw ("Este instalador foi gerado incompleto e nao pode preparar o TranscrevoFacil. " +
    "Componentes ausentes: $($missingAssets -join ', '). " +
    "Baixe novamente o instalador; se o erro persistir, relate em https://github.com/yurimj/TranscrevoFacil/issues.")
}

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
  Assert-ChildPath -Parent $RuntimeRoot -Child $PythonRoot
  if (Test-Path -LiteralPath $PythonRoot) { [System.IO.Directory]::Delete($PythonRoot, $true) }
  Expand-Archive -LiteralPath $PythonArchive -DestinationPath $PythonRoot -Force
}
if (-not (Test-Path -LiteralPath $PythonExe)) { throw 'O runtime Python foi extraido, mas python.exe nao foi encontrado.' }

$NodeExe = Join-Path $NodeRoot 'node.exe'
if (-not (Test-Path -LiteralPath $NodeExe)) {
  $nodeTemporary = Join-Path $RuntimeRoot 'node-extract'
  Assert-ChildPath -Parent $RuntimeRoot -Child $nodeTemporary
  Assert-ChildPath -Parent $RuntimeRoot -Child $NodeRoot
  if (Test-Path -LiteralPath $nodeTemporary) { [System.IO.Directory]::Delete($nodeTemporary, $true) }
  if (Test-Path -LiteralPath $NodeRoot) { [System.IO.Directory]::Delete($NodeRoot, $true) }
  Expand-Archive -LiteralPath $NodeArchive -DestinationPath $nodeTemporary -Force
  $nodeSource = Get-ChildItem -LiteralPath $nodeTemporary -Directory | Select-Object -First 1
  if (-not $nodeSource) { throw 'O arquivo do Node.js nao contem o diretorio de runtime esperado.' }
  Move-Item -LiteralPath $nodeSource.FullName -Destination $NodeRoot
  [System.IO.Directory]::Delete($nodeTemporary, $true)
}
if (-not (Test-Path -LiteralPath $NodeExe)) { throw 'O runtime Node.js foi extraido, mas node.exe nao foi encontrado.' }

& $PythonExe -m pip install --no-index --find-links $WheelRoot --require-hashes --upgrade -r (Join-Path $WheelRoot 'requirements.lock')
if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel instalar o Whisper e as dependencias Python locais.' }

& $PythonExe -c 'import ctranslate2, faster_whisper; print(ctranslate2.__version__)'
if ($LASTEXITCODE -ne 0) { throw 'A validacao do faster-whisper/CTranslate2 falhou.' }

$NvidiaDetected = Test-NvidiaAdapter
$CudaPackageStatus = if ($NvidiaDetected) { 'pending' } else { 'not-required' }
$CudaErrorLog = Join-Path $RuntimeRoot 'cuda-install-error.log'
if ($NvidiaDetected) {
  $CudaWheelRoot = Join-Path $RuntimeRoot 'cuda-wheels'
  Assert-ChildPath -Parent $RuntimeRoot -Child $CudaWheelRoot
  if (Test-Path -LiteralPath $CudaWheelRoot) { [System.IO.Directory]::Delete($CudaWheelRoot, $true) }
  New-Item -ItemType Directory -Force -Path $CudaWheelRoot | Out-Null
  try {
    Write-Host 'GPU NVIDIA detectada. Baixando automaticamente CUDA/cuDNN verificados...'
    & $PythonExe -m pip download --disable-pip-version-check --only-binary=:all: --require-hashes `
      --index-url 'https://pypi.org/simple' --dest $CudaWheelRoot -r $CudaRequirementsLock
    if ($LASTEXITCODE -ne 0) { throw "O download do pacote NVIDIA falhou com codigo $LASTEXITCODE." }

    Copy-WheelLicenseFiles -WheelDirectory $CudaWheelRoot -Destination (Join-Path $InstallRoot 'licenses\nvidia')
    & $PythonExe -m pip install --disable-pip-version-check --no-index --find-links $CudaWheelRoot `
      --require-hashes --upgrade -r $CudaRequirementsLock
    if ($LASTEXITCODE -ne 0) { throw "A instalacao do pacote NVIDIA falhou com codigo $LASTEXITCODE." }

    $CudaPackageStatus = 'installed'
    if (Test-Path -LiteralPath $CudaErrorLog) { Remove-Item -LiteralPath $CudaErrorLog -Force }
  } catch {
    $CudaPackageStatus = 'cpu-fallback'
    [System.IO.File]::WriteAllText($CudaErrorLog, $_.Exception.Message, [System.Text.UTF8Encoding]::new($false))
    Write-Warning 'A aceleracao NVIDIA nao foi instalada. O TranscrevoFacil continuara funcionando pela CPU.'
  } finally {
    if (Test-Path -LiteralPath $CudaWheelRoot) { [System.IO.Directory]::Delete($CudaWheelRoot, $true) }
  }
}

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
  'UPLOAD_LIMIT_MB=0',
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
  nvidiaDetected = $NvidiaDetected
  cudaPackageStatus = $CudaPackageStatus
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

Write-Host 'Runtimes do TranscrevoFacil preparados com sucesso.'
try { Stop-Transcript | Out-Null } catch { }
