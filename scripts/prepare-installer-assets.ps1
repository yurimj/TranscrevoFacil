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

Get-ChildItem -LiteralPath $AssetRoot -File -Filter '*.download' | Remove-Item -Force

if (-not $SkipDownloads) {
  Get-VerifiedDownload -Uri $Dependencies.python.url `
    -Destination (Join-Path $AssetRoot $Dependencies.python.fileName) `
    -ExpectedSha256 $Dependencies.python.sha256
  Get-ChildItem -LiteralPath $AssetRoot -File | Where-Object {
    $_.Name -match '^python-[0-9.]+-amd64\.(exe|zip)$' -and $_.Name -ne $Dependencies.python.fileName
  } | Remove-Item -Force
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

$CmakeExe = if ($env:CMAKE_PATH -and (Test-Path -LiteralPath $env:CMAKE_PATH)) {
  $env:CMAKE_PATH
} else {
  $pinnedCmake = Join-Path $BuildRoot "CMake-$($Dependencies.buildTools.cmake.version)\bin\cmake.exe"
  if (Test-Path -LiteralPath $pinnedCmake) {
    $pinnedCmake
  } else {
    (Get-Command cmake -ErrorAction SilentlyContinue).Source
  }
}
if (-not $CmakeExe) {
  throw 'CMake nao encontrado. Rode scripts\install-build-tools.ps1 para baixar a versao fixada em installer\dependencies.json.'
}

$NinjaExe = if ($env:NINJA_PATH -and (Test-Path -LiteralPath $env:NINJA_PATH)) {
  $env:NINJA_PATH
} else {
  $pinnedNinja = Join-Path $BuildRoot "Ninja-$($Dependencies.buildTools.ninja.version)\ninja.exe"
  if (Test-Path -LiteralPath $pinnedNinja) { $pinnedNinja } else { (Get-Command ninja -ErrorAction SilentlyContinue).Source }
}
if (-not $NinjaExe) {
  throw 'Ninja nao encontrado. Rode scripts\install-build-tools.ps1 para baixar a versao fixada em installer\dependencies.json.'
}
if (-not $env:VULKAN_SDK) { throw 'VULKAN_SDK nao configurado na maquina de build.' }

# O gerador Ninja nao localiza o MSVC sozinho (o gerador Visual Studio localizava, mas aninhava
# MSBuild dentro de MSBuild e quebrava o ExternalProject vulkan-shaders-gen). Importamos o ambiente
# do vcvars64.bat para que cl.exe, INCLUDE e LIB fiquem disponiveis para o Ninja.
$vsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vsWhere)) {
  throw 'vswhere.exe nao encontrado. Instale o Visual Studio 2022 (ou Build Tools) com o componente VC.Tools.x86.x64.'
}
$vsRoot = (& $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1)
if (-not $vsRoot) { throw 'Nenhuma instalacao do MSVC (VC.Tools.x86.x64) foi encontrada pelo vswhere.' }
$VcVars = Join-Path $vsRoot.Trim() 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $VcVars)) { throw "vcvars64.bat nao encontrado em $VcVars." }
Write-Host "Importando o ambiente MSVC de $VcVars"
$vcEnvDump = cmd /c "`"$VcVars`" >nul 2>&1 && set"
foreach ($vcLine in $vcEnvDump) {
  if ($vcLine -match '^([^=]+)=(.*)$') {
    [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process')
  }
}
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
  throw 'cl.exe nao ficou disponivel apos importar o vcvars64.bat.'
}

Write-Host "Compilando o whisper.cpp com Vulkan (gerador Ninja) usando $CmakeExe"
$whisperBuild = Join-Path $BuildRoot 'whisper-vulkan-build'
Reset-Directory -Parent $BuildRoot -Path $whisperBuild
& $CmakeExe -G Ninja -S $WhisperCppSource -B $whisperBuild "-DCMAKE_MAKE_PROGRAM=$NinjaExe" `
  -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl -DCMAKE_BUILD_TYPE=Release `
  -DGGML_VULKAN=ON -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
if ($LASTEXITCODE -ne 0) { throw 'Falha ao configurar o whisper.cpp com Vulkan.' }
& $CmakeExe --build $whisperBuild --parallel 2
if ($LASTEXITCODE -ne 0) { throw 'Falha ao compilar o whisper.cpp com Vulkan.' }

$whisperCli = Get-ChildItem -LiteralPath $whisperBuild -Recurse -Filter 'whisper-cli.exe' | Select-Object -First 1
if (-not $whisperCli) { throw 'whisper-cli.exe nao foi encontrado depois da compilacao Vulkan.' }
Reset-Directory -Parent $AssetRoot -Path $VulkanRoot
$binaryDirectory = $whisperCli.Directory.FullName
# O Ninja gera todos os executaveis do whisper.cpp em bin\ (bench, server, parakeet, quantize, vad...),
# mas o TranscrevoFacil so invoca whisper-cli.exe. Copiamos apenas ele e as DLLs de runtime para nao
# inflar o instalador com binarios que o produto nunca usa.
Copy-Item -LiteralPath $whisperCli.FullName -Destination (Join-Path $VulkanRoot 'whisper-cli.exe') -Force
Get-ChildItem -LiteralPath $binaryDirectory -File -Filter '*.dll' | Copy-Item -Destination $VulkanRoot -Force
Copy-Item -LiteralPath (Join-Path $WhisperCppSource 'LICENSE') -Destination (Join-Path $LicenseRoot 'whisper.cpp-LICENSE') -Force

# Executa o binario copiado: um DLL nativo ausente so aparece no carregamento, nunca na lista de arquivos.
# O whisper-cli.exe imprime a lista de dispositivos Vulkan no stderr; sob ErrorActionPreference='Stop'
# o operador 2>&1 transformaria essa saida normal em erro terminante, entao suspendemos o Stop so aqui.
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& (Join-Path $VulkanRoot 'whisper-cli.exe') --help 2>&1 | Out-Null
$whisperCliExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction
if ($whisperCliExit -ne 0) {
  throw "O whisper-cli.exe copiado nao executou (codigo $whisperCliExit). Provavelmente falta um DLL ao lado do executavel."
}

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

# O manifesto e gerado enumerando o que existe, entao um componente que sumiu do build produz
# um manifesto valido e autoconsistente. Este gate compara a arvore com a lista declarada em
# dependencies.json para que a falha aconteca aqui, e nao na maquina do usuario final.
if (-not $Dependencies.requiredAssets) {
  throw 'installer\dependencies.json nao declara requiredAssets.'
}
$missingAssets = foreach ($requiredAsset in $Dependencies.requiredAssets) {
  $requiredPath = Join-Path $AssetRoot $requiredAsset
  Assert-ChildPath -Parent $AssetRoot -Child $requiredPath
  if (-not (Test-Path -LiteralPath $requiredPath)) {
    $requiredAsset
  } elseif ((Get-Item -LiteralPath $requiredPath).Length -eq 0) {
    "$requiredAsset (arquivo vazio)"
  }
}
if ($missingAssets) {
  throw "O pacote do instalador esta incompleto e nao pode ser publicado. Ausentes: $($missingAssets -join ', ')"
}

$manifestItems = Get-ChildItem -LiteralPath $AssetRoot -Recurse -File | Where-Object { $_.Name -notin 'manifest.sha256', 'README.md' }
$manifestLines = foreach ($item in $manifestItems) {
  Assert-ChildPath -Parent $AssetRoot -Child $item.FullName
  $relative = $item.FullName.Substring([System.IO.Path]::GetFullPath($AssetRoot).TrimEnd('\').Length + 1)
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant()
  "$hash  $relative"
}
[System.IO.File]::WriteAllLines((Join-Path $AssetRoot 'manifest.sha256'), $manifestLines, [System.Text.UTF8Encoding]::new($false))

Write-Host "Assets do instalador preparados e verificados em $AssetRoot"
