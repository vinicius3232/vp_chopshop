# AGENTS.md — orientação para agentes de IA

Leia isto **antes** de qualquer alteração. É o ponto de entrada. O estado atual
(branch, HEAD, fase, o que fazer a seguir) está em [`STATUS.md`](STATUS.md).

---

## 1. O que é o projeto

`vp_chopshop` — resource FiveM/QBox de **chop shop** (desmanche criminoso de
veículos). ~9k linhas de Lua. Server-authoritative: o client **nunca** decide
quantidade, payout, tipo de peça, conclusão, cooldown, identidade de veículo,
sucesso de inventário. O client manda `{ sessionId, action }`; o servidor deriva
o resto.

Domínio: roubo → desmanche (base/advanced) → logística (pneu, truck) → fence
(venda, contratos, entrega de carro) → perícia policial. Fora de escopo: NUI de
tuning, boss menu/society, engine swap "de verdade" (só áudio), persistência de
mods por placa.

## 2. Diretrizes que não se negociam

1. **Trust-no-client.** Todo callback começa com `IsValidSource`/`ServerPlayerIsReady`
   na 1ª linha. 100% SQL parametrizado (nunca concatenação; `IN (...)` só com `?`).
2. **Delegue leitura, nunca julgamento.** OmniRoute (`~/.claude/omniroute/Route-Task.ps1`)
   serve para ler arquivo grande / varrer / resumir / revisar adversarialmente.
   Quem confirma o que volta é você — **≈metade das "descobertas" da revisão não
   sobrevive à conferência**. Cite arquivo:linha ao confirmar ou refutar.
3. **PRs pequenas e empilhadas.** Uma mudança lógica por PR. Base = `pr-h`
   (a branch de integração rolante). Nenhuma PR mergeia sozinha — o **dono dá GO
   explícito por PR** e você **PARA** depois de abrir cada uma.
4. **Todo commit econômico considera:** replay, timeout, disconnect, restart de
   resource, restart de servidor, falha de DB, falha de inventário, race de 2
   jogadores, netId reuse, entidade stale. Fail-closed quando a identidade não
   pode ser provada.
5. **Resposta curta é o padrão.** O gargalo é crédito, não gateway. Documento
   longo só quando pedido.

## 3. NUNCA faça / NUNCA delegue

- **Não reescreva** `ChopSession` / `ActionSession` / `discard` / `deliverCar` /
  `TyreEntitlement` / `carcass_ledger`. São a fundação provada pela suite de testes
  (concorrência, idempotência, transação de dinheiro, fail-closed). Estenda,
  não substitua.
- **Não edite os arquivos do spike** `shared/registry/parts.lua` /
  `registry/tools.lua` / `registry/registry_spec.lua` — schema v2 CONGELADO.
  Mudar a forma reabre a review adversarial. (Adicionar uma peça nova ao registry
  quando a fase pedir é ok; renomear campo/reestruturar não é.)
- **Não delegue** decisão de arquitetura, afirmação sobre schema de banco, revisão
  de teste que usa mock, nem nada onde "confiante e errado" é caro.
- **Não faça `cat`/`type`/leitura integral** de `settings*.json`, `.env*`,
  `secrets`, ou qualquer arquivo no `.gitignore`. Já vazou chave de API 3×.
- **Não toque em `main`** — está em `v1.14.3`. Todo o trabalho de integração vive em `pr-h`.
- **Não copie código de terceiros** (ver `docs/research/EXTERNAL_RESEARCH_MATRIX.md`
  §13 — licenças). Reuso de **conceito**, reimplementação própria.

## 4. Fluxo por PR (o mesmo desde a stack #2→#11)

```
git checkout pr-h/... && git pull
git checkout -b feat/<id>
  implementar
  lua tools/run_spec.lua .              → deve ficar VERDE (baseline atual: consultar STATUS.md)
  luac -p <arquivos tocados>            → limpo (ignore "unexpected symbol near '`'"
                                          — é o hashkey literal do CFX, não é erro seu)
  OmniRoute -Kind challenge no diff     → CONFERIR cada achado você mesmo
  git commit -q -m "..."  (Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>)
  git push -u origin <branch>
  gh pr create --base pr-h/...
  atualizar a memória do projeto
