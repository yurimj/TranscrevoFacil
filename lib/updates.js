// Regras puras do detector de atualizacao. Ficam separadas do servidor para poderem ser
// testadas sem rede e sem subir o Express.

const installerPattern = /^TranscrevoFacil-Setup-.+\.exe$/i;
const checksumFileName = 'SHA256SUMS.txt';
const trustedDownloadHosts = new Set(['github.com', 'www.github.com']);
const trustedDownloadSuffix = '.githubusercontent.com';

// Aceita "v0.2.5" ou "0.2.5". Sufixos como "-beta" sao ignorados na comparacao: as tags do
// projeto usam apenas major.minor.patch, e tratar pre-release exigiria semver completo.
export function parseVersion(value) {
  const match = /^\s*v?(\d+)\.(\d+)\.(\d+)/.exec(String(value ?? ''));
  if (!match) return null;
  return { major: Number(match[1]), minor: Number(match[2]), patch: Number(match[3]) };
}

export function compareVersions(left, right) {
  const a = parseVersion(left);
  const b = parseVersion(right);
  if (!a || !b) return null;
  if (a.major !== b.major) return a.major > b.major ? 1 : -1;
  if (a.minor !== b.minor) return a.minor > b.minor ? 1 : -1;
  if (a.patch !== b.patch) return a.patch > b.patch ? 1 : -1;
  return 0;
}

export function isNewerVersion(candidate, current) {
  return compareVersions(candidate, current) === 1;
}

export function selectInstallerAsset(assets = []) {
  const found = (Array.isArray(assets) ? assets : []).find((asset) => installerPattern.test(String(asset?.name || '')));
  if (!found) return null;
  return {
    name: String(found.name),
    size: Number(found.size) || 0,
    url: String(found.browser_download_url || '')
  };
}

export function selectChecksumAsset(assets = []) {
  const found = (Array.isArray(assets) ? assets : [])
    .find((asset) => String(asset?.name || '').toLowerCase() === checksumFileName.toLowerCase());
  if (!found) return null;
  return { name: String(found.name), url: String(found.browser_download_url || '') };
}

// Formato do SHA256SUMS.txt: "<hash>  <nome>". Tolera um espaco so e o "*" do modo binario
// do sha256sum, que aparece quando o arquivo e gerado fora do workflow.
export function parseChecksums(text) {
  const checksums = new Map();
  for (const line of String(text ?? '').split(/\r?\n/)) {
    const match = /^([0-9a-f]{64})\s+\*?(.+?)\s*$/i.exec(line.trim());
    if (match) checksums.set(match[2], match[1].toLowerCase());
  }
  return checksums;
}

// So baixamos de onde o proprio GitHub serve os anexos de release. A URL vem de uma resposta
// da API, entao e tratada como dado externo: se o host nao for confiavel, nao ha download.
export function isTrustedReleaseUrl(value) {
  try {
    const url = new URL(String(value));
    if (url.protocol !== 'https:') return false;
    const host = url.hostname.toLowerCase();
    return trustedDownloadHosts.has(host) || host.endsWith(trustedDownloadSuffix);
  } catch {
    return false;
  }
}

export function buildUpdateStatus({ currentVersion, release }) {
  const latestVersion = String(release?.tag_name || '').replace(/^v/i, '');
  const installer = selectInstallerAsset(release?.assets);
  const checksums = selectChecksumAsset(release?.assets);
  return {
    currentVersion,
    latestVersion: latestVersion || null,
    updateAvailable: isNewerVersion(latestVersion, currentVersion) && Boolean(installer),
    releaseName: release?.name || null,
    releaseUrl: release?.html_url || null,
    publishedAt: release?.published_at || null,
    asset: installer,
    checksumAsset: checksums
  };
}
