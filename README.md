# Transcrevo Facil

Aplicativo local para transcrever videos e audios sem consumir tokens ou creditos de API. A transcricao roda no seu computador com Whisper local via `faster-whisper`.

## Como rodar

1. Instale o Node.js 20 ou superior.
2. Instale Python 3.10 ou superior.
3. Instale o ffmpeg e deixe o comando `ffmpeg` disponivel no terminal.
4. Rode o instalador local:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/setup-local.ps1
```

Ou instale manualmente o motor local:

```bash
pip install faster-whisper
```

5. Copie `.env.example` para `.env` se quiser trocar modelo, porta ou limite de upload.
6. Instale as dependencias do app:

```bash
npm install
```

7. Inicie:

```bash
npm run dev
```

8. Abra `http://localhost:3000`.

## O que ja faz

- Upload de video ou audio.
- Transcricao local em portugues, ingles, espanhol ou deteccao automatica.
- Traducao para ingles usando o proprio Whisper local.
- Download em TXT, JSON e SRT simples.
- Base pronta para virar um produto publico em `transcrevofacil.com.br`.

## Modelos locais

No `.env`, ajuste `WHISPER_MODEL`.

- `tiny`: mais rapido, menos preciso.
- `base`: leve e aceitavel.
- `small`: bom equilibrio inicial.
- `medium`: melhor, mas mais pesado.
- `large-v3`: melhor qualidade, exige mais maquina.

## GPU e desempenho

Se o computador tiver NVIDIA/CUDA disponivel, use:

```env
WHISPER_DEVICE=cuda
WHISPER_COMPUTE_TYPE=int8_float16
WHISPER_NUM_WORKERS=1
```

Para CPU, use `WHISPER_DEVICE=cpu` e `WHISPER_COMPUTE_TYPE=int8`. Aumente `WHISPER_NUM_WORKERS` com cuidado: em uma GPU com 4 GB de VRAM, `1` costuma ser mais estavel para um video por vez.

## Proximos passos recomendados

- Criar instalador para Windows com Python, ffmpeg e modelo empacotados.
- Adicionar fila de processamento para varios videos.
- Criar cadastro, historico de transcricoes e limite por plano.
- Para publicar ao publico sem custo de API, rodar workers proprios com GPU/CPU e controlar fila por usuario.
