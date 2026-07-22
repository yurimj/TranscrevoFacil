param(
  [Parameter(Mandatory = $true)][string]$InstallerPath
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $PSScriptRoot
$BuildRoot = Join-Path $AppRoot '.installer-build'
$resolvedInstaller = [System.IO.Path]::GetFullPath($InstallerPath)
$resolvedOutputRoot = [System.IO.Path]::GetFullPath((Join-Path $AppRoot 'dist-installer')).TrimEnd('\') + '\'
if (-not $resolvedInstaller.StartsWith($resolvedOutputRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw 'O instalador a assinar esta fora de dist-installer.'
}

if (-not $env:WINDOWS_SIGNING_CERTIFICATE_BASE64 -or -not $env:WINDOWS_SIGNING_CERTIFICATE_PASSWORD) {
  throw 'Configure os secrets WINDOWS_SIGNING_CERTIFICATE_BASE64 e WINDOWS_SIGNING_CERTIFICATE_PASSWORD antes de publicar uma tag.'
}

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
$certificatePath = Join-Path $BuildRoot 'codesigning.pfx'
[System.IO.File]::WriteAllBytes($certificatePath, [Convert]::FromBase64String($env:WINDOWS_SIGNING_CERTIFICATE_BASE64))

try {
  $signTool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter 'signtool.exe' |
    Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
  if (-not $signTool) { throw 'signtool.exe nao foi encontrado no runner Windows.' }

  & $signTool.FullName sign /f $certificatePath /p $env:WINDOWS_SIGNING_CERTIFICATE_PASSWORD /fd SHA256 /tr 'http://timestamp.digicert.com' /td SHA256 $resolvedInstaller
  if ($LASTEXITCODE -ne 0) { throw 'A assinatura Authenticode do instalador falhou.' }

  $signature = Get-AuthenticodeSignature -LiteralPath $resolvedInstaller
  if ($signature.Status -ne 'Valid') { throw "Assinatura final invalida: $($signature.Status)" }
  Write-Host "Instalador assinado por $($signature.SignerCertificate.Subject)."
} finally {
  if (Test-Path -LiteralPath $certificatePath) {
    [System.IO.File]::Delete([System.IO.Path]::GetFullPath($certificatePath))
  }
}
