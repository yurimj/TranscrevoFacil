# Componentes de terceiros

O código próprio do TranscrevoFácil é distribuído sob a licença MIT. Os componentes abaixo permanecem sob as licenças de seus respectivos autores; a licença MIT não substitui nem altera esses termos.

As versões, URLs e hashes aprovados estão em `installer/dependencies.json`. O lock completo dos pacotes Python está em `installer/python-requirements.lock`. Durante a geração do instalador, os textos encontrados nos pacotes são extraídos para o diretório `licenses/` e entregues ao usuário.

| Componente | Versão | Licença ou termos | Origem |
| --- | --- | --- | --- |
| Python | 3.13.14 | Python Software Foundation License | https://www.python.org/ |
| Node.js | 24.18.0 | MIT e licenças dos componentes incluídos | https://nodejs.org/ |
| FFmpeg, compilação Gyan essentials | 8.1.2 | GPL-3.0-or-later | https://www.gyan.dev/ffmpeg/builds/ |
| faster-whisper | 1.2.1 | MIT | https://github.com/SYSTRAN/faster-whisper |
| CTranslate2 | 4.8.1 | MIT | https://github.com/OpenNMT/CTranslate2 |
| whisper.cpp | 1.9.1 | MIT | https://github.com/ggml-org/whisper.cpp |
| Modelo faster-whisper-small | revisão fixada no manifesto | MIT declarada pelo fornecedor do modelo | https://huggingface.co/Systran/faster-whisper-small |
| Modelo ggml-small | revisão fixada no manifesto | termos do modelo OpenAI Whisper | https://huggingface.co/ggerganov/whisper.cpp |
| NVIDIA cuBLAS | 12.9.2.10 | NVIDIA Software License Agreement | https://docs.nvidia.com/cuda/eula/ |
| NVIDIA cuDNN | 9.25.0.15 | NVIDIA Software License Agreement e suplemento cuDNN | https://docs.nvidia.com/deeplearning/cudnn/ |
| Microsoft Visual C++ Redistributable | 14.51.36247.0 | Microsoft Visual Studio License Terms | https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist |
| Vulkan SDK, usado somente na compilação | 1.4.350.0 | licenças dos componentes do SDK | https://vulkan.lunarg.com/ |
| Inno Setup, usado somente na compilação | 7.0.2 | Inno Setup License | https://jrsoftware.org/isinfo.php |

## Código-fonte correspondente ao FFmpeg

O FFmpeg é executado como programa separado pela linha de comando e não é relicenciado como parte do código MIT do TranscrevoFácil. A distribuição deve manter o texto GPL e oferecer acesso equivalente ao código-fonte correspondente:

- código-fonte do FFmpeg 8.1.2: https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz;
- receita da compilação distribuída: https://github.com/GyanD/codexffmpeg/tree/8.1.2.

Ao publicar o instalador em uma release, mantenha esses links, os textos extraídos em `licenses/` e o arquivo de procedência gerado pelo build disponíveis junto ao binário.

## NVIDIA

As bibliotecas NVIDIA são instaladas como runtimes proprietários separados para uso em GPUs NVIDIA. A redistribuição deve seguir integralmente a licença da NVIDIA, manter os avisos proprietários e não declarar patrocínio ou endosso da NVIDIA.

Este arquivo é informativo e não substitui os textos integrais das licenças. Antes de cada release pública, execute a revisão prevista em `premissas.md`.
