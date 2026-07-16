import 'dotenv/config';
import express from 'express';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import multer from 'multer';
import sanitize from 'sanitize-filename';

const app = express();
const port = Number(process.env.PORT || 3000);
const uploadLimitMb = Number(process.env.UPLOAD_LIMIT_MB || 2048);
const pythonBin = process.env.PYTHON_BIN || 'python';
const whisperModel = process.env.WHISPER_MODEL || 'small';
const whisperDevice = process.env.WHISPER_DEVICE || 'cpu';
const whisperComputeType = process.env.WHISPER_COMPUTE_TYPE || 'int8';
const whisperCpuThreads = Number(process.env.WHISPER_CPU_THREADS || 0);
const whisperNumWorkers = Number(process.env.WHISPER_NUM_WORKERS || 1);
const root = process.cwd();
const uploadDir = path.join(root, 'uploads');
const transcriptDir = path.join(root, 'transcripts');

fs.mkdirSync(uploadDir, { recursive: true });
fs.mkdirSync(transcriptDir, { recursive: true });

const allowedExtensions = new Set(['.mp3', '.mp4', '.mpeg', '.mpga', '.m4a', '.wav', '.webm']);
const upload = multer({
  dest: uploadDir,
  limits: { fileSize: uploadLimitMb * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    const ext = path.extname(file.originalname).toLowerCase();
    if (!allowedExtensions.has(ext)) {
      cb(new Error('Formato nao suportado. Envie MP4, MP3, M4A, WAV, WEBM, MPEG ou MPGA.'));
      return;
    }
    cb(null, true);
  }
});

app.use(express.json());
app.use(express.static(path.join(root, 'public')));

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

function runLocalTranscription({ filePath, language, task }) {
  return new Promise((resolve, reject) => {
    const args = [
      path.join(root, 'scripts', 'transcribe_local.py'),
      '--file',
      filePath,
      '--model',
      whisperModel,
      '--device',
      whisperDevice,
      '--compute-type',
      whisperComputeType,
      '--cpu-threads',
      String(whisperCpuThreads),
      '--num-workers',
      String(whisperNumWorkers),
      '--task',
      task || 'transcribe'
    ];

    if (language) {
      args.push('--language', language);
    }

    const child = spawn(pythonBin, args, {
      cwd: root,
      env: {
        ...process.env,
        PYTHONIOENCODING: 'utf-8',
        PYTHONUTF8: '1'
      },
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

app.get('/api/health', (_req, res) => {
  res.json({
    ok: true,
    engine: 'local-faster-whisper',
    model: whisperModel,
    device: whisperDevice,
    computeType: whisperComputeType,
    cpuThreads: whisperCpuThreads,
    numWorkers: whisperNumWorkers,
    uploadLimitMb,
    supportedFormats: [...allowedExtensions].map((ext) => ext.slice(1))
  });
});

app.post('/api/transcribe', upload.single('media'), async (req, res, next) => {
  const file = req.file;
  if (!file) {
    res.status(400).json({ error: 'Envie um arquivo de audio ou video.' });
    return;
  }

  try {
    const language = req.body.language || 'pt';
    const task = req.body.task || 'transcribe';
    const originalExt = path.extname(file.originalname).toLowerCase();
    const stableFilePath = path.join(uploadDir, `${file.filename}${originalExt}`);
    fs.renameSync(file.path, stableFilePath);

    const result = await runLocalTranscription({
      filePath: stableFilePath,
      language,
      task
    });
    const text = asText(result);
    const name = timestampName(file.originalname);
    const txtPath = path.join(transcriptDir, `${name}.txt`);
    const jsonPath = path.join(transcriptDir, `${name}.json`);
    const srtPath = path.join(transcriptDir, `${name}.srt`);

    fs.writeFileSync(txtPath, text, 'utf8');
    fs.writeFileSync(jsonPath, JSON.stringify(result, null, 2), 'utf8');
    fs.writeFileSync(srtPath, toSrt(result), 'utf8');

    res.json({
      id: crypto.randomUUID(),
      filename: file.originalname,
      engine: 'local-faster-whisper',
      model: whisperModel,
      text,
      downloads: {
        txt: `/api/download/${path.basename(txtPath)}`,
        json: `/api/download/${path.basename(jsonPath)}`,
        srt: `/api/download/${path.basename(srtPath)}`
      }
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/download/:file', (req, res) => {
  const filename = sanitize(req.params.file);
  const target = path.join(transcriptDir, filename);
  if (!target.startsWith(transcriptDir) || !fs.existsSync(target)) {
    res.status(404).json({ error: 'Arquivo nao encontrado.' });
    return;
  }
  res.download(target);
});

app.use((error, _req, res, _next) => {
  if (error instanceof multer.MulterError && error.code === 'LIMIT_FILE_SIZE') {
    res.status(413).json({ error: `Arquivo maior que ${uploadLimitMb} MB.` });
    return;
  }
  res.status(500).json({ error: error.message || 'Nao foi possivel transcrever agora.' });
});

app.listen(port, () => {
  console.log(`Transcrevo Facil rodando em http://localhost:${port}`);
});
