# vp_chopshop — FASE ZERO / Auditoria pré-v1.15

> Diagnóstico. Nenhuma feature nova. Nenhum código de gameplay alterado nesta entrega.

## 1. CURRENT STATE

| Campo | Valor |
|---|---|
| Repo | github.com/vinicius3232/vp_chopshop |
| Branch | `main` |
| HEAD SHA | `92ded339b227c6882a94771ecf3eb6da2e2f946d` |
| Data HEAD | 2026-06-27 |
| Versão declarada | v1.14.3 (CHANGELOG; **não há git tags**) |
| Tamanho | ~9k linhas Lua + ~9k docs/locale/README |
| Framework bridge | QBox (primário), QBCore/ESX marcados "não-testado" no próprio código |
| Deps | ox_lib, ox_inventory, ox_target, oxmysql; opcionais: vp_crimescene, vp_gangs, evidences |

**Arquitetura atual (real):**
- `shared/` — config (1045 linhas, monolítico), events (event bus `VPChopEvt`), locale, chop_parts.
- `bridge/` — framework, inventory, keys(ausente), mdt, evidence, client_notify.
- `server/` — main (God file, 698 linhas: benches, welders, chopPart, discard, tyre truck, alarm), fence, plates, advanced_chop, chop (estado base), progression, heat, partserial, tyremarks, ambush, cooldown, db, validate, discord.
- `client/` — main (1570 linhas), fence, plates, partserial, bench, carry, alarm, welder, progression, tyremarks, placement.
- **Não existe:** ChopSession, ActionSession, Part Registry unificado, Tool Registry unificado, Minigame Provider, BridgeKeys, BridgeGarage.

## 2. MODULE MAP (responsabilidades)

| Módulo | Responsabilidade | Estado |
|---|---|---|
| `server/chop.lua` | Estado "peça X do netId Y removida" (Fase 1 / pneus-porta base). Mutex `netId:partKey`. | OK isolado, **desacoplado do advanced_chop** |
| `server/advanced_chop.lua` | Fases 2/3/4 (portas, motor, carcaça). Tabela `AdvState` **própria**. | Estado paralelo ao de `chop.lua` |
| `server/main.lua` | chopPart callback, discardVehicle, tyre→truck (`addTyreToTruck`), alarme, benches/welders | God file; ver P0/P1 |
| `server/fence.lua` | Trust, venda de itens, venda de pneus, entrega de carro, orders, **eventos de pneu** | ver P0 |
| `server/plates.lua` | Roubo de placa física, placas falsas, mapeamento placa real, hook garagem | ver P1 (witnessScore) |
| `server/progression.lua` | XP/tier, persistência `vp_chop_progression` | ver P2 (stale-write) |
| `server/partserial.lua` | Série em `car_parts` (procedência), scratch/forge, peças legais | base sólida p/ PartSerial 2.0 |
| `server/heat.lua` | Heat por placa, VIN scratch | OK |
| `server/tyremarks.lua` | Marcas de pneu forenses, janela armada server-side | OK |
| `bridge/server_framework.lua` | `IsValidSource`, `ServerPlayerIsReady`, `BridgeAddCash`, `BridgeCountCops` | sem `BridgeHasVehicleAccess` |
| `server/validate.lua` | `ValidatePlayerNearPoint/Vehicle` | usado de forma consistente |

## 3. EVENT MATRIX

Ver [`EVENT_MATRIX.md`](EVENT_MATRIX.md).

## 4. SECURITY AUDIT (resumo por severidade)

### P0 — bloqueia v1.15

