import 'dotenv/config';
import express from 'express';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { performance } from 'node:perf_hooks';
import multer from 'multer';
import sanitize from 'sanitize-filename';
import { detectGpuAdapters, selectGpuBackend } from './lib/hardware.js';
import { isAllowedOrigin, isLoopbackHostname, resolveInside } from './lib/security.js';

const app = express();
const port = Number(process.env.PORT || 3000);
const host = process.env.HOST || '127.0.0.1';
// Limite de upload: o app roda apenas em loopback e o arquivo e gravado direto em disco
// (sem passar pela memoria), entao o teto real e o espaco livre. `UPLOAD_LIMIT_MB=0`
// desativa o limite; valor ausente ou invalido cai no padrao.
const rawUploadLimitMb = String(process.env.UPLOAD_LIMIT_MB ?? '').trim();
const parsedUploadLimitMb = Number(rawUploadLimitMb);
const uploadLimitMb = rawUploadLimitMb && Number.isFinite(parsedUploadLimitMb) && parsedUploadLimitMb >= 0
  ? parsedUploadLimitMb
  : 16384;
const uploadLimitBytes = uploadLimitMb > 0 ? uploadLimitMb * 1024 * 1024 : Infinity;
const pythonBin = process.env.PYTHON_BIN || 'python';
const whisperModel = process.env.WHISPER_MODEL || 'small';
const whisperComputeType = process.env.WHISPER_COMPUTE_TYPE || 'float32';
const whisperGpuComputeType = process.env.WHISPER_GPU_COMPUTE_TYPE || 'float32';
const bundledFfmpeg = path.join(process.cwd(), 'runtime', 'ffmpeg', 'ffmpeg.exe');
const ffmpegBin = process.env.FFMPEG_BIN || (fs.existsSync(bundledFfmpeg) ? bundledFfmpeg : 'ffmpeg');
const thumbnailFrameCount = Math.max(12, Math.min(120, Number(process.env.THUMBNAIL_FRAME_COUNT || 80)));
// "Exibir mais": quantos frames novos cada clique busca no video, teto total por job,
// distancia minima entre frames (evita frames quase identicos) e por quanto tempo o video
// do job fica guardado para permitir novas extracoes (limpeza automatica).
const extraFrameBatch = Math.max(1, Math.min(120, Number(process.env.EXTRA_FRAME_BATCH || 40)));
const maxJobFrames = Math.max(thumbnailFrameCount, Number(process.env.MAX_JOB_FRAMES || 400));
const minFrameGapSeconds = 0.2;
const frameJobTtlMs = Math.max(60 * 1000, Number(process.env.FRAME_JOB_TTL_MS || 60 * 60 * 1000));
const maxFrameJobs = Math.max(1, Number(process.env.MAX_FRAME_JOBS || 10));
const availableCpus = Math.max(1, os.cpus().length);
const autoCpuThreads = Math.max(1, availableCpus - 1);
const autoNumWorkers = Math.max(1, Math.min(4, Math.floor(availableCpus / 2)));
const configuredCpuThreads = Number(process.env.WHISPER_CPU_THREADS || 0);
const configuredNumWorkers = Number(process.env.WHISPER_NUM_WORKERS || 0);
const whisperCpuThreads = configuredCpuThreads > 0 ? configuredCpuThreads : autoCpuThreads;
const whisperNumWorkers = configuredNumWorkers > 0 ? configuredNumWorkers : autoNumWorkers;
const root = process.cwd();
const whisperCppBin = process.env.WHISPER_CPP_BIN || path.join(root, 'runtime', 'whisper-vulkan', 'whisper-cli.exe');
const whisperCppModel = process.env.WHISPER_CPP_MODEL || path.join(root, 'runtime', 'models', 'ggml-small.bin');
const dataRoot = process.env.DATA_ROOT ? path.resolve(process.env.DATA_ROOT) : root;
const uploadDir = path.join(dataRoot, 'uploads');
const transcriptDir = path.join(dataRoot, 'transcripts');
const pathSeparator = process.platform === 'win32' ? ';' : ':';
const thumbnailDir = path.join(transcriptDir, 'thumbnails');

if (!isLoopbackHostname(host)) {
  throw new Error('HOST deve ser localhost, 127.0.0.1 ou ::1. O TranscrevoFacil nao aceita exposicao de rede.');
}

fs.mkdirSync(uploadDir, { recursive: true });
fs.mkdirSync(transcriptDir, { recursive: true });
fs.mkdirSync(thumbnailDir, { recursive: true });

