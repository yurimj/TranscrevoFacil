$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $PSScriptRoot

Push-Location $AppRoot
try {
  & pnpm.cmd install --prod --frozen-lockfile --config.node-linker=hoisted
  if ($LASTEXITCODE -ne 0) { throw 'pnpm install falhou.' }
  & pnpm.cmd test
  if ($LASTEXITCODE -ne 0) { throw 'Os testes falharam.' }
  & pnpm.cmd run verify:release
  if ($LASTEXITCODE -ne 0) { throw 'A validacao de publicacao falhou.' }
} finally {
  Pop-Location
}

if (-not $env:VULKAN_SDK -or -not $env:ISCC_PATH -or -not $env:CMAKE_PATH -or -not $env:NINJA_PATH) {
  & (Join-Path $PSScriptRoot 'install-build-tools.ps1')
  if ($LASTEXITCODE -ne 0) { throw 'A preparacao das ferramentas de build falhou.' }
}

& (Join-Path $PSScriptRoot 'prepare-installer-assets.ps1')
if ($LASTEXITCODE -ne 0) { throw 'A preparacao dos assets falhou.' }

$Iscc = if ($env:ISCC_PATH -and (Test-Path -LiteralPath $env:ISCC_PATH)) { Get-Item -LiteralPath $env:ISCC_PATH } else { Get-Command iscc.exe -ErrorAction SilentlyContinue }
if (-not $Iscc) {
  foreach ($defaultIscc in @('C:\Program Files\Inno Setup 7\ISCC.exe', 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe')) {
    if (Test-Path -LiteralPath $defaultIscc) { $Iscc = Get-Item $defaultIscc; break }
  }
}
if (-not $Iscc) { throw 'Inno Setup nao encontrado mesmo depois da preparacao automatica.' }

& $Iscc.FullName (Join-Path $AppRoot 'installer\TranscrevoFacil.iss')
if ($LASTEXITCODE -ne 0) { throw 'A compilacao do instalador falhou.' }

Write-Host "Instalador criado em $(Join-Path $AppRoot 'dist-installer')"
