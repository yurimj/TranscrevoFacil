# Catalogo de modificacoes do TranscrevoFacil

Este arquivo registra, de forma detalhada e cumulativa, cada modificacao solicitada
para o TranscrevoFacil, conforme a premissa "Catalogo de modificacoes" descrita em
[`premissas.md`](premissas.md). As entradas mais recentes ficam no topo e o historico
anterior nunca e apagado.

## 0.2.3 (2026-07-26)

### Release 0.2.3: instalador regenerado com as mudancas acumuladas

**Data:** 2026-07-26

**Pedido do usuario:** gerar um novo instalador contendo as mudancas (test build, sem assinatura).

**O que mudou:**

- Bump de versao 0.2.2 -> 0.2.3 em `installer/TranscrevoFacil.iss` (`MyAppVersion`), `package.json` e no `version` da rota `/api/health` (que estava desatualizado em 0.2.0).
- `node_modules` reinstalado no layout hoisted (`pnpm install --prod --frozen-lockfile --config.node-linker=hoisted`), como o pipeline oficial exige para o Inno Setup empacotar sem symlinks.
- Instalador compilado com o Inno Setup 7.0.2 a partir do `.iss`, reutilizando os assets ja preparados em `installer/assets` (ffmpeg, python, whisper.cpp Vulkan, modelos, wheels, Node, VC++). Saida: `dist-installer/TranscrevoFacil-Setup-0.2.3.exe`.

**Revisao do instalador (premissa):** nenhuma dependencia, DLL, modelo, pacote ou executavel novo. As mudancas sao arquivos de app (`server.js`, `public/*`) que o `.iss` ja empacota; `premissas.md` idem. As variaveis novas de "Exibir mais" sao opcionais com padrao seguro. `installer/dependencies.json` inalterado.

**Observacoes:**

- Test build **sem assinatura Authenticode**. Uma release publica ainda exige `pnpm run verify:release` e assinatura, conforme `premissas.md`.
- `CHANGELOG.md` nao e empacotado pelo `.iss` (fica como catalogo no GitHub); pode ser incluido futuramente se desejado.

### Checkbox "Utilizar GPU como processamento" marcado por padrao

**Data:** 2026-07-26

**Pedido do usuario:** deixar o checkbox "Utilizar GPU como processamento" marcado por padrao.

**O que mudou:**

- `public/index.html`
  - O input `#useGpu` recebeu o atributo `checked`, ficando marcado ao abrir a pagina.

**Decisoes de projeto:**

- Seguro por padrao: `checkHealth()` (em `public/app.js`) continua desmarcando e desabilitando o checkbox automaticamente quando nenhuma GPU compativel e detectada; e a transcricao ja tem fallback automatico para CPU caso a GPU falhe. Assim, o padrao marcado so tem efeito onde ha GPU utilizavel.

**Impacto no instalador e nas dependencias:** nenhum.

**Validacao executada nesta entrega:**

- Navegador: ao carregar, `#useGpu` aparece marcado (atributo e propriedade `checked`); apos o `checkHealth` com GPU disponivel (RTX 3050 Ti) permanece marcado e habilitado.

### "Exibir mais" agora busca frames novos no video (extracao sob demanda)

**Data:** 2026-07-25

**Pedido do usuario:** o botao "Exibir mais" nao deve apenas revelar frames ja extraidos; ele precisa voltar ao video e extrair frames NOVOS, alem dos ~80 do lote inicial.

**O que mudou:**

- `server.js`
  - Conceito de "job de frames": ao extrair frames (por "Transcricao + Frames" ou "Apenas Frames"), o video e movido para `uploads/job-<id>.<ext>` e um manifesto `transcripts/thumbnails/<id>/job.json` guarda duracao, instantes ja usados e contador de frames. Isso permite voltar ao mesmo video depois.
  - Novo endpoint `POST /api/frames/:job/more`: amostra novos instantes do video (dividindo sempre o maior intervalo livre da linha do tempo), extrai um lote de frames novos (`extra-*.png`), atualiza o manifesto e responde com esses frames e `hasMore`. Cada lote e ordenado por tempo (passada cronologica mais densa).
  - `/api/transcribe` e `/api/frames` agora criam o job e retornam `job` e `hasMore`; `createFrameJob` cuida de mover o video, extrair o lote inicial e gravar o manifesto.
  - Limpeza automatica (`sweepFrameJobs`): remove jobs por TTL (`FRAME_JOB_TTL_MS`, padrao 1h) e mantem apenas os mais recentes (`MAX_FRAME_JOBS`, padrao 10). Roda no start e antes de cada novo job. Teto de frames por job (`MAX_JOB_FRAMES`, padrao 400) e lote por clique (`EXTRA_FRAME_BATCH`, padrao 40).