const allowedExtensions = new Set(['.mp3', '.mp4', '.mpeg', '.mpga', '.m4a', '.wav', '.webm']);
const videoExtensions = new Set(['.mp4', '.mpeg', '.webm']);
const upload = multer({
  dest: uploadDir,
  limits: { fileSize: uploadLimitBytes },
  fileFilter: (_req, file, cb) => {
    const ext = path.extname(file.originalname).toLowerCase();
    if (!allowedExtensions.has(ext)) {
      cb(new Error('Formato nao suportado. Envie MP4, MP3, M4A, WAV, WEBM, MPEG ou MPGA.'));
      return;
    }
    cb(null, true);
  }
});

app.disable('x-powered-by');
app.use((req, res, next) => {
  res.set({
    'Content-Security-Policy': "default-src 'self'; base-uri 'none'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; img-src 'self' data: blob:; media-src 'self' blob:; object-src 'none'; script-src 'self'; style-src 'self'",
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Resource-Policy': 'same-origin',
    'Permissions-Policy': 'camera=(), geolocation=(), microphone=(), payment=(), usb=()',
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY'
  });

  if (!isLoopbackHostname(req.hostname)) {
    res.status(421).json({ error: 'Acesso permitido apenas pelo computador local.' });
    return;
  }

  if (!['GET', 'HEAD', 'OPTIONS'].includes(req.method) && !isAllowedOrigin(req.get('origin'))) {
    res.status(403).json({ error: 'Origem nao autorizada.' });
    return;
  }

  next();
});
app.use(express.json({ limit: '16kb' }));
app.use(express.static(path.join(root, 'public')));

function formatUploadLimit(mb) {
  if (mb <= 0) return 'sem limite';
  if (mb >= 1024) {
    const gb = mb / 1024;
    return `${Number.isInteger(gb) ? gb : gb.toFixed(1)} GB`;
  }
  return `${mb} MB`;
}

function timestampName(filename) {
  const base = sanitize(path.basename(filename, path.extname(filename))) || 'transcricao';
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  return `${stamp}-${base}`;
}

function asText(result) {
  if (result?.text) return result.text;
  if (Array.isArray(result?.segments)) {
    return result.segments.map((segment) => segment.text || '').join('\n').trim();
  }
  return '';
}

function formatSrtTime(seconds) {
  const safe = Math.max(0, Number(seconds) || 0);
  const h = String(Math.floor(safe / 3600)).padStart(2, '0');
  const m = String(Math.floor((safe % 3600) / 60)).padStart(2, '0');
  const s = String(Math.floor(safe % 60)).padStart(2, '0');
  const ms = String(Math.floor((safe % 1) * 1000)).padStart(3, '0');
  return `${h}:${m}:${s},${ms}`;
}

function toSrt(result) {
  const segments = Array.isArray(result?.segments) ? result.segments : [];
  if (!segments.length) return asText(result);
  return segments
    .map((segment, index) => {
      return `${index + 1}\n${formatSrtTime(segment.start)} --> ${formatSrtTime(segment.end)}\n${segment.text.trim()}`;
    })
    .join('\n\n');
}

function secondsFromMs(ms) {
  return Math.round(ms / 100) / 10;
}

function mediaDurationFromResult(result) {
  const duration = Number(result?.duration);
  if (duration > 0) return duration;

  const segments = Array.isArray(result?.segments) ? result.segments : [];
  const lastEnd = segments.reduce((max, segment) => {
    const end = Number(segment?.end);
    return end > max ? end : max;
  }, 0);

  return lastEnd > 0 ? lastEnd : null;
}

function booleanFromForm(value) {
  return value === 'on' || value === 'true' || value === '1';
}

function getPythonNvidiaBinPaths() {
  const configuredPaths = (process.env.PYTHON_NVIDIA_DLL_DIRS || '')
    .split(pathSeparator)
    .map((entry) => entry.trim())
    .filter(Boolean);

  const pythonHome = path.dirname(pythonBin);
  const sitePackagesNvidia = path.join(pythonHome, 'Lib', 'site-packages', 'nvidia');
  const detectedPaths = ['cublas', 'cuda_nvrtc', 'cudnn']
    .map((name) => path.join(sitePackagesNvidia, name, 'bin'))
    .filter((entry) => fs.existsSync(entry));

  return [...configuredPaths, ...detectedPaths];
}

function withNvidiaDllPath(env) {
  const nvidiaBinPaths = getPythonNvidiaBinPaths();
  if (!nvidiaBinPaths.length) return env;

  return {
    ...env,
    PATH: `${nvidiaBinPaths.join(pathSeparator)}${pathSeparator}${env.PATH || ''}`
  };
}

