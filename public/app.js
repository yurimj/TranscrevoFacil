const form = document.querySelector('#transcribeForm');
const media = document.querySelector('#media');
const fileName = document.querySelector('#fileName');
const output = document.querySelector('#output');
const actions = document.querySelector('#actions');
const submitButton = document.querySelector('#submitButton');
const transcribeOnlyButton = document.querySelector('#transcribeOnlyButton');
const framesOnlyButton = document.querySelector('#framesOnlyButton');
const apiStatus = document.querySelector('#apiStatus');
const metrics = document.querySelector('#metrics');
const transcriptionTime = document.querySelector('#transcriptionTime');
const mediaDuration = document.querySelector('#mediaDuration');
const runtimeUsed = document.querySelector('#runtimeUsed');
const useGpu = document.querySelector('#useGpu');
const gpuOptionLabel = document.querySelector('#gpuOptionLabel');
const thumbnailSection = document.querySelector('#thumbnailSection');
const thumbnailGrid = document.querySelector('#thumbnailGrid');
const thumbnailCount = document.querySelector('#thumbnailCount');
const thumbnailNote = document.querySelector('#thumbnailNote');
const thumbnailViewer = document.querySelector('#thumbnailViewer');
const thumbnailViewerImage = document.querySelector('#thumbnailViewerImage');
const thumbnailViewerLabel = document.querySelector('#thumbnailViewerLabel');
const thumbnailOpenOriginal = document.querySelector('#thumbnailOpenOriginal');
const thumbnailPrev = document.querySelector('#thumbnailPrev');
const thumbnailNext = document.querySelector('#thumbnailNext');
const thumbnailShowMore = document.querySelector('#thumbnailShowMore');
let currentThumbnails = [];
let currentThumbnailIndex = 0;
let currentJob = null;
let currentHasMore = false;

function formatDuration(seconds) {
  const parsedSeconds = Number(seconds);
  if (!Number.isFinite(parsedSeconds) || parsedSeconds <= 0) return null;
  const safeSeconds = Math.max(0, parsedSeconds);
  const rounded = Math.round(safeSeconds);
  const h = Math.floor(rounded / 3600);
  const m = Math.floor((rounded % 3600) / 60);
  const s = rounded % 60;

  if (h > 0) return `${h}h ${String(m).padStart(2, '0')}min ${String(s).padStart(2, '0')}s`;
  if (m > 0) return `${m}min ${String(s).padStart(2, '0')}s`;
  return `${safeSeconds.toFixed(safeSeconds < 10 ? 1 : 0)}s`;
}