PARAR — aguardar GO do dono
```

Depois do GO: `gh pr merge <n> --squash --delete-branch`.

**Regra de push (dura):** **nunca** `git push --force`. Quando um rebase da stack
exigir reescrever um branch remoto, usar **sempre** `git push --force-with-lease`
(aborta se o remoto tiver commits que você não viu). `main` bloqueia force-push
por ruleset; `pr-h` permite (rebase da stack) — mas só com `--force-with-lease`.

**CI:** todo PR para `main` ou `pr-h` roda o workflow `harness`
(`.github/workflows/harness.yml`): `luac -p` + `lua tools/run_spec.lua .`. O
critério é o **exit code** do harness, não o número de asserts. `run_spec.lua`
sai `!= 0` se qualquer spec falha **ou** se 0 asserts forem contados.

## 5. Onde está a verdade (authority map)

| Assunto | Doc / arquivo canônico |
|---|---|
| **O que fazer a seguir** | [`STATUS.md`](STATUS.md) |
| **Roadmap completo** (Fases 0–5, `Pn.x`) | [`docs/design/MASTER_IMPLEMENTATION_PLAN.md`](docs/design/MASTER_IMPLEMENTATION_PLAN.md) |
| Invariantes Canônicos Forenses v1.18 | [`docs/V118_RELEASE_INVARIANTS.md`](docs/V118_RELEASE_INVARIANTS.md) |
| Matriz de Live QA Forense v1.18 | [`docs/V118_LIVE_QA.md`](docs/V118_LIVE_QA.md) |
| Invariantes Canônicos Broker/Workshop v1.17 | [`docs/BROKER-6_RELEASE_INVARIANTS.md`](docs/BROKER-6_RELEASE_INVARIANTS.md) |
| Matriz de Live QA Broker v1.17 | [`docs/BROKER-6_LIVE_QA.md`](docs/BROKER-6_LIVE_QA.md) |
| Definição de peça (bones, tool, deps, gates, carry, reward, minigame) | `shared/registry/parts.lua` (**autoridade**, congelado) |
| Classe GTA de peça (`'door'/'tyre'`) | `VPChopPartGtaClass(id)` em `shared/part_class.lua` |
| Ferramentas | `Config.Tools` (saw_cheap/saw_pro/mechanic_drill) + `shared/registry/tools.lua` |
| Migração do registry (FASE A→F) | `docs/design/PART_REGISTRY_MIGRATION.md` · review: `PART_REGISTRY_REVIEW.md` |
| Processamento de peça na bancada (futuro) | `docs/design/PART_PROCESSING_RFC.md` |
| Estado de desmanche de um veículo | `server/session/chop_session.lua` (`ChopSession`, in-memory) |
| Autorização temporal de ação | `server/session/action_session.lua` (`ActionSession`) |
| Barreira anti re-discard pós-restart | `server/session/carcass_ledger.lua` + tabela `vp_chop_carcass` |
| Identidade de veículo | `vsid` (`server/session/chop_session.lua`) + `bridge/server_vehicle.lua` (qbx). Placa é lookup, nunca identidade. |
| Plano de QA da v1.15 RC (26 fases) | `docs/audit/V115_RELEASE_CANDIDATE.md` + `RC_QA_TASKLIST.md` |
| Plano de QA da integração v1.16 | `docs/audit/V116_INTEGRATION_QA.md` |
| Pesquisa externa (matriz, restart study, roadmap reconciliation) | `docs/research/` |
| Eventos internos | `shared/events.lua` (`VPChopEvt`) |

## 6. Build & teste

- **Harness estático** (fora do FiveM): `lua tools/run_spec.lua .` — roda todas as suites registradas (baseline atual: consultar [`STATUS.md`](STATUS.md)). Stub completo dos globals CFX no topo de `run_spec.lua`.
- Specs são self-gated na convar `vp_chopshop_selftest 1` (no servidor real também).
- `luac -p` para checar sintaxe. O erro `unexpected symbol near '` `'` é o literal
  hashkey do CFX (`` `prop_name` ``) — **não** é um erro seu; filtre com
  `grep -v "near '\`'"`.
- **Teste de runtime (in-game) só o dono/QA roda.** O harness não cobre client,
  economia real, resmon nem multiplayer.

## 7. Sistemas KEEP (já corretos — não regredir)

VehicleSessionId · ChopSession FSM · jackstand server-auth · o invariante
"tempo sozinho nunca destrói committed state" · identidade via `vsid` ·
anti-exploit (100% `IsValidSource`, 100% SQL parametrizado) · concorrência
(`LockPart`/`PinPartLock`/`OpenBySrc`) · 0 threads por-frame · bridges QBox-first.