function probeCuda() {
  const probe = spawnSync(pythonBin, ['-c', 'import ctranslate2; print(ctranslate2.get_cuda_device_count())'], {
    cwd: root,
    encoding: 'utf8',
    timeout: 15000,
    windowsHide: true,
    env: withNvidiaDllPath(process.env)
  });
  return probe.status === 0 && Number(probe.stdout.trim()) > 0;
}

const gpuAdapters = detectGpuAdapters();
const cudaAvailable = probeCuda();
const vulkanAvailable = fs.existsSync(whisperCppBin) && fs.existsSync(whisperCppModel);
const detectedGpuBackend = selectGpuBackend({ adapters: gpuAdapters, cudaAvailable, vulkanAvailable });

function getWhisperRuntime(useGpu) {
  if (useGpu && detectedGpuBackend.available && detectedGpuBackend.device === 'cuda') {
    return {
      backend: detectedGpuBackend.backend,
      device: 'cuda',
      label: detectedGpuBackend.label,
      computeType: whisperGpuComputeType,
      cpuThreads: 0,
      numWorkers: Math.max(1, Math.min(2, whisperNumWorkers))
    };
  }

  if (useGpu && detectedGpuBackend.available && detectedGpuBackend.device === 'vulkan') {
    return {
      backend: detectedGpuBackend.backend,
      device: 'vulkan',
      label: detectedGpuBackend.label,
      computeType: 'vulkan',
      cpuThreads: whisperCpuThreads,
      numWorkers: 1
    };
  }

  return {
    backend: 'faster-whisper-cpu',
    device: 'cpu',
    label: 'CPU',
    computeType: whisperComputeType,
    cpuThreads: whisperCpuThreads,
    numWorkers: whisperNumWorkers,
    fallbackReason: useGpu ? detectedGpuBackend.reason : null
  };
}

function runFasterWhisperTranscription({ filePath, language, task, runtime }) {
  return new Promise((resolve, reject) => {
    const args = [
      path.join(root, 'scripts', 'transcribe_local.py'),
      '--file',
      filePath,
      '--model',
      whisperModel,
      '--device',
      runtime.device,
      '--compute-type',
      runtime.computeType,
      '--cpu-threads',
      String(runtime.cpuThreads),
      '--num-workers',
      String(runtime.numWorkers),
      '--task',
      task || 'transcribe'
    ];

    if (language) {
      args.push('--language', language);
    }

    const child = spawn(pythonBin, args, {
      cwd: root,
      env: withNvidiaDllPath({
        ...process.env,
        PYTHONIOENCODING: 'utf-8',
        PYTHONUTF8: '1'
      }),
      windowsHide: true
    });
    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.on('error', (error) => {
      reject(new Error(`Nao consegui iniciar o Python local: ${error.message}`));
    });
    child.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(stderr.trim() || `Transcricao local falhou com codigo ${code}.`));
        return;
      }
      try {
        resolve(JSON.parse(stdout));
      } catch {
        reject(new Error('O transcritor local retornou uma resposta invalida.'));
      }
    });
  });
}

function normalizeWhisperCppResult(payload) {
  const transcription = Array.isArray(payload?.transcription) ? payload.transcription : [];
  const segments = transcription.map((segment, index) => ({
    id: index,
    start: Math.max(0, Number(segment?.offsets?.from || 0) / 1000),
    end: Math.max(0, Number(segment?.offsets?.to || 0) / 1000),
    text: String(segment?.text || '').trim()
  }));
  const duration = segments.reduce((maximum, segment) => Math.max(maximum, segment.end), 0);
  return {
    text: segments.map((segment) => segment.text).filter(Boolean).join('\n'),
    language: payload?.result?.language || null,
    language_probability: null,
    duration,
    segments
  };
}