function durationFromSegments(segments) {
  if (!Array.isArray(segments)) return null;
  return segments.reduce((max, segment) => {
    const end = Number(segment?.end);
    return end > max ? end : max;
  }, 0) || null;
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function resetThumbnails() {
  thumbnailSection.hidden = true;
  thumbnailGrid.innerHTML = '';
  thumbnailCount.textContent = '';
  thumbnailNote.textContent = '';
  thumbnailViewer.hidden = true;
  thumbnailViewerImage.removeAttribute('src');
  thumbnailOpenOriginal.href = '#';
  thumbnailShowMore.hidden = true;
  currentThumbnails = [];
  currentThumbnailIndex = 0;
  currentJob = null;
  currentHasMore = false;
}

function thumbnailCardHtml(thumbnail, index) {
  const label = escapeHtml(thumbnail.label || `Frame ${index + 1}`);
  const url = escapeHtml(thumbnail.url);
  return `
        <button class="thumbnail-card" type="button" data-thumbnail-index="${index}">
          <img src="${url}" alt="${label}" loading="lazy" />
          <span>${label}</span>
        </button>
      `;
}

function wireThumbnailCard(button) {
  button.addEventListener('click', () => {
    selectThumbnail(Number(button.dataset.thumbnailIndex), { scroll: true });
  });
}

// Acrescenta os frames recem-buscados no video ("Exibir mais") ao final da grade,
// sem recriar os cards existentes (preserva a selecao atual).
function appendThumbnails(newThumbnails) {
  const startIndex = currentThumbnails.length;
  currentThumbnails = currentThumbnails.concat(newThumbnails);
  thumbnailGrid.insertAdjacentHTML(
    'beforeend',
    newThumbnails.map((thumbnail, offset) => thumbnailCardHtml(thumbnail, startIndex + offset)).join('')
  );
  const cards = thumbnailGrid.querySelectorAll('.thumbnail-card');
  for (let i = startIndex; i < cards.length; i += 1) {
    wireThumbnailCard(cards[i]);
  }
  thumbnailCount.textContent = `${currentThumbnails.length} opcoes`;
}

function selectThumbnail(index, options = {}) {
  if (!currentThumbnails.length) return;
  currentThumbnailIndex = (index + currentThumbnails.length) % currentThumbnails.length;

  const thumbnail = currentThumbnails[currentThumbnailIndex];
  thumbnailViewer.hidden = false;
  thumbnailViewerImage.src = thumbnail.url;
  thumbnailViewerLabel.textContent = `${thumbnail.label || `Frame ${currentThumbnailIndex + 1}`} (${currentThumbnailIndex + 1}/${currentThumbnails.length})`;
  thumbnailOpenOriginal.href = thumbnail.url;
  thumbnailPrev.disabled = currentThumbnails.length < 2;
  thumbnailNext.disabled = currentThumbnails.length < 2;

  thumbnailGrid.querySelectorAll('.thumbnail-card').forEach((button, buttonIndex) => {
    button.classList.toggle('selected', buttonIndex === currentThumbnailIndex);
    button.setAttribute('aria-pressed', String(buttonIndex === currentThumbnailIndex));
  });

  if (options.scroll) {
    thumbnailViewer.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
}

function renderThumbnails(result) {
  const thumbnails = Array.isArray(result.thumbnails) ? result.thumbnails : [];
  currentThumbnails = thumbnails;
  currentThumbnailIndex = 0;
  currentJob = result.job || null;
  currentHasMore = Boolean(result.hasMore);
  thumbnailSection.hidden = false;
  thumbnailGrid.innerHTML = thumbnails.map((thumbnail, index) => thumbnailCardHtml(thumbnail, index)).join('');

  thumbnailCount.textContent = thumbnails.length ? `${thumbnails.length} opcoes` : 'Sem frames';
  if (thumbnails.length) {
    thumbnailGrid.querySelectorAll('.thumbnail-card').forEach(wireThumbnailCard);
    thumbnailShowMore.textContent = 'Exibir mais frames';
    thumbnailShowMore.hidden = !(currentJob && currentHasMore);
    selectThumbnail(0);
    thumbnailNote.textContent = currentJob && currentHasMore
      ? 'Clique nos frames para ampliar. Use "Exibir mais frames" para buscar novos frames no video.'
      : 'Clique nos frames ou use os botoes laterais para comparar. A imagem principal carrega o PNG em resolucao original.';
    return;
  }

  thumbnailShowMore.hidden = true;
  thumbnailViewer.hidden = true;
  thumbnailNote.textContent = result.thumbnailError
    ? `Nao consegui extrair frames deste arquivo. Verifique se o FFmpeg esta instalado. Detalhe: ${result.thumbnailError}`
    : 'Este arquivo nao parece ser um video com frames para thumbnail.';
}

thumbnailPrev.addEventListener('click', () => {
  selectThumbnail(currentThumbnailIndex - 1);
});

thumbnailNext.addEventListener('click', () => {
  selectThumbnail(currentThumbnailIndex + 1);
});

thumbnailShowMore.addEventListener('click', async () => {
  if (!currentJob || !currentHasMore) return;
  thumbnailShowMore.disabled = true;
  const originalLabel = thumbnailShowMore.textContent;
  thumbnailShowMore.textContent = 'Buscando mais frames...';
  try {
    const response = await fetch(`/api/frames/${encodeURIComponent(currentJob)}/more`, { method: 'POST' });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'Nao consegui buscar mais frames.');

    if (Array.isArray(result.thumbnails) && result.thumbnails.length) {
      appendThumbnails(result.thumbnails);
      thumbnailNote.textContent = `Mais ${result.thumbnails.length} frames extraidos do video. Role para ver as novas opcoes.`;
    } else {
      thumbnailNote.textContent = 'Nao ha mais frames para extrair deste video.';
    }
    currentHasMore = Boolean(result.hasMore);
    thumbnailShowMore.hidden = !currentHasMore;
  } catch (error) {
    thumbnailNote.textContent = error.message;
  } finally {
    thumbnailShowMore.disabled = false;
    thumbnailShowMore.textContent = originalLabel;
  }
});

document.addEventListener('keydown', (event) => {
  if (thumbnailSection.hidden || thumbnailViewer.hidden) return;
  if (event.key === 'ArrowLeft') {
    selectThumbnail(currentThumbnailIndex - 1);
  }
  if (event.key === 'ArrowRight') {
    selectThumbnail(currentThumbnailIndex + 1);
  }
});

async function copyText(text, button) {
  await navigator.clipboard.writeText(text || '');
  const originalText = button.textContent;
  button.textContent = 'Copiado';
  button.disabled = true;
  setTimeout(() => {
    button.textContent = originalText;
    button.disabled = false;
  }, 1600);
}

async function checkHealth() {
  const response = await fetch('/api/health');
  const health = await response.json();
  const acceleration = health.acceleration || {};
  if (acceleration.available) {
    useGpu.disabled = false;
    gpuOptionLabel.textContent = 'Utilizar GPU como processamento';
    useGpu.title = acceleration.label;
  } else {
    useGpu.checked = false;
    useGpu.disabled = true;
    gpuOptionLabel.textContent = 'Utilizar GPU como processamento';
    useGpu.title = acceleration.reason || 'Nenhuma GPU compativel foi detectada.';
  }
  apiStatus.textContent = `Motor local: ${health.model}; CPU ${health.computeType}; ${acceleration.available ? acceleration.label : 'sem aceleracao por GPU'}; ate ${health.uploadLimitMb} MB`;
  apiStatus.className = 'status ok';
}

media.addEventListener('change', () => {
  fileName.textContent = media.files[0]?.name || 'MP4, MP3, M4A, WAV ou WEBM ate 25 MB';
});

function setBusy(isBusy, mode) {
  submitButton.disabled = isBusy;
  transcribeOnlyButton.disabled = isBusy;
  framesOnlyButton.disabled = isBusy;
  submitButton.textContent = isBusy && mode === 'full' ? 'Transcrevendo...' : 'Transcrição + Frames';
  transcribeOnlyButton.textContent = isBusy && mode === 'transcribe' ? 'Transcrevendo...' : 'Apenas Transcrição';
  framesOnlyButton.textContent = isBusy && mode === 'frames' ? 'Extraindo frames...' : 'Apenas Frames';
}

async function processMedia(mode) {
  if (!media.files || !media.files.length) {
    form.reportValidity();
    return;
  }

  const framesOnly = mode === 'frames';
  actions.innerHTML = '';
  resetThumbnails();
  metrics.hidden = true;
  transcriptionTime.textContent = '';
  mediaDuration.textContent = '';
  runtimeUsed.textContent = '';

  if (framesOnly) {
    output.textContent = 'Extraindo os frames do video... isso pode levar alguns instantes.';
  } else if (useGpu.checked) {
    output.textContent = 'Enviando arquivo e transcrevendo com GPU... isso pode levar alguns minutos.';
  } else {
    output.textContent = 'Enviando arquivo e transcrevendo... isso pode levar alguns minutos.';
  }

  setBusy(true, mode);
  const requestStartedAt = performance.now();

  try {
    const data = new FormData(form);
    if (!framesOnly) {
      data.append('includeFrames', mode === 'full' ? 'true' : 'false');
    }
    const endpoint = framesOnly ? '/api/frames' : '/api/transcribe';
    const response = await fetch(endpoint, {
      method: 'POST',
      body: data
    });
    const result = await response.json();
    if (!response.ok) {
      throw new Error(result.error || (framesOnly ? 'Falha ao extrair os frames.' : 'Falha na transcricao.'));
    }

    if (framesOnly) {
      const frameCount = Array.isArray(result.thumbnails) ? result.thumbnails.length : 0;
      output.textContent = frameCount
        ? 'Frames extraidos. Clique em um frame para ver em tamanho maior.'
        : 'Nenhum frame foi extraido deste arquivo.';
      renderThumbnails(result);
      return;
    }

    output.textContent = result.text || 'Transcricao concluida, mas sem texto retornado.';
    const browserElapsedSeconds = (performance.now() - requestStartedAt) / 1000;
    const transcriptionSeconds = Number(result.transcriptionSeconds) > 0 ? result.transcriptionSeconds : browserElapsedSeconds;
    const mediaDurationSeconds = Number(result.mediaDurationSeconds) > 0
      ? result.mediaDurationSeconds
      : durationFromSegments(result.segments);

    transcriptionTime.textContent = formatDuration(transcriptionSeconds) || 'Nao informado';
    mediaDuration.textContent = formatDuration(mediaDurationSeconds) || 'Nao informado';
    runtimeUsed.textContent = result.fallbackReason
      ? `${result.runtimeLabel || result.device}. ${result.fallbackReason}`
      : (result.runtimeLabel || result.device || 'Nao informado');
    metrics.hidden = false;
    actions.innerHTML = `
      <button type="button" class="copy-action" data-copy="text">Copiar texto</button>
      <button type="button" class="copy-action" data-copy="srt">Copiar SRT</button>
      ${Object.entries(result.downloads)
        .map(([format, url]) => `<a href="${escapeHtml(url)}">Baixar ${format.toUpperCase()}</a>`)
        .join('')}
    `;
    actions.querySelector('[data-copy="text"]').addEventListener('click', (clickEvent) => {
      copyText(result.text, clickEvent.currentTarget).catch(() => {
        output.textContent = 'Nao foi possivel copiar a transcricao.';
      });
    });
    actions.querySelector('[data-copy="srt"]').addEventListener('click', (clickEvent) => {
      copyText(result.srtText, clickEvent.currentTarget).catch(() => {
        output.textContent = 'Nao foi possivel copiar o SRT.';
      });
    });
    if (mode === 'full') {
      renderThumbnails(result);
    }
  } catch (error) {
    output.textContent = error.message;
  } finally {
    setBusy(false, mode);
  }
}

form.addEventListener('submit', (event) => {
  event.preventDefault();
  processMedia('full');
});

transcribeOnlyButton.addEventListener('click', () => {
  processMedia('transcribe');
});

framesOnlyButton.addEventListener('click', () => {
  processMedia('frames');
});

checkHealth().catch(() => {
  apiStatus.textContent = 'Nao foi possivel verificar a configuracao.';
  apiStatus.className = 'status warn';
});
