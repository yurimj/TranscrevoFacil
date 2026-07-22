# Política de segurança

## Versões suportadas

Somente a versão mais recente publicada recebe correções de segurança.

## Como relatar uma vulnerabilidade

Não abra uma issue pública com credenciais, dados pessoais, arquivos de áudio, transcrições ou detalhes que permitam explorar a falha.

Use **Security > Report a vulnerability** no repositório do GitHub para enviar um relato privado. Inclua:

- versão afetada;
- passos mínimos para reproduzir;
- impacto esperado;
- logs já removidos de tokens, caminhos pessoais e conteúdo transcrito.

O recebimento será confirmado assim que possível. A correção e a divulgação pública serão coordenadas conforme o impacto.

## Escopo de segurança local

O TranscrevoFácil foi projetado para escutar somente no endereço de loopback. Expor a aplicação à rede, alterar `HOST` para um endereço externo ou publicar as pastas `uploads/` e `transcripts/` não é uma configuração suportada.