async function runVulkanTranscription({ filePath, language, task, runtime }) {
  const temporaryId = crypto.randomUUID();
  const wavPath = path.join(uploadDir, `${temporaryId}.whisper.wav`);
  const outputBase = path.join(uploadDir, `${temporaryId}.whisper-result`);
  const jsonPath = `${outputBase}.json`;

  try {
    await runFfmpeg(['-hide_banner', '-loglevel', 'error', '-i', filePath, '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', '-y', wavPath]);
    await new Promise((resolve, reject) => {
      const args = [
        '-m', whisperCppModel,
        '-f', wavPath,
        '-l', language || 'auto',
        '-t', String(Math.max(1, runtime.cpuThreads)),
        '-bs', '5',
        '-ojf',
        '-of', outputBase,
        '-np'
      ];
      if (task === 'translate') args.push('-tr');

      const child = spawn(whisperCppBin, args, { cwd: root, windowsHide: true });
      let stderr = '';
      child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
      child.on('error', (error) => reject(new Error(`Nao consegui iniciar o runtime Vulkan: ${error.message}`)));
      child.on('close', (code) => {
        if (code !== 0) {
          reject(new Error(stderr.trim() || `O runtime Vulkan falhou com codigo ${code}.`));
          return;
        }
        resolve();
      });
    });

    const payload = JSON.parse(await fsp.readFile(jsonPath, 'utf8'));
    return normalizeWhisperCppResult(payload);
  } finally {
    await Promise.all([
      fsp.rm(wavPath, { force: true }),
      fsp.rm(jsonPath, { force: true })
    ]);
  }
}

async function runTranscription({ filePath, language, task, useGpu }) {
  const requestedRuntime = getWhisperRuntime(useGpu);
  try {
    const result = requestedRuntime.device === 'vulkan'
      ? await runVulkanTranscription({ filePath, language, task, runtime: requestedRuntime })
      : await runFasterWhisperTranscription({ filePath, language, task, runtime: requestedRuntime });
    return { result, runtime: requestedRuntime };
  } catch (error) {
    if (!useGpu || requestedRuntime.device === 'cpu') throw error;

    const cpuRuntime = getWhisperRuntime(false);
    const result = await runFasterWhisperTranscription({ filePath, language, task, runtime: cpuRuntime });
    return {
      result,
      runtime: {
        ...cpuRuntime,
        fallbackReason: `A aceleracao por ${requestedRuntime.label} falhou (${error.message}). A transcricao foi refeita automaticamente pela CPU.`
      }
    };
  }
}

function runFfmpeg(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(ffmpegBin, args, { cwd: root, windowsHide: true });
    let stderr = '';

    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.on('error', (error) => {
      reject(new Error(`Nao consegui iniciar o FFmpeg: ${error.message}`));
    });
    child.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(stderr.trim() || `FFmpeg falhou com codigo ${code}.`));
        return;
      }
      resolve();
    });
  });
}

// Le a duracao do arquivo direto da saida do proprio ffmpeg (linha "Duration: HH:MM:SS.xx").
// Evita depender do ffprobe, que nao e empacotado pelo instalador. Usado no modo "Apenas Frames",
// onde nao ha resultado de transcricao para extrair a duracao. Nunca rejeita: retorna null se falhar.
function probeMediaDurationSeconds(filePath) {
  return new Promise((resolve) => {
    const child = spawn(ffmpegBin, ['-hide_banner', '-i', filePath], { cwd: root, windowsHide: true });
    let stderr = '';

    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.on('error', () => resolve(null));
    child.on('close', () => {
      const match = stderr.match(/Duration:\s*(\d+):(\d{2}):(\d{2}(?:\.\d+)?)/);
      if (!match) {
        resolve(null);
        return;
      }
      const totalSeconds = Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
      resolve(Number.isFinite(totalSeconds) && totalSeconds > 0 ? totalSeconds : null);
    });
  });
}

function formatFrameLabel(seconds, index) {
  const safeSeconds = Math.max(0, Number(seconds) || 0);
  const m = Math.floor(safeSeconds / 60);
  const s = Math.floor(safeSeconds % 60);
  return `Frame ${index + 1} - ${m}:${String(s).padStart(2, '0')}`;
}

async function listThumbnailFiles(dir, publicBase, frameTimes = []) {
  const files = await fsp.readdir(dir).catch(() => []);
  return files
    .filter((file) => file.toLowerCase().endsWith('.png'))
    .sort()
    .map((file, index) => ({
      url: `${publicBase}/${file}`,
      label: frameTimes[index] == null ? `Frame ${index + 1}` : formatFrameLabel(frameTimes[index], index)
    }));
}

function buildFrameTimes(durationSeconds, count) {
  const duration = Number(durationSeconds) > 0 ? Number(durationSeconds) : 120;
  const safeCount = Math.max(1, count);
  const startPadding = Math.min(8, Math.max(0.5, duration * 0.015));
  const endPadding = Math.min(8, Math.max(0.5, duration * 0.015));
  const span = Math.max(1, duration - startPadding - endPadding);

  return Array.from({ length: safeCount }, (_value, index) => {
    const point = safeCount === 1 ? 0.5 : index / (safeCount - 1);
    return Math.max(0.5, Math.min(duration - 0.5, startPadding + span * point));
  });
}