- `public/app.js`
  - Removida a paginacao no cliente (que so revelava os frames ja carregados). Agora todos os frames extraidos aparecem e "Exibir mais frames" faz `POST /api/frames/:job/more`, anexando os frames novos ao final da grade (`appendThumbnails`) sem recriar os cards existentes. Botao mostra "Buscando mais frames..." durante a extracao e some quando `hasMore` e falso.
  - `renderThumbnails` passou a guardar `job`/`hasMore`; `selectThumbnail` simplificado (sem logica de revelar).
- `public/styles.css`
  - Removida a regra morta `.thumbnail-card.is-hidden` (a paginacao no cliente saiu).

**Decisoes de projeto:**

- Densificacao por "maior intervalo": cada frame novo cai no maior buraco atual da linha do tempo, garantindo frames sempre novos e bem distribuidos, sem repetir instantes; para quando o maior intervalo fica menor que 0,4 s ou ao atingir o teto de frames.
- O video de origem e mantido apenas enquanto o job vive (TTL + limite de jobs), respeitando a premissa de manter uploads locais e limpar o disco. Continua tudo em loopback; nada vai para a rede.
- Substitui a abordagem anterior de "Exibir mais" (paginacao no cliente) descrita na entrada abaixo.

**Impacto no instalador e nas dependencias:** nenhum. Reusa o `ffmpeg.exe` ja empacotado; nenhum binario, DLL, modelo ou pacote novo. Novas variaveis de ambiente sao opcionais e tem padrao seguro. Sem alteracao em `installer/dependencies.json`.

**Validacao automatizada executada nesta entrega:**

- `node --check` (server.js e app.js) e `node --test` (10/10).
- Fluxo real na maquina (dev server + ffmpeg): `POST /api/frames` -> job + 80 frames + `hasMore`; dois `POST /api/frames/:job/more` -> +40 frames novos cada, `extra-*.png`, rotulos cronologicos, distribuicao uniforme pelas faixas de 10 s do video (26/27/27/28/27/25 em 160 frames), zero duplicados.
- Navegador: "Exibir mais frames" leva a grade de 80 -> 120 com fetch real; clicar em um frame novo abre o `extra-*.png` no visualizador e rola a pagina ate ele.

### Botao "Apenas Transcricao"

**Data:** 2026-07-25

**Pedido do usuario:** adicionar um terceiro botao, entre "Transcricao + Frames" e "Apenas Frames", chamado "Apenas Transcricao".

**O que mudou:**

- `public/index.html`
  - Novo botao `#transcribeOnlyButton` ("Apenas Transcricao"), posicionado entre `#submitButton` e `#framesOnlyButton`. A ordem passa a ser: "Transcricao + Frames", "Apenas Transcricao", "Apenas Frames".
  - Dica atualizada para explicar tambem o modo "Apenas Transcricao".
- `public/styles.css`
  - `.submit-row` passou a ter tres colunas (`repeat(3, 1fr)`); no modo estreito continua empilhando em coluna unica. Ajuste de `padding`/`font-size`/`line-height` dos botoes da linha para acomodar os tres rotulos.
- `public/app.js`
  - Novo modo `transcribe` em `processMedia`: chama `POST /api/transcribe` com `includeFrames=false`, transcreve normalmente e mantem a secao de frames oculta (nao chama `renderThumbnails`).
  - `setBusy` passou a controlar os tres botoes, rotulando o botao ativo com o progresso.
- `server.js`
  - `POST /api/transcribe` passou a ler `includeFrames` do corpo (ausente => true, preservando "Transcricao + Frames"). Quando `false`, pula `generateGoodFrames` e responde com `thumbnails: []`.

**Decisoes de projeto:**

- Reaproveitou-se o endpoint `/api/transcribe` com um sinalizador (`includeFrames`) em vez de criar um endpoint novo, mantendo a transcricao, a escrita de `txt/json/srt` e as metricas identicas ao modo "Transcricao + Frames"; apenas a extracao de frames e pulada, economizando o trabalho do FFmpeg.

**Impacto no instalador e nas dependencias:** nenhum. Nenhum executavel, DLL, modelo, pacote ou variavel novo; sem alteracao em `installer/dependencies.json` nem nos scripts de instalacao.

**Validacao manual sugerida:**

- Usar "Apenas Transcricao" num MP4: o texto e as metricas aparecem, sem a secao de frames.
- Confirmar que "Transcricao + Frames" continua extraindo os frames e que "Apenas Frames" continua so extraindo os frames.

**Validacao automatizada executada nesta entrega:**

- `node --check` em `server.js` e `public/app.js` (sintaxe).
- `node --test` (10/10 testes existentes aprovados).
- `POST /api/transcribe` com `includeFrames=false`: resposta HTTP 200 com `thumbnails: []` e sem extracao de frames; com `includeFrames=true` os frames continuam sendo extraidos.
- Verificacao no navegador: os tres botoes renderizados na ordem correta; "Apenas Transcricao" mantem a secao de frames oculta.

