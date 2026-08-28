# v1.15 — RELEASE CANDIDATE / REAL QBOX INTEGRATION VALIDATION

**Data:** 2026-08-27
**HEAD:** `99371e4` (`pr-h/v1.15-delivercar-terminal-hardening`)
**Harness:** `lua tools/run_spec.lua .` → **493 PASS / 0 FAIL**
(chop_session 75 · adv_gate 18 · base_state 75 · advanced_state 29 · discard_state 94
· tyre_entitlement 54 · deliver_car 57 · action_session 91)

A fase de implementação arquitetural v1.15 está **ENCERRADA** (CODE FREEZE).
Nenhuma PR mergeada. Não iniciar feature nova. Não fazer hardening especulativo.

---

## 1. Stack de PRs (ordem de merge)

```
#2  security/v1.15-p0-hotfix            P0-1..P0-4
#3  arch/v1.15-chop-session             ChopSession core + VSID + jackstand server-auth
#4  pr-a/...advanced-chop-require-raised P1-1 adv_gate
#5  pr-b/...base-chop-to-chopsession     base chop → ChopSession (sem TTL destrutivo)
#6  pr-c/...advanced-state-to-chopsession advanced state → ChopSession
#7  pr-d/...unified-discard              discardVehicle transação terminal + owned/delete safety
#8  pr-e/...tyre-entitlement             TyreEntitlement ledger + TruckStorage identity
#9  pr-f/...action-session-base-tyre     ActionSession core + base tyre vertical slice
#10 pr-g/...advanced-to-action-session   advanced → ActionSession + core hardening
#11 pr-h/...delivercar-terminal-hardening fence:deliverCar + RC-FIX-1a/1b   ← HEAD 99371e4
```

Nenhuma mergeada. GO DE RELEASE ≠ GO ARQUITETURAL — release exige as fases abaixo.

---

## 2. Auditoria 4-dimensões (`/fivem-audit`, HEAD 99371e4)

| severidade | item | ação |
|---|---|---|
| **CRITICAL** | — | 0 |
| **HIGH** | — | 0 |
| **MEDIUM** | **M1** — i18n player-facing parcial: notificações pt-BR hardcoded no servidor (`server/main.lua:330` reward base, `server/advanced_chop.lua:101/187` engine/carcass, `server/ambush.lua:160` loot). `L()` É global server-side (`shared/locale.lua:1360`) mas estes call-sites o ignoram → jogador en/es/fr/tr vê português. **Não afeta autoridade/transação/segurança/economia.** | chore pós-RC |
| **LOW / CHORE** | **M2** — bloco legado morto em `client/fence.lua` (~L460-620: `VPChopSpawnTyreProp` / `PickUp` / `Drop` / `LoadTyreInTruck` / `...FromCarry`). Auto-documentado, sem call-site externo (fluxo vivo = `client/main.lua`). O `GetGamePool` em `client/fence.lua:527` só roda se o fluxo morto for acionado → zero custo idle hoje. | chore pós-RC |
| **OBSERVATION** | Sistema próprio `L()` (tabela Lua, 5 idiomas) em vez de `lib.locale()` + `locales/*.json`. Padrão válido e consistente no client; não há `locales/`. Decisão arquitetural — **não mexer**. | — |
| **OBSERVATION** | Resmon: a análise estática sustenta que a arquitetura aparenta ser leve (0 threads por-frame, `GetGamePool` on-demand/cache 500ms, waits adaptativos, `cache.ped` no hot loop, `#(v1-v2)` em toda distância, 0 `GetDistanceBetweenCoords`). **Números só viram oficiais após profiler/resmon real (Fase 25).** | — |
| **FALSE POSITIVE (fechado)** | `server/plates.lua` `Wait(250)` — one-shot dentro de `entityCreated`; a thread nem é criada quando `DisguiseByReal` está vazio; após 250 ms valida a entidade, consulta cache O(1) e termina. Trocar para 1000 ms só atrasaria a reaplicação visual da placa falsa. **Encerrado sem alteração.** | nenhuma |

