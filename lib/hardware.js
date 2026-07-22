import { execFileSync } from 'node:child_process';

export function classifyGpuVendor(name = '') {
  const normalized = String(name).toLowerCase();
  if (normalized.includes('nvidia')) return 'nvidia';
  if (normalized.includes('amd') || normalized.includes('radeon')) return 'amd';
  if (normalized.includes('intel')) return 'intel';
  return 'other';
}

function normalizeAdapter(adapter) {
  const name = String(adapter?.Name || adapter?.name || 'GPU desconhecida').trim();
  const rawMemory = Number(adapter?.AdapterRAM ?? adapter?.adapterRam ?? 0);
  return {
    name,
    vendor: classifyGpuVendor(name),
    memoryMb: rawMemory > 0 ? Math.round(rawMemory / 1024 / 1024) : null,
    driverVersion: String(adapter?.DriverVersion || adapter?.driverVersion || '').trim() || null
  };
}

export function parseGpuAdapters(value) {
  if (!value) return [];
  try {
    const parsed = typeof value === 'string' ? JSON.parse(value) : value;
    return (Array.isArray(parsed) ? parsed : [parsed]).map(normalizeAdapter);
  } catch {
    return [];
  }
}

export function detectGpuAdapters(env = process.env) {
  if (env.TRANSCREVO_GPU_ADAPTERS_JSON) {
    return parseGpuAdapters(env.TRANSCREVO_GPU_ADAPTERS_JSON);
  }
  if (process.platform !== 'win32') return [];

  try {
    const command = [
      'Get-CimInstance Win32_VideoController',
      "Select-Object Name,AdapterRAM,DriverVersion",
      'ConvertTo-Json -Compress'
    ].join(' | ');
    const output = execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', command], {
      encoding: 'utf8',
      timeout: 8000,
      windowsHide: true
    });
    return parseGpuAdapters(output.trim());
  } catch {
    return [];
  }
}

export function selectGpuBackend({ adapters = [], cudaAvailable = false, vulkanAvailable = false }) {
  const nvidia = adapters.find((adapter) => adapter.vendor === 'nvidia');
  const amdOrIntel = adapters.find((adapter) => adapter.vendor === 'amd')
    || adapters.find((adapter) => adapter.vendor === 'intel');
  const anyAdapter = adapters[0];

  if (cudaAvailable && (nvidia || !adapters.length)) {
    return {
      available: true,
      backend: 'faster-whisper-cuda',
      device: 'cuda',
      adapter: nvidia || null,
      label: nvidia ? `NVIDIA CUDA - ${nvidia.name}` : 'NVIDIA CUDA'
    };
  }

  if (vulkanAvailable && (amdOrIntel || nvidia)) {
    const adapter = amdOrIntel || nvidia;
    return {
      available: true,
      backend: 'whisper.cpp-vulkan',
      device: 'vulkan',
      adapter,
      label: `Vulkan - ${adapter.name}`
    };
  }

  const reason = amdOrIntel && !vulkanAvailable
    ? 'O runtime Vulkan nao foi encontrado. Execute o reparo do instalador.'
    : nvidia && !cudaAvailable
      ? 'CUDA nao esta disponivel. Atualize o driver NVIDIA ou execute o reparo do instalador.'
      : 'Nenhuma GPU compativel foi detectada; o processamento usara CPU.';

  return {
    available: false,
    backend: 'faster-whisper-cpu',
    device: 'cpu',
    adapter: anyAdapter || null,
    label: 'CPU',
    reason
  };
}