| ID | Local | Problema | Impacto |
|---|---|---|---|
| **P0-1** | `server/fence.lua:282` `vp_chopshop:tyre:truckLoad` **+** `server/main.lua:143` `vp_chopshop:server:addTyreToTruck` | **Duas implementações concorrentes** que incrementam `ServerTyreCounts[netId]` a partir de evento do cliente, **sem consumir item nem entitlement**. Só há proximidade (8m) + rate-limit (3s). | Cheater perto de qualquer caminhão enche o storage (até `MaxTyresInTruck`) sem ter pneu nenhum. |
| **P0-2** | `server/fence.lua:439` `vp_chopshop:fence:sellTyres` (ramo `truck`) | Paga `ServerTyreCounts[nid]` só validando `DoesEntityExist(truck)` — **não valida distância do jogador ao caminhão, nem modelo/classe**. Limpa o contador e chama `BridgeAddCash` **sem checar retorno**. | Combinado com P0-1: loop `truckLoad` ×N → `sellTyres` → cash do nada. |
| **P0-3** | `server/fence.lua:228` `vp_chopshop:tyres:jackstandTyreStolen` | Servidor entrega `chopshop_tyre` **sem prova de que uma roda real foi desmontada**. Não há ChopSession, estado de roda, nem token de minigame. Mitigado a "4 por netId" via `JackstandTyreCount`, mas repetível em cada veículo e reset no reuso de netId. | Geração de item ilícita (4/veículo, ilimitada em nº de veículos). |
| **P0-4** | `server/main.lua:473` `vp_chopshop:discardVehicle` | **Sem mutex.** Dois callbacks simultâneos passam o gate `partCount>=minParts` e ambos chamam `BridgeAddCash` antes de `VPChopClearVehicle`. `deliverCar` tem mutex; `discardVehicle` não. | Double-payout no discard. |

### P1

| ID | Local | Problema |
|---|---|---|
| P1-1 | `server/advanced_chop.lua` (todo) | Header diz "requer jackstand levantado" mas **nenhum callback checa estado de elevação**. Jackstand é 100% client-side. Fases 2/3/4 executáveis sem carro no macaco. |
| P1-2 | `server/plates.lua:145` `stealPlate` | `witnessScore` vem do **cliente** e alimenta `witnessDispatchChance` (menos polícia) e `applyWitnessBonus` (cash+XP). Capado, mas é confiança em valor do cliente. |
| P1-3 | `bridge/server_framework.lua:264` `BridgeAddCash` | Retorna bool; **`sellItems`, `sellTyres`, `discardVehicle`, `deliverCar` ignoram o retorno**. AddMoney falha depois do `RemoveItem` → jogador perde item e não recebe cash. Sem rollback. |
| P1-4 | `server/main.lua:473` `discardVehicle` | `DeleteEntity(veh)` direto. Sem `BridgeDeleteVehicle`, sem guard de veículo owned/persistente, sem update de garagem. Carro de jogador que entre no pátio é deletado. |
| P1-5 | falta de ActionSession | `chopPart`, `adv:*`, `stealPlate`, `sellTyres` — cliente chama o callback diretamente após seu próprio minigame. Server não valida que o minigame ocorreu nem tempo decorrido (`minimumActionDuration`). Gates atuais: item + proximidade + not-done + rate-limit + mutex. |

### P2

| ID | Local | Problema |
|---|---|---|
| P2-1 | `server/progression.lua:91` | Persistência em `CreateThread` por chamada. Cache em memória correto, mas **duas chamadas em rajada geram duas threads `MySQL.query.await` sem ordem garantida** → DB pode gravar valor stale; cache é descartado no `playerDropped` (último write no DB vence). Sem writer serializado/queue/versioning. |
| P2-2 | `server/chop.lua` vs `server/advanced_chop.lua` | Estado de desmanche **dividido** (`ChoppedByNetId` × `AdvState`). `VPChopClearVehicle` (discard) limpa só o de `chop.lua`; `AdvState` fica stale até `entityRemoved`. `discardVehicle` conta `minParts` só das peças base — peças avançadas não contam. |
| P2-3 | `shared/config.lua` (1045 linhas) | Config monolítico; sem separação gameplay/balance/integration. Duas fontes de dados de ferramenta (`Config.Tools` + regras espalhadas em `Config.CarPartRewards`/`AdvancedChop`). |
| P2-4 | Identidade de veículo | Todo o sistema usa `netId` como chave persistente (`ServerTyreCounts`, `ChoppedByNetId`, `AdvState`, `PlateStolen`). NetId reutilizável → estado antigo aplicável a veículo novo. Sem `VehicleSessionId`. |