### Botoes de acao separados, rolagem ao frame e paginacao de frames

**Data:** 2026-07-25

**Pedido do usuario:**

1. Dividir o botao unico "Transcrever agora" em dois botoes: "Transcricao + Frames" e "Apenas Frames".
2. Ao clicar em um frame da grade, rolar a pagina ate a imagem ampliada.
3. Adicionar um botao "Exibir mais" para carregar frames adicionais para escolha.
4. Registrar cada modificacao futura de forma detalhada para exposicao no GitHub (esta premissa e este catalogo).

**O que mudou:**

- `premissas.md`
  - Nova secao "Catalogo de modificacoes", que torna obrigatorio documentar cada alteracao neste `CHANGELOG.md` antes do commit, com data, pedido, arquivos alterados, motivo, decisoes e impacto no instalador.
- `CHANGELOG.md` (novo arquivo)
  - Criacao do catalogo cumulativo, comecando por esta entrada.
- `public/index.html`
  - O botao unico foi substituido por uma linha (`.submit-row`) com dois botoes: `#submitButton` ("Transcricao + Frames", envia o formulario e transcreve) e `#framesOnlyButton` ("Apenas Frames", extrai somente os frames).
  - Novo botao `#thumbnailShowMore` ("Exibir mais"), abaixo da grade de frames, oculto por padrao.
  - Dica atualizada para explicar o modo "Apenas Frames".
- `public/styles.css`
  - Novos estilos: `.submit-row` (dois botoes lado a lado, empilhados no modo estreito), `.button-secondary` (variacao clara do botao "Apenas Frames"), `.thumbnail-more` (botao "Exibir mais") e `.thumbnail-card.is-hidden` (frames ainda nao exibidos).
- `public/app.js`
  - A logica de envio foi unificada em `processMedia(mode)`, chamada tanto pelo submit ("full") quanto pelo botao "Apenas Frames" ("frames"). O modo "frames" chama `POST /api/frames`, oculta as metricas de transcricao e mostra apenas os frames.
  - `setBusy(isBusy, mode)` desabilita e rotula ambos os botoes durante o processamento.
  - `selectThumbnail(index, { scroll })` passou a rolar suavemente ate a imagem ampliada quando o frame e escolhido por clique na grade; navegacao por setas/teclado nao rola a pagina.
  - Paginacao de frames: apenas os primeiros `THUMBNAIL_PAGE_SIZE` (24) frames aparecem; "Exibir mais" revela o proximo lote (`updateThumbnailVisibility`). Selecionar por teclado um frame ainda oculto o revela automaticamente.
- `server.js`
  - Novo endpoint `POST /api/frames`: recebe o upload, extrai os frames com `generateGoodFrames` e responde sem transcrever.
  - Nova funcao `probeMediaDurationSeconds`: obtem a duracao do video a partir da saida do proprio `ffmpeg -i` (linha `Duration:`), usada para distribuir os frames pela linha do tempo no modo "Apenas Frames".

**Decisoes de projeto:**

- "Exibir mais" pagina, no cliente, o conjunto de frames ja extraidos pelo servidor (ate ~80 por processamento), revelando-os em lotes. Nao ha reprocessamento nem persistencia do video de origem entre requisicoes, o que evita uso extra de disco e preserva o comportamento de limpeza atual dos uploads.
- A duracao no modo "Apenas Frames" e lida do `ffmpeg` ja empacotado, em vez de adicionar o `ffprobe` ao instalador.

**Impacto no instalador e nas dependencias:** nenhum. Nenhum executavel, DLL, modelo, pacote ou variavel de ambiente novo. O endpoint `/api/frames` reutiliza o mesmo `ffmpeg.exe` ja empacotado, as rotas de thumbnail e a CSP existentes. Nao ha alteracao em `installer/dependencies.json` nem nos scripts de instalacao.

**Validacao manual sugerida:**

- Enviar um MP4 e usar "Transcricao + Frames": a transcricao e os frames aparecem como antes.
- Usar "Apenas Frames" no mesmo MP4: apenas os frames aparecem, sem metricas de transcricao.
- Clicar em um frame da grade: a pagina rola ate a imagem ampliada.
- Clicar em "Exibir mais": novos frames surgem para escolha, ate esgotar o conjunto (o botao some quando nao ha mais frames).

**Validacao automatizada executada nesta entrega:**

- `node --check` em `server.js` e `public/app.js` (sintaxe).
- `node --test` (10/10 testes existentes aprovados).
- `POST /api/frames` com um MP4 de teste de 30s: resposta HTTP 200, `mediaDurationSeconds` = 30, 80 frames extraidos, `thumbnailError` nulo.
- Verificacao no navegador: dois botoes renderizados; paginacao 24 -> 48 -> 72 -> 80 com "Exibir mais"; clique no frame aciona a rolagem ate a imagem ampliada.
