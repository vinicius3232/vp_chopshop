# Contribuindo com o vp_chopshop

## Fluxo de trabalho

1. **Nunca commite direto em `main`.** `main` é sempre a versão estável em produção.
2. Crie um branch a partir de `main` seguindo a convenção de nomes abaixo.
3. Abra um Pull Request. Um PR = uma mudança coesa e revisável.
4. Para trabalho grande, use uma **pilha de PRs** (cada um com `base` no anterior),
   um passo lógico por PR — não um PR gigante.
5. Merge só depois de: revisão de arquitetura **e** teste em servidor. GO
   arquitetural ≠ GO de release.

## Convenção de branch

| Prefixo      | Uso                                              |
|--------------|--------------------------------------------------|
| `feat/`      | Nova funcionalidade                              |
| `fix/`       | Correção de bug                                  |
| `security/`  | Correção de vulnerabilidade / hardening          |
| `arch/`      | Refatoração de arquitetura sem mudança de comportamento |
| `balance/`   | Ajuste de economia / balanceamento de gameplay   |
| `docs/`      | Só documentação                                  |
| `chore/`     | Infra do repo, build, manutenção                 |

Exemplo: `feat/v1.16-tyre-logistics`, `fix/alarm-double-trigger`.

## Push e rebase

- **Nunca** `git push --force`.
- Para rebase de stacked branches (quando um PR a montante muda), use
  **sempre** `git push --force-with-lease` — ele aborta se o remoto tiver
  commits que você ainda não viu, evitando sobrescrever trabalho.
- `main` bloqueia force-push por ruleset. `pr-h` permite (necessário para o
  rebase da pilha), mas a regra `--force-with-lease` continua valendo.

## Convenção de commit

```
tipo(vX.Y.Z): resumo curto no imperativo

Corpo opcional explicando o porquê.
```

`tipo` ∈ `feat`, `fix`, `security`, `arch`, `balance`, `docs`, `chore`.
Inclua a versão-alvo entre parênteses quando o commit fecha uma versão.

## Versionamento e release

- Versão semântica: `MAJOR.MINOR.PATCH`.
- Toda versão liberada recebe:
  1. Entrada no `CHANGELOG.md` (formato [Keep a Changelog](https://keepachangelog.com)).
  2. Tag anotada `vX.Y.Z` no commit de merge em `main`.
  3. GitHub Release com as notas da seção correspondente do CHANGELOG.
- Bump dos 6 READMEs (`README*.md`) quando a versão muda algo visível ao operador.

## Checklist antes de abrir PR

- [ ] `main` como ponto de partida (ou o PR-base correto, se for pilha)
- [ ] Sem segredo/credencial no diff (checar `discord.lua`, configs)
- [ ] Eventos de rede novos têm validação server-side + rate limit
- [ ] Testado em servidor local com QBox
- [ ] `CHANGELOG.md` atualizado se muda comportamento