### P3

| ID | Problema |
|---|---|
| P3-1 | `stream/bolt.ydr` + `stream/wheel_spacer.ytyp` — CHANGELOG 1.14.3 admite: "idênticos aos do pacote pago `ls_bolt_minigame` (Lith Studios)". Estão versionados no repo público. **Redistribuição de asset comercial.** Ver §6. |
| P3-2 | `server/main.lua` é God file (benches, welders, chop, discard, tyre, alarm). Dificulta review incremental. |
| P3-3 | QBCore/ESX marcados no código como "PORTABILIDADE não-testada" mas READMEs sugerem suporte. Alinhar linguagem → EXPERIMENTAL. |

## 5. PREVIOUS FINDINGS VALIDATION

| Achado anterior | Classificação | Evidência |
|---|---|---|
| tyre grant exploit | **PARTIALLY FIXED** | `fence.lua:228` tem rate-limit + proximidade + cap 4/netId, mas nenhuma prova de roda real desmontada. |
| truck storage exploit | **CONFIRMED** | `fence.lua:282` + `main.lua:143` incrementam sem consumir item; duas impls. |
| truck sale validation | **PARTIALLY FIXED** | `fence.lua:439` valida trust + fence + mutex + existência do truck; **falta distância ao truck e modelo**. |
| client jackstand authority | **CONFIRMED** | `advanced_chop.lua` não checa estado de elevação em nenhum callback. |
| client key authority | **CONFIRMED (ausência)** | Não há `BridgeHasVehicleAccess`; `Config.RequireVehicleKeys` não é revalidado server-side. |
| tool config drift | **CONFIRMED** | `Config.Tools` + regras duplicadas; sem Tool Registry. |
| base/advanced discard state split | **CONFIRMED** | `ChoppedByNetId` (chop.lua) × `AdvState` (advanced_chop.lua); clear parcial no discard. |
| XP stale write race | **PARTIALLY FIXED** | `progression.lua:91` snapshot completo por write reduz janela, mas threads concorrentes sem ordem. |
| ignored AddMoney results | **CONFIRMED** | `BridgeAddCash` retorna bool; 4 callers ignoram. |
| inventory full handling | **PARTIALLY FIXED** | `AddItem` é checado em quase todos os pontos (notifica), mas alguns marcam a peça como chopada mesmo com inventário cheio (item perdido). |
| witnessScore trust | **CONFIRMED** | `plates.lua:145` recebe do cliente, capado. |
| tool metadata slot handling | **PARTIALLY FIXED** | `main.lua:242 VPChopConsumeTool` usa `GetItem` + `RemoveItem(…, prevMeta)` — pega 1 slot, mas escolhe o **primeiro** encontrado, não o de menor/maior durabilidade determinística; comportamento com múltiplos slots de metadata diferente não testado. |
| persistent vehicle deletion | **CONFIRMED** | `main.lua:519 DeleteEntity(veh)` direto no discard. |
| license/asset issue | **CONFIRMED** | CHANGELOG 1.14.3 §Notes. |

## 6. NEW FINDINGS

- **N1 (P0-4):** `discardVehicle` sem mutex → double-payout. (novo)
- **N2 (P2-2):** `discardVehicle.minParts` ignora peças avançadas; `VPChopClearVehicle` não limpa `AdvState`.
- **N3 (P1-3 detalhe):** ordem transacional em `sellTyres` truck-branch: limpa `ServerTyreCounts` **antes** de confirmar `BridgeAddCash`. Se AddCash falhar, pneus somem sem pagamento.
- **N4:** `stealPlate` — `PlateStolen[netId]` como anti-replay via netId; reuso de netId reabre o roubo.
- **N5:** `heat.lua` e `progression.lua` ambos escutam `VPChopEvt.PART_CHOPPED` e ambos fazem SQL — sem coalescing; rajada de chop = várias queries.
- **N6:** nenhum `Config.Debug`/convar central; logs de segurança sem rate-limit próprio (`LogSuspicious` printa sempre).

