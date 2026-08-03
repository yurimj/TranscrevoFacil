# TranscrevoFácil

Transcrição local de áudio e vídeo com Whisper, sem consumir créditos de API. O processamento e os arquivos permanecem no computador do usuário.

## Recursos

- transcrição e tradução local;
- exportação em TXT, JSON e SRT;
- extração de frames para thumbnails;
- NVIDIA por CUDA;
- AMD e Intel por Vulkan;
- fallback automático para CPU quando a aceleração não está disponível;
- precisão `float32` em CPU e CUDA para reduzir divergências;
- instalador Windows com runtimes, modelos e dependências verificadas.

## Instalação para usuário final

O usuário final deve receber `TranscrevoFacil-Setup-<versão>.exe` a partir de uma release oficial. O instalador configura Node.js, Python, FFmpeg, Whisper, Vulkan e os modelos necessários. Quando detecta uma GPU NVIDIA, ele baixa e instala automaticamente o pacote CUDA/cuDNN fixado por versão e SHA-256; se a rede ou a GPU falhar, o aplicativo continua pela CPU. O atalho verifica os runtimes, escolhe uma porta local livre, inicia o servidor e abre o navegador.

O servidor aceita conexões somente de `localhost`. Na instalação final, dados e transcrições ficam em `%LOCALAPPDATA%\TranscrevoFacil\data` e não são removidos silenciosamente na desinstalação.

As regras obrigatórias do produto e da distribuição estão em [`premissas.md`](premissas.md).

## Desenvolvimento

Requisitos: Windows, Node.js 24, pnpm 11 e Python 3.13 x64.

```powershell
corepack enable
corepack prepare pnpm@11.15.1 --activate
pnpm install --frozen-lockfile
powershell -ExecutionPolicy Bypass -File scripts/setup-local.ps1
pnpm dev
```

Abra `http://127.0.0.1:3000`.

Para validar uma mudança:

```powershell
pnpm test
pnpm run audit
pnpm run verify:release
```

Nunca versione `.env`, mídias, transcrições, modelos, runtimes ou credenciais reais.

## Configuração

Copie `.env.example` para `.env` somente quando precisar alterar os padrões. Opções principais:

- `WHISPER_MODEL`: `tiny`, `base`, `small`, `medium`, `large-v3` ou caminho de um modelo local;
- `UPLOAD_LIMIT_MB`: limite máximo de upload em MB; o padrão é `0`, que remove o limite (o teto passa a ser o espaço em disco);
- `THUMBNAIL_FRAME_COUNT`: quantidade de frames extraídos;
- `WHISPER_CPU_THREADS`: `0` seleciona automaticamente;
- `WHISPER_NUM_WORKERS`: quantidade de workers;
- `FFMPEG_BIN`: caminho alternativo para `ffmpeg.exe`.

`HOST` deve permanecer em `127.0.0.1`. Exposição em rede não é uma configuração suportada.

## GPU e consistência

Ao marcar **Utilizar GPU como processamento**, o backend é escolhido automaticamente:

- NVIDIA compatível: faster-whisper/CTranslate2 com CUDA;
- AMD ou Intel compatível: whisper.cpp com Vulkan;
- GPU ausente, fraca, incompatível ou com falha: faster-whisper em CPU.

CPU e CUDA usam `float32`. O backend Vulkan usa um modelo GGML equivalente e pode produzir pequenas diferenças de segmentação.

## Instalador

O manifesto [`installer/dependencies.json`](installer/dependencies.json) fixa versões, origens e hashes. Os pacotes Python são fixados transitivamente em [`installer/python-requirements.lock`](installer/python-requirements.lock). O pacote NVIDIA opcional usa o lock separado [`installer/python-requirements-cuda.lock`](installer/python-requirements-cuda.lock), evitando adicionar mais de 1 GB a computadores AMD, Intel ou sem GPU.

Para gerar o instalador em uma máquina Windows:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build-installer.ps1
```

O build baixa e verifica as ferramentas necessárias, executa testes, compila o backend Vulkan e grava o resultado em `dist-installer/`.

## Segurança

Consulte [`SECURITY.md`](SECURITY.md) para relatar vulnerabilidades de forma privada. Não publique conteúdo transcrito ou logs com caminhos pessoais em issues.

## Licença

O código do TranscrevoFácil está sob a [licença MIT](LICENSE). Componentes e modelos de terceiros mantêm suas próprias licenças; consulte [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
