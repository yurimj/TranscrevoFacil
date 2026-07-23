# Premissas obrigatorias do TranscrevoFacil

## Instalador para distribuicao publica

O TranscrevoFacil somente pode ser liberado ao publico por meio de um instalador para Windows. O usuario final deve conseguir instalar, abrir e transcrever sem usar terminal, editar arquivos, configurar variaveis ou procurar dependencias por conta propria.

O instalador e parte do produto. Toda nova implementacao deve incluir uma revisao do instalador, mesmo quando a alteracao parecer restrita ao frontend ou ao servidor. A revisao deve confirmar se surgiram novos arquivos, executaveis, modelos, variaveis, pacotes, permissoes ou DLLs. Se uma nova DLL for necessaria, ela deve ser instalada e validada pelo instalador na mesma entrega.

## Responsabilidades do instalador

O instalador deve instalar ou empacotar absolutamente tudo que um usuario leigo precisar, incluindo:

- Node.js e os pacotes NPM da aplicacao;
- Python, pip, ambiente Python e faster-whisper;
- CTranslate2 e o modelo Whisper utilizado pelo aplicativo;
- FFmpeg;
- runtimes NVIDIA CUDA, cuBLAS e cuDNN necessarios, baixados e validados automaticamente apenas quando uma GPU NVIDIA for detectada, sem exigir o CUDA Toolkit completo;
- runtime Vulkan, whisper.cpp e modelo GGML para GPUs AMD e Intel;
- Microsoft Visual C++ Runtime e qualquer outra DLL nativa exigida pelos executaveis;
- entradas de PATH necessarias, sem depender exclusivamente do PATH para iniciar o aplicativo;
- arquivos `.env` e demais configuracoes iniciais com caminhos absolutos validos.

Downloads feitos pelo instalador devem ser automaticos, silenciosos, provenientes de fontes oficiais, ter versao fixada e validacao de integridade. Uma falha deve exibir uma mensagem compreensivel e oferecer reparo; nunca deve mandar o usuario instalar manualmente uma dependencia.

As versoes, origens e hashes aprovados devem ficar centralizados em `installer/dependencies.json`. Pacotes Python devem usar locks completos com hashes de dependencias transitivas, incluindo um lock separado para o pacote NVIDIA opcional. Downloads, Actions e ferramentas de build nao podem depender apenas de tags, URLs ou versoes mutaveis. A revisao desse manifesto vence depois de 120 dias e deve ser renovada antes de qualquer release.

O instalador publico deve ser assinado com certificado Authenticode confiavel e timestamp. Builds de teste podem ser unsigned, mas nunca devem ser apresentados como release final.

## Compatibilidade de processamento

- NVIDIA compativel: usar faster-whisper/CTranslate2 com CUDA.
- AMD ou Intel com Vulkan compativel: usar whisper.cpp com Vulkan.
- GPU ausente, fraca, incompativel ou com falha: continuar funcionando por CPU e informar claramente o fallback.
- A deteccao deve ser automatica. O usuario nao precisa conhecer CUDA, ROCm, Vulkan, VRAM ou arquitetura da GPU.

## Atalho e inicializacao

O instalador deve criar atalhos no Menu Iniciar e, quando selecionado, na Area de Trabalho. O atalho deve executar um inicializador que:

1. localize a instalacao e verifique os runtimes Node.js, Python, Whisper, FFmpeg e as DLLs necessarias;
2. corrija o PATH da sessao e use caminhos absolutos como garantia;
3. verifique se o servidor do TranscrevoFacil ja esta ativo;
4. tente usar a porta 3000 sem encerrar processos de outros programas;
5. se a porta 3000 estiver ocupada por outro programa, escolha automaticamente outra porta livre;
6. inicie ou recupere o servidor quando necessario;
7. aguarde a resposta da rota de saude;
8. abra o endereco correto do software no navegador padrao.

O servidor deve escutar exclusivamente em loopback (`127.0.0.1`, `localhost` ou `::1`), validar o cabecalho Host e rejeitar origens externas. Transcricoes, uploads e logs do usuario devem ficar fora dos arquivos do programa e nunca podem ser enviados para a rede sem consentimento explicito.

## Repositorio publico e cadeia de fornecimento

- o codigo proprio usa licenca MIT; componentes de terceiros conservam suas licencas;
- `LICENSE`, `SECURITY.md` e `THIRD_PARTY_NOTICES.md` sao obrigatorios;
- commits devem usar o endereco `noreply` do GitHub, salvo decisao consciente do autor;
- `.env`, uploads, transcricoes, runtimes, modelos, caches, logs, chaves e credenciais nunca podem ser versionados;
- dependencias do GitHub Actions devem ser fixadas pelo SHA completo do commit;
- a branch padrao aceita commits e merges diretos; pull request e verificacoes de CI sao recomendados, mas nao obrigatorios; force-push e exclusao devem ser feitos com cuidado, porem nao ficam bloqueados;
- Dependabot, alertas de vulnerabilidade, secret scanning e relato privado de vulnerabilidades devem permanecer habilitados;
- releases devem incluir checksums, procedencia, avisos e textos de licenca exigidos;
- qualquer credencial encontrada deve ser revogada, nao apenas removida do commit mais recente.

## Criterios para uma versao publicavel

Antes de gerar uma versao publica, devem ser validados em uma instalacao limpa:

- instalacao sem Node.js, Python, FFmpeg ou CUDA previamente instalados;
- inicializacao pelo atalho depois de reiniciar o Windows;
- porta 3000 livre e porta 3000 ocupada;
- computador sem GPU dedicada;
- NVIDIA compativel e NVIDIA sem memoria suficiente;
- AMD compativel com Vulkan;
- Intel integrada ou dedicada com Vulkan;
- fallback automatico para CPU quando qualquer backend de GPU falhar;
- transcricao, traducao, downloads e extracao de thumbnails;
- reparo e desinstalacao sem apagar transcricoes do usuario sem confirmacao.
- assinatura Authenticode valida e instalador sem alerta de arquivo adulterado;
- CI, auditoria de dependencias, secret scan e `pnpm run verify:release` aprovados;
- licencas, hashes, procedencia e oferta de codigo-fonte dos componentes copyleft revisados.

Uma versao que nao cumpra esta lista nao deve ser apresentada como pronta para o usuario final.