async function generateTimelineFrames({ filePath, outputDir, publicBase, durationSeconds, count }) {
  const frameTimes = buildFrameTimes(durationSeconds, count);

  for (const [index, timestamp] of frameTimes.entries()) {
    const target = path.join(outputDir, `frame-${String(index + 1).padStart(2, '0')}.png`);
    await runFfmpeg([
      '-hide_banner',
      '-loglevel',
      'error',
      '-ss',
      String(timestamp),
      '-i',
      filePath,
      '-frames:v',
      '1',
      '-y',
      target
    ]);
  }

  return listThumbnailFiles(outputDir, publicBase, frameTimes);
}

async function generateGoodFrames({ filePath, originalExt, name, durationSeconds }) {
  if (!videoExtensions.has(originalExt)) {
    return { frames: [], error: null };
  }

  const safeName = sanitize(name) || crypto.randomUUID();
  const outputDir = path.join(thumbnailDir, safeName);
  const publicBase = `/api/thumbnails/${safeName}`;
  await fsp.rm(outputDir, { recursive: true, force: true });
  await fsp.mkdir(outputDir, { recursive: true });

  try {
    await runFfmpeg([
      '-hide_banner',
      '-loglevel',
      'error',
      '-i',
      filePath,
      '-vf',
      "select='gt(scene,0.18)'",
      '-vsync',
      'vfr',
      '-frames:v',
      String(thumbnailFrameCount),
      '-y',
      path.join(outputDir, 'frame-%02d.png')
    ]);

    const sceneFrames = await listThumbnailFiles(outputDir, publicBase);
    if (sceneFrames.length >= thumbnailFrameCount) {
      return { frames: sceneFrames, error: null };
    }

    await fsp.rm(outputDir, { recursive: true, force: true });
    await fsp.mkdir(outputDir, { recursive: true });
    const timelineFrames = await generateTimelineFrames({
      filePath,
      outputDir,
      publicBase,
      durationSeconds,
      count: thumbnailFrameCount
    });
    return { frames: timelineFrames, error: null };
  } catch (error) {
    await fsp.rm(outputDir, { recursive: true, force: true });
    return { frames: [], error: error.message };
  }
}

// ----- Jobs de frames: guardam o video para permitir "Exibir mais" (novos frames sob demanda) -----

function jobManifestPath(jobId) {
  return path.join(thumbnailDir, jobId, 'job.json');
}

async function readJobManifest(jobId) {
  try {
    return JSON.parse(await fsp.readFile(jobManifestPath(jobId), 'utf8'));
  } catch {
    return null;
  }
}

async function writeJobManifest(jobId, manifest) {
  await fsp.writeFile(jobManifestPath(jobId), JSON.stringify(manifest, null, 2), 'utf8');
}

async function removeFrameJob(jobId) {
  const manifest = await readJobManifest(jobId);
  if (manifest?.sourceFile) {
    await fsp.rm(path.join(uploadDir, path.basename(manifest.sourceFile)), { force: true }).catch(() => {});
  }
  await fsp.rm(path.join(thumbnailDir, jobId), { recursive: true, force: true }).catch(() => {});
}

// Remove jobs expirados (por TTL) e mantem apenas os mais recentes, liberando o disco.
async function sweepFrameJobs() {
  const now = Date.now();
  const entries = await fsp.readdir(thumbnailDir, { withFileTypes: true }).catch(() => []);
  const jobs = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const stat = await fsp.stat(jobManifestPath(entry.name)).catch(() => null);
    if (!stat) continue; // diretorio de thumbnails sem manifesto: nao e um job com "Exibir mais"
    jobs.push({ id: entry.name, mtimeMs: stat.mtimeMs });
  }

  const alive = [];
  for (const job of jobs) {
    if (now - job.mtimeMs > frameJobTtlMs) {
      await removeFrameJob(job.id);
    } else {
      alive.push(job);
    }
  }

  alive.sort((a, b) => b.mtimeMs - a.mtimeMs);
  for (const job of alive.slice(maxFrameJobs)) {
    await removeFrameJob(job.id);
  }
}

function canExtractMore(durationSeconds, usedTimes) {
  if (usedTimes.length >= maxJobFrames) return false;
  const duration = Number(durationSeconds) > 0 ? Number(durationSeconds) : 120;
  const anchors = [0, ...usedTimes.filter((t) => t > 0 && t < duration), duration].sort((a, b) => a - b);
  let maxGap = 0;
  for (let i = 0; i < anchors.length - 1; i += 1) {
    maxGap = Math.max(maxGap, anchors[i + 1] - anchors[i]);
  }
  return maxGap >= minFrameGapSeconds * 2;
}

