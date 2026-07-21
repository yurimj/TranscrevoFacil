param(
  [string]$PythonCommand = 'python',
  [string]$WhisperCppSource = '',
  [switch]$SkipDownloads
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $PSScriptRoot
$AssetRoot = Join-Path $AppRoot 'installer\assets'
$WheelRoot = Join-Path $AssetRoot 'python-wheels'
$ModelRoot = Join-Path $AssetRoot 'models'
$VulkanRoot = Join-Path $AssetRoot 'whisper-vulkan'
$FfmpegRoot = Join-Path $AssetRoot 'ffmpeg'
$LicenseRoot = Join-Path $AssetRoot 'licenses'
$BuildRoot = Join-Path $AppRoot '.installer-build'
$DependencyFile = Join-Path $AppRoot 'installer\dependencies.json'
$RequirementsLock = Join-Path $AppRoot 'installer\python-requirements.lock'
$CudaRequirementsLock = Join-Path $AppRoot 'installer\python-requirements-cuda.lock'
$Dependencies = Get-Content -Raw -LiteralPath $DependencyFile | ConvertFrom-Json

function Assert-ChildPath {
  param([string]$Parent, [string]$Child)
  $resolvedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
  $resolvedChild = [System.IO.Path]::GetFullPath($Child)
  if (-not $resolvedChild.StartsWith($resolvedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Caminho fora da raiz permitida: $resolvedChild"
  }
}

function Reset-Directory {
  param([string]$Parent, [string]$Path)
  Assert-ChildPath -Parent $Parent -Child $Path
  if (Test-Path -LiteralPath $Path) {
    [System.IO.Directory]::Delete([System.IO.Path]::GetFullPath($Path), $true)
  }
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Assert-FileHash {
  param([string]$Path, [string]$ExpectedSha256)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Arquivo nao encontrado: $Path" }
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
    throw "Hash invalido para $Path. Esperado $ExpectedSha256; recebido $actual."
  }
}

function Get-VerifiedDownload {
  param([string]$Uri, [string]$Destination, [string]$ExpectedSha256)
  if (Test-Path -LiteralPath $Destination) {
    $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
    if ($existingHash -eq $ExpectedSha256.ToLowerInvariant()) { return }
    Remove-Item -LiteralPath $Destination -Force
  }

  Write-Host "Baixando $Uri"
  $partial = "$Destination.download"
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($curl) {
    & $curl.Source --location --fail --retry 3 --retry-delay 2 --continue-at - --output $partial $Uri
    if ($LASTEXITCODE -ne 0) { throw "Falha ao baixar $Uri com curl (codigo $LASTEXITCODE)." }
  } else {
    Invoke-WebRequest -Uri $Uri -OutFile $partial -UseBasicParsing
  }
  Move-Item -LiteralPath $partial -Destination $Destination -Force
  Assert-FileHash -Path $Destination -ExpectedSha256 $ExpectedSha256
}

function Assert-TrustedSignature {
  param([string]$Path, [string]$PublisherPattern)
  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch $PublisherPattern) {
    throw "Assinatura Authenticode invalida ou inesperada em $Path."
  }
}

function Copy-ArchiveLicenseFiles {
  param([string]$Archive, [string]$Destination, [string]$Prefix)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
  try {
    foreach ($entry in $zip.Entries) {
      if ($entry.Name -and $entry.FullName -match '(?i)(^|/)(LICENSE[^/]*|COPYING[^/]*|NOTICE[^/]*|README\.txt)$') {
        $safeName = ($entry.FullName -replace '[^A-Za-z0-9._-]', '_')
        $target = Join-Path $Destination "$Prefix-$safeName"
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
      }
    }
  } finally {
    $zip.Dispose()
  }
}

New-Item -ItemType Directory -Force -Path $AssetRoot, $WheelRoot, $ModelRoot, $VulkanRoot, $FfmpegRoot, $LicenseRoot, $BuildRoot | Out-Null

if (-not $SkipDownloads) {
  Get-VerifiedDownload -Uri $Dependencies.python.url `
    -Destination (Join-Path $AssetRoot $Dependencies.python.fileName) `
    -ExpectedSha256 $Dependencies.python.sha256
  Assert-TrustedSignature -Path (Join-Path $AssetRoot $Dependencies.python.fileName) -PublisherPattern $Dependencies.python.signerSubjectPattern
  Get-VerifiedDownload -Uri $Dependencies.node.url `
    -Destination (Join-Path $AssetRoot $Dependencies.node.fileName) `
    -ExpectedSha256 $Dependencies.node.sha256
  Get-VerifiedDownload -Uri $Dependencies.vcRedist.url `
    -Destination (Join-Path $AssetRoot $Dependencies.vcRedist.fileName) `
    -ExpectedSha256 $Dependencies.vcRedist.sha256
  Assert-TrustedSignature -Path (Join-Path $AssetRoot $Dependencies.vcRedist.fileName) -PublisherPattern $Dependencies.vcRedist.signerSubjectPattern
  Get-VerifiedDownload -Uri $Dependencies.ffmpeg.url `
    -Destination (Join-Path $AssetRoot $Dependencies.ffmpeg.fileName) `
    -ExpectedSha256 $Dependencies.ffmpeg.sha256

  Reset-Directory -Parent $AssetRoot -Path $WheelRoot
  & $PythonCommand -m pip download --only-binary=:all: --require-hashes --dest $WheelRoot -r $RequirementsLock
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao preparar os pacotes Python bloqueados por hash.' }

  $cudaAuditRoot = Join-Path $BuildRoot 'cuda-wheels-audit'
  Reset-Directory -Parent $BuildRoot -Path $cudaAuditRoot
  & $PythonCommand -m pip download --only-binary=:all: --require-hashes --dest $cudaAuditRoot -r $CudaRequirementsLock
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao validar o pacote NVIDIA opcional bloqueado por hash.' }
  Assert-ChildPath -Parent $BuildRoot -Child $cudaAuditRoot
  [System.IO.Directory]::Delete([System.IO.Path]::GetFullPath($cudaAuditRoot), $true)

  $ggmlModel = Join-Path $ModelRoot $Dependencies.ggmlModel.fileName
  $ggmlUrl = "https://huggingface.co/$($Dependencies.ggmlModel.repository)/resolve/$($Dependencies.ggmlModel.revision)/$($Dependencies.ggmlModel.fileName)?download=true"
  Get-VerifiedDownload -Uri $ggmlUrl -Destination $ggmlModel -ExpectedSha256 $Dependencies.ggmlModel.sha256

  $fasterModel = Join-Path $ModelRoot 'faster-whisper-small'
  Reset-Directory -Parent $ModelRoot -Path $fasterModel
  foreach ($modelFile in $Dependencies.fasterWhisperModel.files) {
    $modelUrl = "https://huggingface.co/$($Dependencies.fasterWhisperModel.repository)/resolve/$($Dependencies.fasterWhisperModel.revision)/$($modelFile.name)?download=true"
    Get-VerifiedDownload -Uri $modelUrl `
      -Destination (Join-Path $fasterModel $modelFile.name) `
      -ExpectedSha256 $modelFile.sha256
  }
}

$ffmpegArchive = Join-Path $AssetRoot $Dependencies.ffmpeg.fileName
Assert-FileHash -Path $ffmpegArchive -ExpectedSha256 $Dependencies.ffmpeg.sha256
$ffmpegExtract = Join-Path $BuildRoot 'ffmpeg-extract'
Reset-Directory -Parent $BuildRoot -Path $ffmpegExtract
Expand-Archive -LiteralPath $ffmpegArchive -DestinationPath $ffmpegExtract -Force
$ffmpegExe = Get-ChildItem -LiteralPath $ffmpegExtract -Recurse -Filter 'ffmpeg.exe' | Select-Object -First 1
if (-not $ffmpegExe) { throw 'ffmpeg.exe nao foi encontrado no pacote verificado.' }
Copy-Item -LiteralPath $ffmpegExe.FullName -Destination (Join-Path $FfmpegRoot 'ffmpeg.exe') -Force
Copy-ArchiveLicenseFiles -Archive $ffmpegArchive -Destination (Join-Path $LicenseRoot 'ffmpeg') -Prefix 'ffmpeg'

$nodeArchive = Join-Path $AssetRoot $Dependencies.node.fileName
Assert-FileHash -Path $nodeArchive -ExpectedSha256 $Dependencies.node.sha256
Copy-ArchiveLicenseFiles -Archive $nodeArchive -Destination (Join-Path $LicenseRoot 'node') -Prefix 'node'

foreach ($wheel in Get-ChildItem -LiteralPath $WheelRoot -Filter '*.whl') {
  Copy-ArchiveLicenseFiles -Archive $wheel.FullName -Destination (Join-Path $LicenseRoot 'python') -Prefix $wheel.BaseName
}

Push-Location $AppRoot
try {
  $nodeLicenseJson = (& pnpm.cmd licenses list --prod --json | Out-String)
  if ($LASTEXITCODE -ne 0 -or -not $nodeLicenseJson.Trim()) { throw 'Falha ao gerar o inventario de licencas Node.js.' }
  [System.IO.File]::WriteAllText((Join-Path $LicenseRoot 'node-dependencies.json'), $nodeLicenseJson, [System.Text.UTF8Encoding]::new($false))
} finally {
  Pop-Location
}

if (-not $WhisperCppSource) {
  $WhisperCppSource = Join-Path $BuildRoot 'whisper.cpp'
  if (-not (Test-Path -LiteralPath (Join-Path $WhisperCppSource '.git'))) {
    Assert-ChildPath -Parent $BuildRoot -Child $WhisperCppSource
    & git clone --filter=blob:none --no-checkout $Dependencies.whisperCpp.repository $WhisperCppSource
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao obter o whisper.cpp.' }
  }
  & git -C $WhisperCppSource fetch --depth 1 origin $Dependencies.whisperCpp.commit
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao obter o commit fixado do whisper.cpp.' }
  & git -C $WhisperCppSource checkout --force $Dependencies.whisperCpp.commit
  & git -C $WhisperCppSource submodule update --init --recursive --depth 1
  if ($LASTEXITCODE -ne 0) { throw 'Falha ao obter os submodulos fixados do whisper.cpp.' }
}

$Cmake = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $Cmake) { throw 'CMake nao encontrado. Use o workflow windows-installer ou instale CMake na maquina de build.' }
if (-not $env:VULKAN_SDK) { throw 'VULKAN_SDK nao configurado na maquina de build.' }