## 7. TARGET ARCHITECTURE (proposta, aprovar antes de implementar)

```
shared/
  registry/parts.lua      -- PartDefinition{category,bone,tools,minigame,requiresRaised,noise,deps,serialized}
  registry/tools.lua      -- ToolDefinition{actions,maxUses,speed,noise,breakChance}
  session/state.lua       -- enum de estados ChopSession + transições válidas

server/session/
  chop_session.lua        -- ChopSessions[sessionId] fonte única. vehicleSessionId, participants, parts{}, state, locks, storage
  action_session.lua      -- startAction(sid,partId)->{actionId,nonce,expiresAt,allowedTool}; completeAction(actionId) revalida tudo; single-use; minimumActionDuration
  vehicle_identity.lua    -- VehicleSessionId (netId + spawn nonce + plate hash)

bridge/
  keys.lua                -- BridgeHasVehicleAccess(src, veh)
  garage.lua              -- BridgeDeleteVehicle(veh) / BridgeVehiclePersistence
  minigames.lua (client)  -- VPMinigames.Bolt/Cut/Lockpick/Hack/Scan/Wiring -> provider manager

server/transaction.lua    -- Transaction.AddMoney/RemoveMoney/AddItem/RemoveItem/Exchange — sempre com retorno + compensação
```

- **ChopSession** = fonte da verdade do desmanche (substitui `ChoppedByNetId` + `AdvState` + `ServerTyreCounts` + `PlateStolen`).
- **ActionSession** = toda ação com recompensa passa por `startAction`→UX→`completeAction`.
- **Estados:** CREATED → PREPARING → RAISED → DISMANTLING → PROCESSING → READY_FOR_DISCARD → COMPLETED / CANCELLED. Transições explícitas; peça exige pré-requisitos do Part Graph.
- Jackstand vira `session.state == RAISED` server-side.
- Pneu: só nasce como entitlement one-time gerado pelo `completeAction` de uma `wheel_*` da sessão.

## 8. MIGRATION PLAN (arquivo por arquivo) — v1.15

| # | Arquivo(s) | Mudança | Commit |
|---|---|---|---|
| 1 | `server/session/vehicle_identity.lua` (novo) | VehicleSessionId | `arch: vehicle session id` |
| 2 | `server/session/chop_session.lua` (novo) | Registry + timeout + cleanup em playerDropped/entityRemoved | `arch: add chop session registry` |
| 3 | `server/session/action_session.lua` (novo) | startAction/completeAction, nonce single-use, minDuration | `arch: add action session` |
| 4 | `server/fence.lua` | **Remover** `jackstandTyreStolen`, `tyre:truckLoad`. Pneu via entitlement da ChopSession. `sellTyres` valida distância ao truck + modelo + Transaction. | `security: close tyre grant + storage exploit` |
| 5 | `server/main.lua` | **Remover** `addTyreToTruck`. `discardVehicle`: mutex + `BridgeDeleteVehicle` + guard owned + Transaction. `chopPart` passa por ActionSession. | `security: unify truck storage; fix discard` |
| 6 | `server/advanced_chop.lua` | Ler estado da ChopSession; exigir `state==RAISED`; Part Graph deps; ActionSession. | `refactor: advanced chop uses chop session` |
| 7 | `server/chop.lua` | Estado migra p/ ChopSession; manter só helpers. | `refactor: unify part state` |
| 8 | `shared/registry/parts.lua`, `tools.lua` (novos) | Fonte única. `main.lua`/`advanced_chop.lua` consomem. | `refactor: unify tool + part registry` |
| 9 | `bridge/keys.lua` (novo) + call sites | `BridgeHasVehicleAccess` revalidado quando `Config.RequireVehicleKeys`. | `security: server-side vehicle access` |
| 10 | `server/transaction.lua` (novo) | Wrapper com retorno + compensação; refactor dos 4 call sites de `BridgeAddCash`. | `refactor: transaction service` |
| 11 | `server/progression.lua` | Writer serializado (fila por identifier) ou `xp = xp + ?` atômico no SQL. | `fix: xp persistence stale-write` |
| 12 | `server/plates.lua` | `witnessScore` calculado server-side (players próximos + zona + hora); client info só cosmética. | `security: server-side witness score` |
| 13 | `shared/config.lua` | Split em `config/gameplay.lua` / `balance.lua` / `integration.lua`. `Config.Debug`. | `refactor: split config` |
| 14 | eventos legados | Marcar deprecated, remover no fim da fase. | `chore: remove deprecated tyre events` |