// Escolhe novos instantes dividindo sempre o maior intervalo livre: cada frame extra cai
// no maior "buraco" da linha do tempo, densificando sem repetir os instantes ja usados.
function nextExtraTimes(durationSeconds, usedTimes, count) {
  const duration = Number(durationSeconds) > 0 ? Number(durationSeconds) : 120;
  const anchors = [0, ...usedTimes.filter((t) => t > 0 && t < duration), duration].sort((a, b) => a - b);
  const result = [];

  while (result.length < count && usedTimes.length + result.length < maxJobFrames) {
    let bestGap = -1;
    let bestPos = -1;
    for (let i = 0; i < anchors.length - 1; i += 1) {
      const gap = anchors[i + 1] - anchors[i];
      if (gap > bestGap) {
        bestGap = gap;
        bestPos = i;
      }
    }
    if (bestGap < minFrameGapSeconds * 2) break;
    const mid = (anchors[bestPos] + anchors[bestPos + 1]) / 2;
    result.push(Math.min(duration - 0.1, Math.max(0.1, mid)));
    anchors.splice(bestPos + 1, 0, mid);
  }

  // Ordena por tempo para que cada lote de "Exibir mais" apareca como uma passada
  // cronologica (mais densa) pela linha do tempo, em vez de instantes fora de ordem.
  return result.sort((a, b) => a - b);
}

async function extractExtraFrames({ sourcePath, jobDir, publicBase, startCounter, times }) {
  const created = [];
  for (const [offset, timestamp] of times.entries()) {
    const globalIndex = startCounter + offset;
    const file = `extra-${String(globalIndex + 1).padStart(4, '0')}.png`;
    await runFfmpeg([
      '-hide_banner',
      '-loglevel',
      'error',
      '-ss',
      String(timestamp),
      '-i',
      sourcePath,
      '-frames:v',
      '1',
      '-y',
      path.join(jobDir, file)
    ]);
    created.push({ url: `${publicBase}/${file}`, label: formatFrameLabel(timestamp, globalIndex) });
  }
  return created;
}

// Move o video para o armazenamento do job, extrai o lote inicial de frames e grava o manifesto,
// para que "Exibir mais" possa voltar ao mesmo video e amostrar novos instantes depois.
async function createFrameJob({ sourcePath, originalExt, durationSeconds }) {
  if (!videoExtensions.has(originalExt)) {
    return { job: null, frames: [], error: null, hasMore: false };
  }

  await sweepFrameJobs().catch(() => {});
  const jobId = crypto.randomUUID();
  const jobDir = path.join(thumbnailDir, jobId);
  const jobSourcePath = path.join(uploadDir, `job-${jobId}${originalExt}`);
  await fsp.rename(sourcePath, jobSourcePath);

  const duration = Number(durationSeconds) > 0 ? Number(durationSeconds) : await probeMediaDurationSeconds(jobSourcePath);
  const { frames, error } = await generateGoodFrames({
    filePath: jobSourcePath,
    originalExt,
    name: jobId,
    durationSeconds: duration
  });

  if (!frames.length) {
    await fsp.rm(jobSourcePath, { force: true }).catch(() => {});
    await fsp.rm(jobDir, { recursive: true, force: true }).catch(() => {});
    return { job: null, frames: [], error, hasMore: false };
  }

  const usedTimes = buildFrameTimes(duration, frames.length);
  await writeJobManifest(jobId, {
    sourceFile: path.basename(jobSourcePath),
    ext: originalExt,
    duration: Number(duration) > 0 ? Number(duration) : null,
    usedTimes,
    frameCounter: frames.length,
    createdAt: Date.now()
  });

  return { job: jobId, frames, error, hasMore: canExtractMore(duration, usedTimes) };
}

app.get('/api/health', (_req, res) => {
  const cpuRuntime = getWhisperRuntime(false);
  res.json({
    ok: true,
    app: 'transcrevofacil',
    version: '0.2.4',
    engine: 'local-faster-whisper',
    model: whisperModel,
    device: cpuRuntime.device,
    computeType: cpuRuntime.computeType,
    gpuComputeType: whisperGpuComputeType,
    cpuThreads: cpuRuntime.cpuThreads,
    numWorkers: cpuRuntime.numWorkers,
    availableCpus,
    graphicsAdapters: gpuAdapters,
    acceleration: detectedGpuBackend,
    cudaAvailable,
    vulkanAvailable,
    uploadLimitMb,
    uploadLimitLabel: formatUploadLimit(uploadLimitMb),
    supportedFormats: [...allowedExtensions].map((ext) => ext.slice(1))
  });
});

