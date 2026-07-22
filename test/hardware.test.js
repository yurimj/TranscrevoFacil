import test from 'node:test';
import assert from 'node:assert/strict';
import { parseGpuAdapters, selectGpuBackend } from '../lib/hardware.js';

test('prefere CUDA para NVIDIA', () => {
  const adapters = parseGpuAdapters(JSON.stringify({ Name: 'NVIDIA GeForce RTX 3050 Ti', AdapterRAM: 4294967296 }));
  assert.equal(selectGpuBackend({ adapters, cudaAvailable: true, vulkanAvailable: true }).device, 'cuda');
});

test('usa Vulkan para AMD', () => {
  const adapters = parseGpuAdapters(JSON.stringify({ Name: 'AMD Radeon RX 7600', AdapterRAM: 4294967296 }));
  assert.equal(selectGpuBackend({ adapters, cudaAvailable: false, vulkanAvailable: true }).device, 'vulkan');
});

test('usa Vulkan para Intel', () => {
  const adapters = parseGpuAdapters(JSON.stringify({ Name: 'Intel Arc A750', AdapterRAM: 4294967296 }));
  assert.equal(selectGpuBackend({ adapters, cudaAvailable: false, vulkanAvailable: true }).device, 'vulkan');
});

test('usa Vulkan para NVIDIA quando CUDA nao esta pronta', () => {
  const adapters = parseGpuAdapters(JSON.stringify({ Name: 'NVIDIA GeForce GTX 1050', AdapterRAM: 2147483648 }));
  assert.equal(selectGpuBackend({ adapters, cudaAvailable: false, vulkanAvailable: true }).device, 'vulkan');
});

test('mantem CPU quando o runtime da GPU nao existe', () => {
  const adapters = parseGpuAdapters(JSON.stringify({ Name: 'AMD Radeon Graphics' }));
  const result = selectGpuBackend({ adapters, cudaAvailable: false, vulkanAvailable: false });
  assert.equal(result.available, false);
  assert.equal(result.device, 'cpu');
  assert.match(result.reason, /Vulkan/);
});

test('nao oferece Vulkan para adaptador basico desconhecido', () => {
  const adapters = parseGpuAdapters(JSON.stringify({ Name: 'Microsoft Basic Display Adapter' }));
  const result = selectGpuBackend({ adapters, cudaAvailable: false, vulkanAvailable: true });
  assert.equal(result.available, false);
  assert.equal(result.device, 'cpu');
});