$whisperBuild = Join-Path $BuildRoot 'whisper-vulkan-build'
& $Cmake.Source -S $WhisperCppSource -B $whisperBuild -DGGML_VULKAN=ON -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
if ($LASTEXITCODE -ne 0) { throw 'Falha ao configurar o whisper.cpp com Vulkan.' }
& $Cmake.Source --build $whisperBuild --config Release --parallel 2
if ($LASTEXITCODE -ne 0) { throw 'Falha ao compilar o whisper.cpp com Vulkan.' }

$whisperCli = Get-ChildItem -LiteralPath $whisperBuild -Recurse -Filter 'whisper-cli.exe' | Where-Object { $_.FullName -match 'Release' } | Select-Object -First 1
if (-not $whisperCli) { throw 'whisper-cli.exe nao foi encontrado depois da compilacao Vulkan.' }
Reset-Directory -Parent $AssetRoot -Path $VulkanRoot
$binaryDirectory = $whisperCli.Directory.FullName
Get-ChildItem -LiteralPath $binaryDirectory -File | Where-Object { $_.Extension -in '.exe', '.dll' } | Copy-Item -Destination $VulkanRoot -Force
Copy-Item -LiteralPath (Join-Path $WhisperCppSource 'LICENSE') -Destination (Join-Path $LicenseRoot 'whisper.cpp-LICENSE') -Force

