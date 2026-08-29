# MASTER_IMPLEMENTATION_PLAN — vp_chopshop v1.16-dev

**Base:** `pr-h/v1.15-delivercar-terminal-hardening` · **Harness:** 632 PASS / 0 FAIL
**Progresso:** ver [`STATUS.md`](../../STATUS.md) na raiz. Este doc é o roadmap completo.

---

## 1. Registro de decisão

**2026-08-28 — o dono suspendeu o RC freeze.** Justificativa: a direção está
decidida (chop shop modular + processamento de peça); manter a v1.15 congelada
para a QA testar um código que já vai ser reescrito é desperdício de esforço de
teste. **Novo alvo:** um build consolidado (`v1.16-dev`) que a equipe de teste
valida como um todo, já moldado para o que se quer.

**O que isto NÃO significa:** reescrever `ChopSession` / `ActionSession` /
`discard` / `deliverCar` do zero. São 500+ asserts sobre a parte mais difícil de
acertar (concorrência, idempotência, transação de dinheiro, netId reuse,
fail-closed). **Esses primitivos são a fundação.** "Do zero" aqui = completar e
consolidar tudo em volta deles; construir os elos que faltam (`Part Registry`,
`interaction`, `vehicle_part`, `ProcessSession`, `VehicleSecurity`, contratos),
não jogar fora o núcleo provado.

**O que passa a valer:** GO ARQUITETURAL e GO DE RELEASE colapsam num só fluxo —
cada sistema entra como PR em `pr-h`, com harness verde, revisão adversarial
(OmniRoute `-Kind challenge`) e **GO explícito do dono por PR**. A QA testa `pr-h`;
`main` fica em `v1.14.3` até a validação completa.

---

## 2. Estratégia de branch

`pr-h` é a **branch de integração rolante**. Cada item (`Pn.x`) = uma branch
`feat/v1.16-<id>` a partir de `pr-h`, PR com base `pr-h`, squash-merge em `pr-h`
após o GO. `main` intocado.

### Checklist por PR
Ver [`AGENTS.md`](../../AGENTS.md) §4. Resumo: implementar → `lua tools/run_spec.lua .`
verde → `luac -p` → OmniRoute challenge (conferir os achados) → commit pequeno →
push → PR base `pr-h` → memória → **PARAR** para GO.

---

## 3. Sequência consolidada

