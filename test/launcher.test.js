import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

test('inicializador reutiliza instancia fora da porta preferida e ignora estado invalido', {
  skip: process.platform !== 'win32',
}, () => {
  const source = fileURLToPath(new URL('../scripts/start-transcrevofacil.ps1', import.meta.url));
  const script = `
    $ErrorActionPreference = 'Stop'
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($env:LAUNCHER_SOURCE, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw $errors[0] }
    $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
      ForEach-Object { Invoke-Expression $_.Extent.Text }
    $StatePath = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.json')
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
      $listener.Start()
      $occupiedPort = $listener.LocalEndpoint.Port
      if (Test-PortFree $occupiedPort) { throw 'Porta ocupada considerada livre.' }
      $listener.Stop()
      if (-not (Test-PortFree $occupiedPort)) { throw 'Porta livre considerada ocupada.' }

      # A porta escolhida existe em listeners reais; a saude e simulada para
      # garantir que o teste nao depende de aplicativos em execucao na maquina.
      $runningPort = 0
      foreach ($candidate in 3099..3001) {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $candidate)
        try { $listener.Start(); $runningPort = $candidate; break } catch { $listener.Stop() }
      }
      if (-not $runningPort) { throw 'Sem porta disponivel para o teste.' }
      function Test-AppHealth { param([int]$Port) return $Port -eq $runningPort }
      function Test-PortFree { param([int]$Port) return $true }
      $selection = Find-AppPort 3000
      if (-not $selection.Running -or $selection.Port -ne $runningPort) { throw 'Duplicou instancia com porta preferida livre.' }

      [IO.File]::WriteAllText($StatePath, '{invalido')
      $selection = Find-AppPort 3000
      if (-not $selection.Running -or $selection.Port -ne $runningPort) { throw 'Estado corrompido bloqueou a instancia.' }

      [IO.File]::WriteAllText($StatePath, '{"port":3000}')
      $selection = Find-AppPort 3000
      if ($selection.Port -ne $runningPort) { throw 'Reutilizou estado sem validar saude.' }

      function Test-AppHealth { param([int]$Port) return $false }
      function Test-PortFree { param([int]$Port) return $Port -eq 3003 }
      $selection = Find-AppPort 3000
      if ($selection.Running -or $selection.Port -ne 3003) { throw 'Nao escolheu a proxima porta livre.' }
      function Test-PortFree { param([int]$Port) return $false }
      $failed = $false
      try { Find-AppPort 3000 } catch { $failed = $true }
      if (-not $failed) { throw 'Nao informou esgotamento de portas.' }
    } finally {
      $listener.Stop()
      if (Test-Path -LiteralPath $StatePath) { Remove-Item -LiteralPath $StatePath }
    }
  `;
  const result = spawnSync(path.join(process.env.WINDIR, 'System32/WindowsPowerShell/v1.0/powershell.exe'),
    ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')],
    { encoding: 'utf8', timeout: 30000, env: { ...process.env, LAUNCHER_SOURCE: source } });
  assert.equal(result.status, 0, `${result.error || ''}\n${result.stdout}\n${result.stderr}`);
});
