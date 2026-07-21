import test from 'node:test';
import assert from 'node:assert/strict';
import { isAllowedOrigin, isLoopbackHostname, normalizeHostname, resolveInside } from '../lib/security.js';

test('aceita apenas nomes de host locais', () => {
  assert.equal(isLoopbackHostname('localhost'), true);
  assert.equal(isLoopbackHostname('127.0.0.1'), true);
  assert.equal(isLoopbackHostname('[::1]'), true);
  assert.equal(isLoopbackHostname('transcrevofacil.exemplo'), false);
});

test('normaliza hostname IPv6 local', () => {
  assert.equal(normalizeHostname('[::1]'), '::1');
});

test('bloqueia origens externas e malformadas', () => {
  assert.equal(isAllowedOrigin('http://localhost:3000'), true);
  assert.equal(isAllowedOrigin('http://127.0.0.1:4123'), true);
  assert.equal(isAllowedOrigin('https://exemplo.com'), false);
  assert.equal(isAllowedOrigin('nao-e-url'), false);
  assert.equal(isAllowedOrigin(''), true);
});

test('resolve apenas caminhos contidos no diretorio raiz', () => {
  const root = 'C:\\dados\\transcricoes';
  assert.equal(resolveInside(root, 'arquivo.txt'), pathForPlatform(root, 'arquivo.txt'));
  assert.equal(resolveInside(root, '..', 'segredo.txt'), null);
});

function pathForPlatform(root, file) {
  return resolveInside(root, file);
}
