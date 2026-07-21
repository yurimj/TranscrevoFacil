# Assets gerados

Esta pasta e preenchida automaticamente pelo workflow `windows-installer.yml` e pelo script `scripts/build-installer.ps1`.

Os binarios, modelos e wheels nunca devem ser versionados. Eles somente podem ser gerados a partir de `installer/dependencies.json` e `installer/python-requirements.lock`, com validacao de SHA-256 e revisao de `premissas.md`.
