$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $PSScriptRoot
Push-Location $AppRoot

try {
  $requiredFiles = @(
    'LICENSE',
    'SECURITY.md',
    'THIRD_PARTY_NOTICES.md',
    'premissas.md',
    'installer\dependencies.json',
    'installer\python-requirements.lock',
    'installer\python-requirements-cuda.lock',
    'scripts\test-installed-release.ps1',
    '.github\dependabot.yml',
    '.github\workflows\ci.yml',
    '.github\workflows\windows-installer.yml'
  )
  foreach ($file in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Arquivo obrigatorio ausente: $file" }
  }

  foreach ($script in Get-ChildItem -LiteralPath 'scripts' -Filter '*.ps1') {
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      $script.FullName,
      [ref]$null,
      [ref]$parseErrors
    ) | Out-Null
    if ($parseErrors.Count) {
      throw "PowerShell invalido em $($script.Name): $($parseErrors[0].Message)"
    }
  }

  $tracked = @(git ls-files)
  $forbiddenPatterns = @(
    '(^|/)\.env$',
    '(^|/)uploads/',
    '(^|/)transcripts/',
    '(^|/)runtime/',
    '(^|/)__pycache__/',
    '\.py[co]$',
    '\.(pem|pfx|p12|key|kdbx)$'
  )
  foreach ($path in $tracked) {
    foreach ($pattern in $forbiddenPatterns) {
      if ($path -match $pattern) { throw "Arquivo proibido esta versionado: $path" }
    }
  }

  foreach ($path in @('.env', 'uploads/arquivo.mp4', 'transcripts/arquivo.txt', 'runtime/arquivo.dll', 'scripts/__pycache__/teste.pyc')) {
    git check-ignore --quiet -- $path
    if ($LASTEXITCODE -ne 0) { throw "Caminho sensivel nao esta ignorado: $path" }
  }

  $package = Get-Content -Raw -LiteralPath 'package.json' | ConvertFrom-Json
  if ($package.license -ne 'MIT') { throw 'package.json deve declarar a licenca MIT.' }
  if ($package.private -ne $true) { throw 'package.json deve manter private=true para impedir publicacao acidental no npm.' }
  if ($package.packageManager -notmatch '^pnpm@\d+\.\d+\.\d+$') { throw 'packageManager deve usar uma versao exata do pnpm.' }

  $installerText = Get-Content -Raw -LiteralPath 'installer\TranscrevoFacil.iss'
  if ($installerText -notmatch [regex]::Escape("#define MyAppVersion `"$($package.version)`"")) {
    throw 'A versao do instalador difere da versao do package.json.'
  }
  foreach ($requiredInstallerFile in @('LICENSE', 'SECURITY.md', 'dependencies.json', 'python-requirements.lock', 'python-requirements-cuda.lock')) {
    if ($installerText -notmatch [regex]::Escape($requiredInstallerFile)) {
      throw "O instalador nao inclui $requiredInstallerFile."
    }
  }

  $dependencies = Get-Content -Raw -LiteralPath 'installer\dependencies.json' | ConvertFrom-Json
  if ($dependencies.python.distribution -ne 'portable' -or $dependencies.python.fileName -notmatch '\.zip$') {
    throw 'O Python do instalador deve ser uma distribuicao portatil em ZIP.'
  }
  $runtimeInstaller = Get-Content -Raw -LiteralPath 'scripts\install-runtime.ps1'
  if ($runtimeInstaller -match 'InstallAllUsers|PythonInstaller') {
    throw 'O runtime nao pode executar o instalador global do Python.'
  }
  if ($installerText -notmatch '\[Code\]' -or $installerText -notmatch 'RaiseException') {
    throw 'O instalador deve abortar quando a preparacao dos runtimes falhar.'
  }
  foreach ($criticalAsset in @('whisper-vulkan\whisper-cli.exe', 'models\ggml-small.bin', 'ffmpeg\ffmpeg.exe')) {
    if ($dependencies.requiredAssets -notcontains $criticalAsset) {
      throw "requiredAssets deve declarar o runtime obrigatorio $criticalAsset."
    }
  }
  $assetPreparation = Get-Content -Raw -LiteralPath 'scripts\prepare-installer-assets.ps1'
  if ($assetPreparation -notmatch 'requiredAssets') {
    throw 'A preparacao de assets deve validar requiredAssets antes de gerar o manifesto.'
  }
  if ($runtimeInstaller -notmatch 'requiredAssets') {
    throw 'O install-runtime deve validar requiredAssets antes de preparar os runtimes.'
  }
  if (-not $dependencies.buildTools.cmake.sha256) {
    throw 'O CMake usado no build deve estar fixado com hash em dependencies.json.'
  }

  $reviewDate = [DateTime]::ParseExact($dependencies.reviewedAt, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  if (([DateTime]::UtcNow.Date - $reviewDate.Date).TotalDays -gt 120) {
    throw 'A revisao das dependencias do instalador tem mais de 120 dias.'
  }

  $dependencyJson = Get-Content -Raw -LiteralPath 'installer\dependencies.json'
  $hashValues = [regex]::Matches($dependencyJson, '"sha256"\s*:\s*"([0-9a-f]+)"')
  if ($hashValues.Count -lt 8) { throw 'O manifesto de dependencias nao contem todos os hashes esperados.' }
  foreach ($match in $hashValues) {
    if ($match.Groups[1].Value.Length -ne 64) { throw "SHA-256 invalido: $($match.Groups[1].Value)" }
  }

  $baseRequirements = Get-Content -Raw -LiteralPath 'installer\python-requirements.lock'
  $cudaRequirements = Get-Content -Raw -LiteralPath 'installer\python-requirements-cuda.lock'
  if ($baseRequirements -match '(?im)^nvidia-') {
    throw 'Pacotes NVIDIA nao devem inflar o instalador-base.'
  }
  foreach ($requiredCudaPackage in @('nvidia-cublas-cu12', 'nvidia-cuda-nvrtc-cu12', 'nvidia-cudnn-cu12')) {
    if ($cudaRequirements -notmatch "(?m)^$([regex]::Escape($requiredCudaPackage))==") {
      throw "Pacote CUDA obrigatorio ausente do lock opcional: $requiredCudaPackage"
    }
  }

  $workflowFiles = Get-ChildItem -LiteralPath '.github\workflows' -Filter '*.yml'
  foreach ($workflow in $workflowFiles) {
    $workflowText = Get-Content -Raw -LiteralPath $workflow.FullName
    if ($workflowText -match 'uses:\s+[^\s]+@(v\d+|main|master)\b') {
      throw "Action nao fixada por commit em $($workflow.Name)."
    }
    if ($workflowText -match '(?i)choco\s+install') {
      throw "Chocolatey sem procedencia fixada em $($workflow.Name)."
    }
  }

  $serverText = Get-Content -Raw -LiteralPath 'server.js'
  if ($serverText -notmatch 'app\.listen\(port, host,') { throw 'O servidor nao esta explicitamente limitado ao host validado.' }
  if ((Get-Content -Raw -LiteralPath '.env.example') -notmatch '(?m)^HOST=127\.0\.0\.1\r?$') {
    throw '.env.example deve limitar HOST a 127.0.0.1.'
  }
  $installerWorkflow = Get-Content -Raw -LiteralPath '.github\workflows\windows-installer.yml'
  if ($installerWorkflow -notmatch [regex]::Escape('scripts\test-installed-release.ps1')) {
    throw 'O workflow do instalador deve validar uma instalacao limpa.'
  }

  Write-Host 'Validacao de publicacao concluida sem pendencias.'
} finally {
  Pop-Location
}
