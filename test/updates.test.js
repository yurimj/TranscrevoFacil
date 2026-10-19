import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildUpdateStatus,
  compareVersions,
  isNewerVersion,
  isTrustedReleaseUrl,
  parseChecksums,
  parseVersion,
  selectChecksumAsset,
  selectInstallerAsset
} from '../lib/updates.js';

test('le a versao com ou sem o prefixo v', () => {
  assert.deepEqual(parseVersion('v0.2.5'), { major: 0, minor: 2, patch: 5 });
  assert.deepEqual(parseVersion('0.2.5'), { major: 0, minor: 2, patch: 5 });
  assert.deepEqual(parseVersion('1.10.3-beta'), { major: 1, minor: 10, patch: 3 });
  assert.equal(parseVersion('nao-e-versao'), null);
  assert.equal(parseVersion(undefined), null);
});

test('compara versoes por numero, nao por texto', () => {
  assert.equal(compareVersions('0.2.10', '0.2.9'), 1);
  assert.equal(compareVersions('0.3.0', '0.2.99'), 1);
  assert.equal(compareVersions('1.0.0', '0.9.9'), 1);
  assert.equal(compareVersions('0.2.5', '0.2.5'), 0);
  assert.equal(compareVersions('0.2.4', '0.2.5'), -1);
  assert.equal(compareVersions('invalida', '0.2.5'), null);
});

test('so aponta atualizacao quando a versao publicada e maior', () => {
  assert.equal(isNewerVersion('v0.2.6', '0.2.5'), true);
  assert.equal(isNewerVersion('v0.2.5', '0.2.5'), false);
  assert.equal(isNewerVersion('v0.2.4', '0.2.5'), false);
  assert.equal(isNewerVersion('', '0.2.5'), false);
});

test('escolhe o instalador e o arquivo de checksums entre os anexos', () => {
  const assets = [
    { name: 'LICENSE', browser_download_url: 'https://github.com/x/y/releases/download/v1/LICENSE' },
    { name: 'SHA256SUMS.txt', browser_download_url: 'https://github.com/x/y/releases/download/v1/SHA256SUMS.txt' },
    { name: 'TranscrevoFacil-Setup-0.2.6.exe', size: 42, browser_download_url: 'https://github.com/x/y/releases/download/v1/TranscrevoFacil-Setup-0.2.6.exe' }
  ];
  assert.deepEqual(selectInstallerAsset(assets), {
    name: 'TranscrevoFacil-Setup-0.2.6.exe',
    size: 42,
    url: 'https://github.com/x/y/releases/download/v1/TranscrevoFacil-Setup-0.2.6.exe'
  });
  assert.equal(selectChecksumAsset(assets).name, 'SHA256SUMS.txt');
  assert.equal(selectInstallerAsset([{ name: 'outro-programa.exe' }]), null);
  assert.equal(selectChecksumAsset([]), null);
});

test('le o SHA256SUMS.txt nos dois formatos do sha256sum', () => {
  const text = [
    'a'.repeat(64) + '  TranscrevoFacil-Setup-0.2.6.exe',
    'b'.repeat(64) + ' *TranscrevoFacil-Setup-0.2.7.exe',
    'linha invalida'
  ].join('\r\n');
  const checksums = parseChecksums(text);
  assert.equal(checksums.get('TranscrevoFacil-Setup-0.2.6.exe'), 'a'.repeat(64));
  assert.equal(checksums.get('TranscrevoFacil-Setup-0.2.7.exe'), 'b'.repeat(64));
  assert.equal(checksums.size, 2);
});

test('aceita download apenas de onde o GitHub serve os anexos', () => {
  assert.equal(isTrustedReleaseUrl('https://github.com/yurimj/TranscrevoFacil/releases/download/v1/a.exe'), true);
  assert.equal(isTrustedReleaseUrl('https://objects.githubusercontent.com/pacote'), true);
  assert.equal(isTrustedReleaseUrl('http://github.com/a.exe'), false);
  assert.equal(isTrustedReleaseUrl('https://github.com.exemplo.net/a.exe'), false);
  assert.equal(isTrustedReleaseUrl('https://exemplo.com/a.exe'), false);
  assert.equal(isTrustedReleaseUrl('nao-e-url'), false);
});

test('monta o estado da atualizacao a partir da resposta do release', () => {
  const release = {
    tag_name: 'v0.2.6',
    name: 'TranscrevoFacil 0.2.6',
    html_url: 'https://github.com/yurimj/TranscrevoFacil/releases/tag/v0.2.6',
    published_at: '2026-08-03T13:00:00Z',
    assets: [
      { name: 'TranscrevoFacil-Setup-0.2.6.exe', size: 10, browser_download_url: 'https://github.com/a.exe' },
      { name: 'SHA256SUMS.txt', browser_download_url: 'https://github.com/SHA256SUMS.txt' }
    ]
  };
  const status = buildUpdateStatus({ currentVersion: '0.2.5', release });
  assert.equal(status.updateAvailable, true);
  assert.equal(status.latestVersion, '0.2.6');
  assert.equal(status.asset.name, 'TranscrevoFacil-Setup-0.2.6.exe');

  const mesmaVersao = buildUpdateStatus({ currentVersion: '0.2.6', release });
  assert.equal(mesmaVersao.updateAvailable, false);

  const semInstalador = buildUpdateStatus({ currentVersion: '0.2.5', release: { ...release, assets: [] } });
  assert.equal(semInstalador.updateAvailable, false);
});