**Consolidado:** 0 CRITICAL · 0 HIGH · **1 MEDIUM** (i18n) · 1 LOW/CHORE · 2 OBSERVATIONS · 1 FALSE POSITIVE fechado.
Nenhum problema arquitetural novo. Segurança/transação/autoridade/economia: sólidas
(100% dos callbacks com `IsValidSource`/`ServerPlayerIsReady` na 1ª linha; 100% SQL
parametrizado; `IN (...)` dinâmico só com `?`; trust-no-client completo; valor de
client — `witnessScore` — clampado server-side).

**Pós-RC:** um único commit `chore:` isolado com **M1 + M2**, regressão rápida (493 asserts).
M3 permanece decisão arquitetural. M4 encerrado.

---

## 3. Fases de validação runtime (só o operador roda — servidor QBox real, 2–4 jogadores)

Registrar reprodução + evidência antes de qualquer correção. Correção = `RC-FIX` pequena e isolada.

| # | fase | crítico? | resultado esperado |
|---|---|---|---|
| 1 | Boot / load order | | resource sobe sem erro; `shared/action_gate.lua` client+server; `deliver_car_util.lua` antes de `fence.lua`; executores ActionSession registrados; sweepers ChopSession/ActionSession ativos; TyreEntitlement/TruckStorage ativos; DB Ready = true; sem erro em exports qbx_core/qbx_vehicles; console limpo |
| 2 | Static selftest no runtime | | `vp_chopshop_selftest 1` (dev) → **493 PASS**. Diferença harness↔runtime ⇒ PARAR |
| 3 | ChopSession / jackstand | | sessionId + VSID + marker + raised + participant; B sem participar ⇒ DENY (EnforceRaised=true); EnforceRaised=false ⇒ legacy compat |
| 4 | ActionSession base tyre | | START→OPEN→lock; B na mesma roda ⇒ `processing`; cancel ⇒ CANCELLED + lock liberado + 0 peça/reward/entitlement |
| 5 | COMPLETE real | | OPEN→COMMITTING(pinned)→COMPLETED; wheel REMOVED origin=base; tool -1; reward 1×; PART_CHOPPED 1×; TyreEntitlement 1×; client recebe entitlementId; roda some; prop de carry aparece |
| 6 | Response loss / replay | | `action:complete` 2× ⇒ replay=true, mesmo tyreEntitlementId, 0 side-effect repetido |
| 7 | Timing / tool / distance | | too_fast · distance · no_tool · disconnect em OPEN ⇒ cancel + lock liberado. Nenhum remove peça/recompensa |
| 8 | Tyre logistics | | storageId `ts:*` + marker `vpChopTyreStorageId` write+readback; REMOVED→STORED; count derivada; `chopTyreCount` só UX; recarregar mesmo entitlement ⇒ DENY |
| 9 | Truck concurrency | | load/load · load/sell · sell/sell simultâneos ⇒ 1 storage lock, 0 duplicação, ≤1 payout, SOLD exatamente 1× |
| 10 | Truck lifecycle | | despawn ⇒ STORED→LOST; quem carregou desconecta ⇒ STORED fica; quem tem REMOVED desconecta ⇒ REMOVED→LOST |
| 11 | Advanced ActionSession | | bonnet→engine→carcass; engine antes bonnet ⇒ hood_first; carcass antes engine ⇒ engine_first; carcass sem welder ⇒ no_welder_adv; phases 2/3/4; PART_CHOPPED 1×; cooldown 3s; tool no START+COMPLETE |
| 12 | Discard | | 2 base + 2 advanced, MinPartsToDiscard=4 ⇒ permitido; `VPChopGetPartCount` ainda base-only; READY_FOR_DISCARD→payment→COMPLETED→BridgeDeleteWorldVehicle |
| 13 | Discard concurrency | | A e B mesmo carro ⇒ 1 session, 1 lock, 1 payout, 1 CAR_DISCARDED, 1 tombstone |
| 14 | Owned vehicle | | QBox persistido real ⇒ discard DENY owned + deliverCar DENY owned; state.vehicleid; lookup qbx_vehicles; registro DB permanece; entidade não deletada |
| 15 | Fake plate + ownership | | OWNED com fake plate ativa ⇒ ownership continua OWNED; não vira not_owned pela placa fake; testar discard + deliverCar |
| 16 | QBox delete | | not_owned legítimo ⇒ `DisablePersistence` OCORRE + DeleteEntity; entity não reaparece; 0 registro player_vehicle afetado |
| 17 | Delete failure (injeção) | | discard: jogador pago + COMPLETED + cleanupPending + retry não re-paga. deliverCar: cooldown reservado + jogador pago + marker permanece + cleanupPending + retry não re-paga |
| 18 | NetID reuse | | retry destrutiva nunca toca entidade cujo VSID / delivery marker / storage marker não corresponda; mesmo modelo NÃO basta |
| **19** | **Resource restart + `vpChopDeliveredMark`** | **★ MAIS CRÍTICO** | deliverCar cleanupPending (pago, carro fica, marker presente) → `ensure vp_chopshop` → player B tenta a mesma entidade ⇒ **`already_delivered`**, 0 segundo payout. **Registrar se o statebag server-local sobrevive ao restart no OneSync real** — NÃO assumir pelo harness. Se NÃO sobreviver ⇒ **P1**, muda a estratégia da barreira |
| 20 | Discard + resource restart | | ChopSession é in-memory: sessão parcialmente desmontada → restart → registrar state visual / parts / entity / re-chop / impacto econômico. **Define se persistência da ChopSession é requisito v1.15 ou v1.16.** NÃO corrigir nesta RC sem planejamento |
| 21 | deliverCar (ordem observável) | | not_owned real ⇒ cooldown reserve → marker → cash → delete → trust/event; conferir `last_car_delivery` no MySQL; 2º jogador mesma entidade ⇒ não recebe; mesmo jogador outro carro <20 min ⇒ cooldown |
| 22 | Failure injection deliverCar | | A: reserve affected=0 ⇒ cash 0. B: marker write/readback fail ⇒ cash 0. C: BridgeAddCash false ⇒ cooldown rollback + marker removido + carro fica. D: delete fail ⇒ payout válido + marker fica + cleanupPending |
| 23 | Observability RC-FIX-1a/1b | | durante F22 confirmar: `rollbackCooldown` valida affectedRows==1; `clearMark` failure loga SEVERE. Reprodutível ⇒ já coberto por `99371e4`; caso contrário nada a fazer |
| 24 | Economia | | antes/depois (cash, inventory, tyre count, XP, trust, heat) para tyre sale / discard / deliverCar. Nenhuma operação gera valor 2× |
| 25 | Resmon | | idle · perto do chop · ActionSession OPEN · advanced · truck load · truck sale · discard. ActionSession event-driven, sem loop por action. Registrar client ms + server ms |
| 26 | Soak test | | 2–4 jogadores, 30–60 min: chops/cancels/disconnects/loads/sells/advanced/discard/deliverCar. Buscar locks presos, tombstones errados, session/storage/entitlement leak, duplicate payouts, console errors |