Funde: `PART_PROCESSING_RFC` + `ROADMAP_AUDIT` (#12→#26) + Part Registry spike
(FASE A→F) + RC-FINDING-01 (minigame) + `docs/research/RESTART_RECOVERY_STUDY`.

### FASE 0 — base + dores concretas da QA ✅ COMPLETA

| ID | O quê | PR |
|---|---|---|
| **P0.1** | Branch de integração + baseline. | — |
| **P0.2** | **Minigame de placa** — `VPChopPlateBoltMinigame(vehicle, isRear)`: a face deixa de ser hardcoded na traseira (`client/plates.lua` resolve por `GetOffsetFromEntityGivenWorldCoords .y>0`); `runBoltSurface` endurecido (clamp de giro; degrada p/ skillCheck se nada projeta >2.5s). **Asset pago `stream/bolt.ydr`+`wheel_spacer.ytyp` removido**; `stream/` esvaziado (`nacelle.*`/`lr_supermod_*` = elevador morto). `Bolt3D.Enable=false` (skillCheck ativo). | **#14** |
| **P0.3** | **chore M1+M2** — 4 notificações server hardcoded → `L()` (5 chaves × 5 idiomas); bloco morto de props de pneu removido de `client/fence.lua` (−215 linhas). Zero mudança de comportamento. | **#15** |
| **P0.4** | **Restart recovery** — tabela `vp_chop_carcass` (PK net_id+model, TTL 1800s), `server/session/carcass_ledger.lua` (`VPChopCarcassLedger`, DB seam injetável, 32 asserts), barreira `alreadyProcessed` **antes** do pagamento do discard → `already_discarded`, `server/session/restart_recovery.lua` (sweep de boot, só re-deleta com match de `vsid` vivo). Fecha a dupe da Fase 20 do RC. Barreira do `deliverCar` **inalterada** (statebag `vpChopDeliveredMark`). `Config.RestartRecovery`. | **#16** |

### FASE 1 — Part Registry vira a autoridade ✅ COMPLETA

| ID | O quê | PR |
|---|---|---|
| **P1.1** | `shared/registry/{tools,parts,registry_spec}.lua` (spike, schema v2 congelado, 28 asserts) trazidos INERTES. **DRIFT CHECK: zero drift** (P0.* não tocou ChopParts/Config.Tools/MinDurationMs/advanced_chop). | **#17** |
| **P1.2** (FASE B) | `shared/chop_parts.lua` vira projeção de `VPChopPartRegistry.projectChopParts()` (byte-a-byte). | **#18** |
| **P1.3** (FASE C) | `bonnet` valida via `registryValidate` (vertical slice); demais no hardcode. | **#19** |
| **P1.4** (FASE D) | `adv_door`/`adv_engine`/`adv_carcass` validam via registry (`requires`/`toolClass`/`gates`); fallback hardcode por kind. | **#20** |
| **P1.5** (FASE E) | Registry OBRIGATÓRIO (`error()` no load); fallbacks removidos. `Config.AdvancedChop.SawItem`/`ScrewdriverItem` mortos removidos. **Capability nova:** `enabled=false` por peça → `'part'` (inchopável). | **#21** |
| **P1.6** (FASE F) | 11 sites server saem de `ChopParts[k].kind` → `VPChopPartGtaClass(k)`. | **#22** |
| **P2.1** (enxuto) | 6 sites client saem de `ChopParts` → `VPChopPartRegistry.get()`. `chop_parts.lua` deletado → `shared/part_class.lua` (só `VPChopPartGtaClass`). **`ChopParts`/`ChopPartOrder` não existem mais.** | **#23** |

### CHECKPOINT DE QA ⏸ — a bola está aqui

`docs/audit/V116_INTEGRATION_QA.md` (**#24**). Deploy da `pr-h` num servidor QBox
e rodar Q1–Q5. **Fase 2 só começa depois de Q1–Q4 sem FAIL P0/P1.**

### FASE 2 — peça física + interação  *(AUDIT #14-17)* ⏸

| ID | O quê |
|---|---|
| **P2.2** | **Wheels V2** — state machine server-side `AVAILABLE→LOCKED→REMOVED→CARRIED→STORED` (o `REMOVING` e subestados são **view do client**, não estado autoritativo — ver `INTERACTIVE_DISMANTLING.md` §5); `bridge/minigames.lua` provider dirigido por `Registry.action.minigame`. Detalhado como **ID-2** (domínio) + **ID-3** (bolt provider) no design doc §11. |
| **P2.3** | `server/vehicle_condition.lua` — `VehicleConditionSnapshot` 1×/ChopSession via `lib.getVehicleProperties`; client mede → server clampa → economia usa snapshot. |
| **P2.4** | `vehicle_part{partType='engine'}` — motor deixa de ser 5× `car_parts`; vira peça com metadata server-only. **Aqui** entra o carry genérico (`PartEntitlement` estende `TyreEntitlement`, `PartStorage` estende `TruckStorage`) e o `client/interaction.lua` (resolve ponto por bone/offset). Não antes — sem peça não-pneu carregável, é churn. |

**Design consolidado da interação física (research + arquitetura + roadmap de PRs ID-0..ID-8):**
[`INTERACTIVE_DISMANTLING.md`](INTERACTIVE_DISMANTLING.md) ·
[`INTERACTIVE_DISMANTLING_RESEARCH.md`](INTERACTIVE_DISMANTLING_RESEARCH.md) ·
[`WHEEL_BOLT_MINIGAME.md`](WHEEL_BOLT_MINIGAME.md). Providers dirigidos por
`Registry.action.minigame` (`bolt`/`cut`/`mechanical`/`wiring`/`skillcheck`). Todas as PRs de
implementação bloqueadas pelo gate Q1–Q4.

### FASE 3 — processamento de peça  *(PART_PROCESSING_RFC #12-17)* ⏸

`vehicle_part` genérico + `Config.PartProcessing` · `ProcessSession` (espelha
ActionSession, sem veículo) + specs PROC1-20 · executor + quarentena · bench UX ·
forense `processed` · contrato de oficina (`ConsumeCarParts`/`QueryCarParts` +
`bridge/workshop.lua`). Ver `docs/design/PART_PROCESSING_RFC.md`.

### FASE 4 — camada de crime  *(AUDIT #18-22)* ⏸

Provenance V2 · `vehicle_security.lua` (alarm/immobilizer/tracker/ecuLock/vin/keys)
· tracker gameplay (`ActionSession(kind=tracker)`) · `contract_session.lua` +
Fence Contracts V2 · Heat V2 (0-100 probabilístico).

### FASE 5 — polish + release ⏸

Split visual do desmanche — **absorvido pelo Interactive Dismantling** (ID-1..ID-8), que já é
"não loop por-frame" por design · **CI gate** (`.github/workflows/spec.yml` — primeiro corrigir
o exit code do harness: hoje `os.exit(1)` só em thread error, não em FAIL de asserção; ver
ID-8) · `Config.Debug` + níveis de log · hardening + soak.

---

## 4. Sistemas KEEP (não tocar — já corretos)

VehicleSessionId · ChopSession FSM · jackstand server-auth · invariante
"tempo sozinho nunca destrói committed state" · identidade via `vsid` ·
anti-exploit · concorrência (`LockPart`/`PinPartLock`/`OpenBySrc`) · 0 threads
por-frame · bridges QBox-first. **IGNORE:** NUI de tuning, boss menu/society,
engine swap real (só áudio), persistência de mods por placa.

## 5. Referências

Reuso de **conceito**, nunca de código (licenças: `docs/research/EXTERNAL_RESEARCH_MATRIX.md`).
`qbx_core/vehicle-persistence` (padrão de P0.4) · `renzu_projectcars` (anti-exemplo
client-authoritative) · `ox_inventory` metadata (P2.4/P3) · `renzu_engine`/`an-engineswap`
(P2.4, quando houver adapter real).
