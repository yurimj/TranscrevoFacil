const form = document.querySelector('#transcribeForm');
const media = document.querySelector('#media');
const fileName = document.querySelector('#fileName');
const output = document.querySelector('#output');
const actions = document.querySelector('#actions');
const submitButton = document.querySelector('#submitButton');
const apiStatus = document.querySelector('#apiStatus');

async function checkHealth() {
  const response = await fetch('/api/health');
  const health = await response.json();
  apiStatus.textContent = `Motor local: ${health.model} em ${health.device} ate ${health.uploadLimitMb} MB`;
  apiStatus.className = 'status ok';
}

media.addEventListener('change', () => {
  fileName.textContent = media.files[0]?.name || 'MP4, MP3, M4A, WAV ou WEBM ate 25 MB';
});

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  actions.innerHTML = '';
  output.textContent = 'Enviando arquivo e transcrevendo... isso pode levar alguns minutos.';
  submitButton.disabled = true;
  submitButton.textContent = 'Transcrevendo...';

  try {
    const data = new FormData(form);
    const response = await fetch('/api/transcribe', {
      method: 'POST',
      body: data
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'Falha na transcricao.');

    output.textContent = result.text || 'Transcricao concluida, mas sem texto retornado.';
    actions.innerHTML = Object.entries(result.downloads)
      .map(([format, url]) => `<a href="${url}">Baixar ${format.toUpperCase()}</a>`)
      .join('');
  } catch (error) {
    output.textContent = error.message;
  } finally {
    submitButton.disabled = false;
    submitButton.textContent = 'Transcrever agora';
  }
});

checkHealth().catch(() => {
  apiStatus.textContent = 'Nao foi possivel verificar a configuracao.';
  apiStatus.className = 'status warn';
});