## 9. TEST PLAN

**Exploit (esperado: DENY):** chop sem session; chop sem RAISED; chop remoto; netId falso; entidade deletada; modelo errado; mesma peça 2×; mesma peça 2 players simultâneos; instant-complete (<minDuration); replay actionId; actionId de outro player; `truckLoad` sem pneu; pneu duplicado; truck remoto/inválido/modelo falso; venda de storage remoto; amount/price/condition/xp/witnessScore falso; motor antes de pré-requisitos; discard cedo demais; **discard duplo simultâneo**.

**Funcional:** fluxo completo street chop + full chop QBox; alarme; placas + placa falsa; série de peça; heat; marca de pneu; order; entrega de carro.

**Multiplayer (2–4 clients):** mesmo veículo; mesma roda; peças diferentes; veículo em movimento; motorista entra; veículo destruído durante ação; player sai no meio; ownership da sessão.

**Inventário:** cheio; mesmo item múltiplos slots; durabilidades diferentes (tool A=10 / B=90); RemoveItem falha; AddItem falha.

**Econômico:** AddMoney falha; RemoveMoney falha; DB down; disconnect durante pagamento; restart do resource; requests duplicados.

**Performance:** idle; minigame de roda ativo; full chop; 4 players. Comparar antes/depois (baseline atual a capturar).

**Regressão:** Fence, plates, fake plates, serial, evidence, tyre marks, heat, ambush, progression, bench, discard, hook de garagem.

## 10. PR / COMMIT PLAN (ordem exata)

1. `docs: fase zero audit (este doc + event matrix)` ← **esta entrega**
2. `security: close tyre grant event exploit` (remove `jackstandTyreStolen`, entitlement stub)
3. `security: unify truck tyre storage` (remove `addTyreToTruck`, 1 API)
4. `security: validate tyre sale (distance + model + transaction order)`
5. `security: add discard mutex + BridgeDeleteVehicle`
6. `arch: add vehicle session id`
7. `arch: add chop session registry`
8. `arch: add action session + replay protection`
9. `refactor: migrate jackstand state to chop session (RAISED)`
10. `refactor: base chop uses chop session`
11. `refactor: advanced chop uses chop session + part graph`
12. `refactor: unify discard state`
13. `refactor: unify tool registry`
14. `security: server-side vehicle access bridge`
15. `refactor: transaction service + fix ignored AddMoney`
16. `fix: xp persistence stale-write`
17. `security: server-side witness score`
18. `chore: remove deprecated events`
19. `test: exploit matrix + replay cases`
20. `docs: v1.15 changelog + framework status`

**GATE v1.15:** zero P0 conhecido; matriz de exploit passa; 2-player race passa; QBox core gameplay passa.

---

### Assets a remover antes de qualquer release público (§6 / P3-1)

`stream/bolt.ydr`, `stream/wheel_spacer.ytyp` — associados ao pacote pago `ls_bolt_minigame`.
Ação: (a) substituir por prop próprio OU usar como dependência externa opcional (`GetResourceState`);
(b) `git rm` + entrada no `.gitignore`; (c) purge do histórico (`git filter-repo`) antes de tornar o repo público, se aplicável.
O minigame de parafuso interno já tem fallback "modo marcador" (`DrawMarker`) que não depende do asset — base para o Bolt V2 interno.