app.post('/api/transcribe', upload.single('media'), async (req, res, next) => {
  const file = req.file;
  if (!file) {
    res.status(400).json({ error: 'Envie um arquivo de audio ou video.' });
    return;
  }

  let stableFilePath = file.path;
  try {
    const supportedLanguages = new Set(['auto', 'pt', 'en', 'es']);
    const supportedTasks = new Set(['transcribe', 'translate']);
    const requestedLanguage = String(req.body.language || 'pt').toLowerCase();
    const language = requestedLanguage === 'auto' ? null : requestedLanguage;
    const task = String(req.body.task || 'transcribe').toLowerCase();
    if (!supportedLanguages.has(requestedLanguage) || !supportedTasks.has(task)) {
      res.status(400).json({ error: 'Idioma ou tarefa de transcricao invalida.' });
      return;
    }
    const useGpu = booleanFromForm(req.body.useGpu);
    // Modo "Apenas Transcricao" envia includeFrames=false para pular a extracao de frames.
    // Ausente => true, preservando o comportamento de "Transcricao + Frames".
    const includeFrames = req.body.includeFrames == null ? true : booleanFromForm(req.body.includeFrames);
    const originalExt = path.extname(file.originalname).toLowerCase();
    stableFilePath = path.join(uploadDir, `${file.filename}${originalExt}`);
    fs.renameSync(file.path, stableFilePath);

    const transcriptionStartedAt = performance.now();
    const transcription = await runTranscription({
      filePath: stableFilePath,
      language,
      task,
      useGpu
    });
    const { result, runtime } = transcription;
    const transcriptionSeconds = Math.max(0.1, secondsFromMs(performance.now() - transcriptionStartedAt));
    const text = asText(result);
    const srtText = toSrt(result);
    const mediaDurationSeconds = mediaDurationFromResult(result);
    const name = timestampName(file.originalname);
    // Com frames, cria um job que guarda o video para permitir "Exibir mais" depois.
    const frameJob = includeFrames
      ? await createFrameJob({ sourcePath: stableFilePath, originalExt, durationSeconds: mediaDurationSeconds })
      : { job: null, frames: [], error: null, hasMore: false };
    const txtPath = path.join(transcriptDir, `${name}.txt`);
    const jsonPath = path.join(transcriptDir, `${name}.json`);
    const srtPath = path.join(transcriptDir, `${name}.srt`);

    await Promise.all([
      fsp.writeFile(txtPath, text, 'utf8'),
      fsp.writeFile(jsonPath, JSON.stringify(result, null, 2), 'utf8'),
      fsp.writeFile(srtPath, srtText, 'utf8')
    ]);

    // Tempo total de processamento no servidor: transcricao + extracao de frames + gravacao.
    const processingSeconds = Math.max(0.1, secondsFromMs(performance.now() - transcriptionStartedAt));

    res.json({
      id: crypto.randomUUID(),
      filename: file.originalname,
      engine: runtime.backend,
      model: whisperModel,
      device: runtime.device,
      runtimeLabel: runtime.label,
      fallbackReason: runtime.fallbackReason || null,
      transcriptionSeconds,
      processingSeconds,
      mediaDurationSeconds,
      text,
      srtText,
      segments: Array.isArray(result.segments) ? result.segments : [],
      downloads: {
        txt: `/api/download/${path.basename(txtPath)}`,
        json: `/api/download/${path.basename(jsonPath)}`,
        srt: `/api/download/${path.basename(srtPath)}`
      },
      job: frameJob.job,
      hasMore: frameJob.hasMore,
      thumbnails: frameJob.frames,
      thumbnailError: frameJob.error
    });
  } catch (error) {
    next(error);
  } finally {
    // createFrameJob move o video para o armazenamento do job; aqui so limpamos o upload temporario.
    await Promise.all([
      fsp.rm(file.path, { force: true }).catch(() => {}),
      fsp.rm(stableFilePath, { force: true }).catch(() => {})
    ]);
  }
});