---

## 4. Merge decision

**Estado atual: `C) NOT READY`** — exclusivamente por ausência da validação runtime. Nenhum defeito estático conhecido.

Caminho para **`A) READY FOR STACK MERGE`**:
1. Fase 2 selftest = 493 PASS no servidor;
2. Fases 3–18, 21–26 sem FAIL P0/P1;
3. **Fase 19** confirmando que `vpChopDeliveredMark` sobrevive a `ensure vp_chopshop` no OneSync real;
4. Fase 20 documentada + veredito explícito (release com a limitação in-memory da ChopSession, ou adiar para v1.16);
5. RC-FIX-1a/1b já em `99371e4`.

**`B) READY AFTER RC-FIX`** se a injeção de falha (F17/F19/F22) reproduzir algo — então RC-FIX mínima baseada em evidência.

## 5. Release blockers candidatos (a confirmar no servidor)

- **P1 potencial** — statebag server-local não sobreviver ao resource restart (F19). Cai a barreira anti-revenda pós-restart.
- **P1/P2 a classificar** — ChopSession in-memory + restart (F20). Já conhecido; precisa de veredito de release.
- **P3 (não-blocker de código, mas de distribuição)** — assets `stream/bolt.ydr` + `stream/wheel_spacer.ytyp` do pacote pago `ls_bolt_minigame`. Remover / substituir / purge de histórico antes de repo público. Minigame interno já tem fallback "modo marcador".

---

## 7. RC FINDINGS (feedback runtime da QA)

