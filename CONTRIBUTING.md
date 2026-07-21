# Como contribuir

## Desenvolvimento

1. Não inclua mídia, transcrições, modelos, runtimes, credenciais ou arquivos `.env` reais.
2. Instale as dependências com `pnpm install --frozen-lockfile`.
3. Execute `pnpm test` e `pnpm run verify:release` antes de abrir um pull request.
4. Descreva o comportamento testado em CPU e, quando aplicável, em NVIDIA/CUDA, AMD/Vulkan e Intel/Vulkan.

## Revisão obrigatória do instalador

Toda alteração deve responder se adiciona ou muda arquivos, DLLs, modelos, executáveis, variáveis, permissões ou dependências. Quando a resposta for positiva, atualize o instalador, `installer/dependencies.json`, os avisos de terceiros e os testes correspondentes.

As premissas completas estão em `premissas.md`. Uma mudança que quebre a instalação para usuário leigo não está pronta para merge.

## Segurança e privacidade

Relate vulnerabilidades conforme `SECURITY.md`. Nunca coloque dados reais de usuários em issues, commits, fixtures ou logs de CI.
