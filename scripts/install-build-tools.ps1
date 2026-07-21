$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $PSScriptRoot
$BuildRoot = Join-Path $AppRoot '.installer-build'
$DependencyFile = Join-Path $AppRoot 'installer\dependencies.json'
$Dependencies = Get-Content -Raw -LiteralPath $DependencyFile | ConvertFrom-Json

function Get-VerifiedDownload {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][string]$ExpectedSha256
  )

  if (Test-Path -LiteralPath $Destination) {
    $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
    if ($existingHash -eq $ExpectedSha256.ToLowerInvariant()) { return }
    Remove-Item -LiteralPath $Destination -Force
  }

  $partial = "$Destination.download"
  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($curl) {
    & $curl.Source --location --fail --retry 3 --retry-delay 2 --continue-at - --output $partial $Uri
    if ($LASTEXITCODE -ne 0) { throw "Falha ao baixar $Uri com curl (codigo $LASTEXITCODE)." }
  } else {
    Invoke-WebRequest -Uri $Uri -OutFile $partial -UseBasicParsing
  }
  Move-Item -LiteralPath $partial -Destination $Destination -Force

  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash.ToLowerInvariant()
  if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
    throw "Hash invalido para $Destination. Esperado $ExpectedSha256; recebido $actual."
  }
}

function Assert-TrustedSignature {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$PublisherPattern
  )

  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch $PublisherPattern) {
    throw "Assinatura Authenticode invalida ou inesperada em $Path."
  }
}

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

$vulkan = $Dependencies.buildTools.vulkanSdk
$vulkanInstaller = Join-Path $BuildRoot $vulkan.fileName
$vulkanRoot = Join-Path $BuildRoot "VulkanSDK-$($vulkan.version)"
Get-VerifiedDownload -Uri $vulkan.url -Destination $vulkanInstaller -ExpectedSha256 $vulkan.sha256
Assert-TrustedSignature -Path $vulkanInstaller -PublisherPattern $vulkan.signerSubjectPattern

if (-not (Test-Path -LiteralPath (Join-Path $vulkanRoot 'Bin\glslc.exe'))) {
  $vulkanProcess = Start-Process -FilePath $vulkanInstaller `
    -ArgumentList '--root', $vulkanRoot, '--accept-licenses', '--default-answer', '--confirm-command', 'install' `
    -Wait -PassThru -WindowStyle Hidden
  if ($vulkanProcess.ExitCode -ne 0) {
    throw "A instalacao do Vulkan SDK falhou com codigo $($vulkanProcess.ExitCode)."
  }
}

$inno = $Dependencies.buildTools.innoSetup
$innoInstaller = Join-Path $BuildRoot $inno.fileName
$innoRoot = Join-Path $BuildRoot "InnoSetup-$($inno.version)"
Get-VerifiedDownload -Uri $inno.url -Destination $innoInstaller -ExpectedSha256 $inno.sha256
Assert-TrustedSignature -Path $innoInstaller -PublisherPattern $inno.signerSubjectPattern

$iscc = Join-Path $innoRoot 'ISCC.exe'
if (-not (Test-Path -LiteralPath $iscc)) {
  $innoProcess = Start-Process -FilePath $innoInstaller `
    -ArgumentList '/PORTABLE=1', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=$innoRoot" `
    -Wait -PassThru -WindowStyle Hidden
  if ($innoProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $iscc)) {
    throw "A instalacao portatil do Inno Setup falhou com codigo $($innoProcess.ExitCode)."
  }
}

$env:VULKAN_SDK = $vulkanRoot
$env:ISCC_PATH = $iscc
$env:PATH = "$(Join-Path $vulkanRoot 'Bin');$env:PATH"

if ($env:GITHUB_ENV) {
  "VULKAN_SDK=$vulkanRoot" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
  "ISCC_PATH=$iscc" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
}
if ($env:GITHUB_PATH) {
  (Join-Path $vulkanRoot 'Bin') | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
}

Write-Host "Vulkan SDK $($vulkan.version) e Inno Setup $($inno.version) verificados."