### RC-FINDING-01 — minigame de parafusos 3D quebrado (placa + roda)
**Data:** 2026-08-27 · **Fase:** pré-3 (interação com veículo) · **Severidade:** BLOCKER de teste (não é regressão da stack #2→#11 — código de placas/jackstand é anterior).

**Sintomas (QA):**
1. Ao roubar placa, os 4 parafusos (marcadores) aparecem flutuando no ar sob o chassi/diferencial, **fora da placa** → impossível concluir → "Teste de perícia falhou".
2. Roubando a placa **da frente**, a câmera vai para a **traseira** do carro.
3. "Placa ficou fora do quadro no carro" (a confirmar: marcadores vs mesh da placa).
4. "Tentou realizar ações no carro com as ferramentas e não apareceu ação" (a confirmar: qual ação / carro levantado? / alvo).

**Root cause (código):**
- `client/main.lua:873-877` `VPChopPlateBoltMinigame` calcula o centro da placa **sempre na traseira** (`yRear = vmin.y - PlateYOffset`) e a câmera atrás (`camPos` em `-y`), **ignorando** qual placa o jogador mira. `client/plates.lua` `onSelect` chama `VPChopPlateBoltMinigame(veh)` sem parâmetro frente/traseira.
- `Config.Plates.Bolt3D` (`shared/config.lua:435`) e `Config.Jackstand.Minigame.Bolt3D` (`:901`) usam **geometria placeholder** — o próprio código/config diz *"As medidas da placa são placeholders geométricos — calibrar in-game"*, *"placeholder: calibrar in-game via ZFrac/YOffset"*. `PlateZFrac=0.30 / PlateYOffset=0.02 / PlateHalfWidth=0.20 / PlateHalfHeight=0.07` nunca foram calibrados → pontos dos parafusos caem no lugar errado (bate com o screenshot).
- Relacionado ao P3 da auditoria: o modelo `bolt.ydr` é do pacote pago `ls_bolt_minigame`.

**RC-FIX-2 proposta (CONFIG-ONLY, zero código):**
```lua
-- shared/config.lua
Config.Plates.Bolt3D.Enable = false              -- :436  → cai em Config.Plates.SkillCheck (lib.skillCheck, já válido)
Config.Jackstand.Minigame.Bolt3D.Enable = false  -- :902  → cai em boii_minigames / lib.skillCheck (SkillCheck* já válido)
```
Efeito: roubo de placa e remoção de roda passam a usar `lib.skillCheck` (provado). Elimina câmera, marcadores flutuantes e o problema frente/traseira. O minigame 3D + remoção do asset `bolt.ydr` viram tarefa pós-RC (com a P3).
Fallbacks confirmados no código: `client/plates.lua:110-118` (plate) e `client/main.lua:973-975` (`runWheelUx` só chama `VPChopBoltMinigame` se `mg.Enable`).

**Pendente de confirmação da QA (antes de decidir se há mais que RC-FIX-2):**
- Q1: o roubo da placa **completou** (recebeu item `stolen_plate` + placa visível sumiu) apesar do minigame, ou falhou inteiro?
- Q2: "placa fora do quadro" = os marcadores do minigame, ou o mesh da placa está deslocado no modelo do veículo? Qual veículo?
- Q3: "não apareceu ação com ferramentas" — qual ação (levantar macaco / desmanche / roubo de placa)? O carro estava levantado? O que mirou com o ox_target? Qual item equipado?

**Status:** RC-FIX-2 **APLICADA** (`shared/config.lua` — `Config.Plates.Bolt3D.Enable=false` :436,
`Config.Jackstand.Minigame.Bolt3D.Enable=false` :906). Config-only, zero código. Q1-Q3 ainda
abertas — se a QA responder que há problema ALÉM do minigame 3D (steal não completa / mesh da
placa deslocado / ação ausente com carro levantado), abrir finding separado.

---

## 6. Pós-RC (só depois do RC real passar)

- `chore:` isolado: **M1** (i18n server hardcoded → `L()`) + **M2** (remover bloco morto `client/fence.lua`). Regressão: 493 asserts.
- Features adiadas (exigem GO explícito, uma de cada vez): plate steal / VIN scratch → ActionSession; Part Registry / Tool Registry; Bolt V2 interno.