Copy-Item -LiteralPath $DependencyFile -Destination (Join-Path $AssetRoot 'dependencies.json') -Force
Copy-Item -LiteralPath $RequirementsLock -Destination (Join-Path $WheelRoot 'requirements.lock') -Force
[System.IO.File]::WriteAllLines((Join-Path $LicenseRoot 'SOURCE-OFFER.txt'), @(
  'O codigo do TranscrevoFacil esta em https://github.com/yurimj/TranscrevoFacil.',
  "FFmpeg $($Dependencies.ffmpeg.version): $($Dependencies.ffmpeg.sourceUrl)",
  "Receita da compilacao FFmpeg distribuida: $($Dependencies.ffmpeg.buildSourceUrl)",
  "whisper.cpp $($Dependencies.whisperCpp.version): $($Dependencies.whisperCpp.repository) no commit $($Dependencies.whisperCpp.commit)",
  'Os textos de licenca extraidos dos pacotes acompanham este diretorio.'
), [System.Text.UTF8Encoding]::new($false))

$provenance = [ordered]@{
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  dependencies = $Dependencies
  whisperCppCommit = (& git -C $WhisperCppSource rev-parse HEAD).Trim()
  baseRequirementsSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $RequirementsLock).Hash.ToLowerInvariant()
  cudaRequirementsSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $CudaRequirementsLock).Hash.ToLowerInvariant()
}
[System.IO.File]::WriteAllText((Join-Path $AssetRoot 'build-provenance.json'), ($provenance | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))

$manifestItems = Get-ChildItem -LiteralPath $AssetRoot -Recurse -File | Where-Object { $_.Name -notin 'manifest.sha256', 'README.md' }
$manifestLines = foreach ($item in $manifestItems) {
  Assert-ChildPath -Parent $AssetRoot -Child $item.FullName
  $relative = $item.FullName.Substring([System.IO.Path]::GetFullPath($AssetRoot).TrimEnd('\').Length + 1)
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
  "$hash  $relative"
}
[System.IO.File]::WriteAllLines((Join-Path $AssetRoot 'manifest.sha256'), $manifestLines, [System.Text.UTF8Encoding]::new($false))

Write-Host "Assets do instalador preparados e verificados em $AssetRoot"