app.post('/api/frames', upload.single('media'), async (req, res, next) => {
  const file = req.file;
  if (!file) {
    res.status(400).json({ error: 'Envie um arquivo de audio ou video.' });
    return;
  }

  let stableFilePath = file.path;
  try {
    const originalExt = path.extname(file.originalname).toLowerCase();
    stableFilePath = path.join(uploadDir, `${file.filename}${originalExt}`);
    fs.renameSync(file.path, stableFilePath);

    const processingStartedAt = performance.now();
    const mediaDurationSeconds = await probeMediaDurationSeconds(stableFilePath);
    const frameJob = await createFrameJob({ sourcePath: stableFilePath, originalExt, durationSeconds: mediaDurationSeconds });
    // Tempo total de processamento no servidor: leitura da duracao + extracao dos frames.
    const processingSeconds = Math.max(0.1, secondsFromMs(performance.now() - processingStartedAt));

    res.json({
      id: crypto.randomUUID(),
      filename: file.originalname,
      framesOnly: true,
      processingSeconds,
      mediaDurationSeconds,
      job: frameJob.job,
      hasMore: frameJob.hasMore,
      thumbnails: frameJob.frames,
      thumbnailError: frameJob.error
    });
  } catch (error) {
    next(error);
  } finally {
    // createFrameJob move o video para o armazenamento do job; aqui so limpamos o upload temporario.
    await Promise.all([
      fsp.rm(file.path, { force: true }).catch(() => {}),
      fsp.rm(stableFilePath, { force: true }).catch(() => {})
    ]);
  }
});

app.post('/api/frames/:job/more', async (req, res, next) => {
  try {
    const jobId = sanitize(req.params.job);
    const jobDir = jobId ? resolveInside(thumbnailDir, jobId) : null;
    if (!jobId || !jobDir) {
      res.status(404).json({ error: 'Job de frames invalido.' });
      return;
    }

    const manifest = await readJobManifest(jobId);
    if (!manifest) {
      res.status(404).json({ error: 'Nao encontrei este conjunto de frames. Envie o video novamente para extrair mais.' });
      return;
    }

    const jobSourcePath = path.join(uploadDir, path.basename(manifest.sourceFile || ''));
    if (!manifest.sourceFile || !fs.existsSync(jobSourcePath)) {
      await removeFrameJob(jobId).catch(() => {});
      res.status(410).json({ error: 'O video expirou. Envie novamente para extrair mais frames.' });
      return;
    }

    const times = nextExtraTimes(manifest.duration, manifest.usedTimes, extraFrameBatch);
    if (!times.length) {
      res.json({ thumbnails: [], hasMore: false });
      return;
    }

    const newFrames = await extractExtraFrames({
      sourcePath: jobSourcePath,
      jobDir,
      publicBase: `/api/thumbnails/${jobId}`,
      startCounter: manifest.frameCounter,
      times
    });

    manifest.usedTimes = [...manifest.usedTimes, ...times];
    manifest.frameCounter += newFrames.length;
    manifest.updatedAt = Date.now();
    await writeJobManifest(jobId, manifest);

    res.json({ thumbnails: newFrames, hasMore: canExtractMore(manifest.duration, manifest.usedTimes) });
  } catch (error) {
    next(error);
  }
});

app.get('/api/download/:file', (req, res) => {
  const filename = sanitize(req.params.file);
  const target = resolveInside(transcriptDir, filename);
  const allowedDownloadExtensions = new Set(['.txt', '.json', '.srt']);
  if (!filename || !target || !allowedDownloadExtensions.has(path.extname(filename).toLowerCase()) || !fs.existsSync(target)) {
    res.status(404).json({ error: 'Arquivo nao encontrado.' });
    return;
  }
  res.download(target);
});

app.get('/api/thumbnails/:job/:file', (req, res) => {
  const job = sanitize(req.params.job);
  const filename = sanitize(req.params.file);
  const resolvedTarget = resolveInside(thumbnailDir, job, filename);

  if (!job || !filename || !resolvedTarget || path.extname(filename).toLowerCase() !== '.png' || !fs.existsSync(resolvedTarget)) {
    res.status(404).json({ error: 'Thumbnail nao encontrada.' });
    return;
  }

  res.sendFile(resolvedTarget);
});

app.use((error, _req, res, _next) => {
  if (error instanceof multer.MulterError && error.code === 'LIMIT_FILE_SIZE') {
    res.status(413).json({
      error: `Arquivo maior que ${formatUploadLimit(uploadLimitMb)}. Ajuste UPLOAD_LIMIT_MB no arquivo .env (0 remove o limite) e reinicie o TranscrevoFacil.`
    });
    return;
  }
  res.status(500).json({ error: error.message || 'Nao foi possivel transcrever agora.' });
});

app.listen(port, host, () => {
  console.log(`TranscrevoFácil rodando em http://${host}:${port}`);
  // Limpa jobs de frames antigos deixados por execucoes anteriores.
  sweepFrameJobs().catch(() => {});
});
