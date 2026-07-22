import path from 'node:path';

const loopbackHostnames = new Set(['127.0.0.1', 'localhost', '::1']);

export function normalizeHostname(value = '') {
  return String(value).trim().toLowerCase().replace(/^\[|\]$/g, '');
}

export function isLoopbackHostname(value = '') {
  return loopbackHostnames.has(normalizeHostname(value));
}

export function isAllowedOrigin(value = '') {
  if (!value) return true;
  try {
    return isLoopbackHostname(new URL(value).hostname);
  } catch {
    return false;
  }
}

export function resolveInside(root, ...segments) {
  const resolvedRoot = path.resolve(root);
  const resolvedTarget = path.resolve(resolvedRoot, ...segments);
  const relative = path.relative(resolvedRoot, resolvedTarget);
  if (!relative || (!relative.startsWith('..') && !path.isAbsolute(relative))) {
    return resolvedTarget;
  }
  return null;
}
