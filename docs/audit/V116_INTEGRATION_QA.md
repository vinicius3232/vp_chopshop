# v1.16-dev — CHECKPOINT DE QA (Fase 0 + Fase 1)

**Data:** 2026-08-28
**Branch a testar:** `pr-h/v1.15-delivercar-terminal-hardening` (após merge dos PRs #14–23)
**Harness estático:** `lua tools/run_spec.lua .` → **632 PASS / 0 FAIL**

Deploy desta branch num servidor QBox real e rode as fases abaixo **antes** de qualquer sistema novo (P2.2+). O objetivo é confirmar que a base de refator não regrediu e que as duas mudanças de runtime da Fase 0 (minigame, restart recovery) funcionam.

Referência de fluxo detalhado: `docs/audit/RC_QA_TASKLIST.md`. Este doc é o **subconjunto que mudou** desde o RC.

---

## O que mudou (resumo por PR)

| PR | Área | Muda runtime? |
|---|---|---|
| #14 | Minigame de placa: frente/traseira-aware; asset pago removido; `stream/` esvaziado | **SIM** (mas `Bolt3D.Enable=false` → cai em `lib.skillCheck`) |
| #15 | i18n: 4 notificações server → `L()`; bloco morto de pneu removido de `client/fence.lua` | cosmético |
| #16 | **Restart recovery**: tabela `vp_chop_carcass`, barreira anti re-discard, sweep de boot | **SIM** |
| #17–#22 | Part Registry vira a autoridade da definição de peça (server + advanced validation) | **refator puro** — harness prova paridade |
| #23 | Client sai de `ChopParts`; `shared/chop_parts.lua` → `shared/part_class.lua` | refator client |

---

## BLOCO Q1 — BOOT & SMOKE  (obrigatório)

### Q1.1 — Boot limpo
1. Importar/migrar o schema (a tabela `vp_chop_carcass` é criada no boot — ver `server/db.lua`).
2. `ensure vp_chopshop`.

**PASS:** console limpo. Sem erro de `VPChopPartRegistry` / `part_class.lua` / `carcass_ledger`. `[vp_chopshop] DB Ready`. O sweep de boot loga `[restart-recovery] sweep: 0 pendentes …` (ou nada se a tabela está vazia).
**FAIL comum a investigar:** `shared/part_class.lua exige VPChopPartRegistry` → ordem do fxmanifest. `attempt to index nil (VPChopPartGtaClass)` → idem.

### Q1.2 — Selftest no runtime
`setr vp_chopshop_selftest 1` → restart → **632 PASS / 0 FAIL**. Depois `setr … 0` → restart.

---

## BLOCO Q2 — DESMANCHE (paridade do registry)  (obrigatório)

O registry agora deriva `toolClass` / `requires` / `gates` / `enabled`. Confirmar que o gameplay é **idêntico** ao RC.

### Q2.1 — Base chop (pneus)
1. Carro não-owned no jackstand. Remover as 4 rodas via ox_target de roda.

**PASS:** cada roda pede serra (`no_saw` sem ferramenta); progress bar; roda some; `car_parts` + `TyreEntitlement` 1×; prop de pneu na mão. Idêntico ao RC.

### Q2.2 — Menu de desmanche (client)
1. Com `Config.AdvancedChop.Enable = false`, abrir o menu do jackstand.

**PASS:** aparecem só bonnet/boot/portas (não-pneu, não-faltando). Labels traduzidas. Com `AdvancedChop.Enable = true` → menu vazio ("nada a desmanchar" — portas viram Fase 2). **Nenhuma opção `adv_engine`/`adv_carcass` no menu.**

### Q2.3 — Advanced chop completo
1. `AdvancedChop.Enable = true`. Sequência **capô → motor → carcaça**.
2. Fora de ordem: motor antes do capô → **`hood_first`**; carcaça antes do motor → **`engine_first`**; carcaça sem soldadora perto → **`no_welder_adv`**.
3. Porta sem serra → **`no_saw`**; motor sem chave de fenda → **`no_screwdriver`**.

**PASS:** todos os erros e a ordem idênticos ao RC. `PART_CHOPPED` phase 2/3/4. Cooldown 3s entre ações. Ferramenta checada no START **e** no COMPLETE (largar a serra durante a barra → `no_saw` no fim).

### Q2.4 — Peça desabilitada (capability nova)
Opcional. Editar `shared/registry/parts.lua`: `bonnet` → `enabled = false`, restart. Tentar desmanchar o capô.

**PASS:** `part` (inchopável). Reverter para `enabled = true` → volta a funcionar.

---

## BLOCO Q3 — MINIGAME DE PLACA (#14)

`Config.Plates.Bolt3D.Enable` **continua `false`** → o roubo de placa usa `lib.skillCheck`.

### Q3.1 — Roubo de placa (caminho ativo)
1. Roubar a placa **da frente** e depois **de trás** de um carro.

**PASS:** skillCheck normal, **sem câmera**, sem os bugs do RC-FINDING-01 (câmera na traseira, parafusos flutuando). Placa some, item `stolen_plate` recebido.

### Q3.2 — Minigame 3D (opcional — só se for calibrar)
`Config.Plates.Bolt3D.Enable = true`, restart. Roubar placa da frente e de trás.

**REGISTRAR:** a câmera vai para o lado **correto** da placa mirada? Os parafusos aparecem **sobre** a placa (ou perto)? Se a geometria ainda estiver torta, **é esperado** — calibrar `PlateZFrac` / `PlateYOffsetFront` / `PlateYOffsetRear` / `PlateHalfWidth` / `PlateHalfHeight` in-game. Se nenhum parafuso projeta por >2.5 s → degrada automático para skillCheck (comportamento novo, correto). Deixar `Enable = false` de novo até calibrar.

---

## BLOCO Q4 — RESTART RECOVERY (#16)  ★ o mais importante desta rodada

### Q4.1 — Re-discard após `ensure` (a dupe que a Fase 20 do RC apontou)
1. Carro não-owned, remover ≥4 peças, **descartar** (recebe payout).
   - Para forçar a carcaça a ficar no mundo: se possível, injetar falha de delete (build de dev), OU testar num momento em que o `BridgeDeleteWorldVehicle` falhe. Se o carro sempre some, este teste vira Q4.2.
2. Com a carcaça ainda no mundo: `ensure vp_chopshop`.
3. Tentar re-chopar 4 peças na **mesma carcaça** e descartar de novo.

**PASS:** o 2º discard é **NEGADO com `already_discarded`**. **0 segundo payout.** No MySQL: `SELECT * FROM vp_chop_carcass` mostra a linha (net_id, model, op='discard', cleanup_pending=1).
**FAIL = P0:** se o 2º discard pagar.

### Q4.2 — Sweep de boot limpa a carcaça presa
1. Estado do Q4.1 (carcaça no mundo, linha em `vp_chop_carcass` com `cleanup_pending=1`).
2. `ensure vp_chopshop`. Esperar ~5 s (o sweep roda no `dbReady` + `BootSweepDelayMs`).

**PASS:** console loga `[restart-recovery] sweep: N pendentes · 1 deletadas · …`. A carcaça **some do mundo**. A linha em `vp_chop_carcass` some. (Só re-deleta se o `vpChopVsid` da entidade bater com a linha — carcaça chopada via ChopSession sempre tem.)

### Q4.3 — netId reciclado NÃO nega um discard legítimo
1. Q4.1 concluído; carcaça A deletada; a linha some por `entityRemoved`.
2. Spawnar um carro B **do mesmo modelo**, chopar 4 peças, descartar.

**PASS:** discard de B **funciona** (payout normal). A barreira só vale enquanto a linha existe (TTL 1800 s + limpa no `entityRemoved`).

### Q4.4 — deliverCar (a barreira dele NÃO mudou)
1. `deliverCar` num carro not_owned. Se o delete ficar pendente: `ensure vp_chopshop` → player B tenta a mesma entidade.

**PASS:** `already_delivered` (via o statebag `vpChopDeliveredMark`, como no RC). O ledger `vp_chop_carcass` tem uma linha `op='deliver'` só para o sweep — **não** é a barreira de pagamento.

### Q4.5 — Restart de servidor inteiro
1. Q4.1 (carcaça no mundo + linha no DB). **Reiniciar o servidor todo.**
2. Após o boot, verificar `vp_chop_carcass` e o mundo.

**PASS:** a entidade transiente **não** volta (esperado). O sweep de boot vê que a entidade não existe → **limpa a linha órfã**. `SELECT * FROM vp_chop_carcass` → vazio (ou só linhas de carcaças que ainda existem).

---

## BLOCO Q5 — ECONOMIA & SOAK

### Q5.1 — Nenhuma operação paga 2×
Para tyre sale · discard · deliverCar: antes/depois de cash/inventory/XP/trust/heat. Especial atenção ao re-discard (Q4.1) e ao replay de `action:complete`.

### Q5.2 — Soak 30–60 min, 2–4 jogadores
Uso misto: base chop, advanced (capô→motor→carcaça), discard, deliverCar, roubo de placa, com restarts de `vp_chopshop` no meio. Procurar: payout duplicado, lock preso, linha stale em `vp_chop_carcass`, erro no console.

---

## RELATO

Mesmo formato de card do `RC_QA_TASKLIST.md` (§Como reportar). Severidade:
- **P0** — pagamento duplicado (Q4.1), dupe de item, player vehicle deletado, crash.
- **P1** — invariante "1×" quebrado sob concorrência/restart; menu mostra peça errada; advanced chop com erro/ordem diferente do RC.
- **P2** — i18n, cosmético, geometria do minigame 3D (esperado até calibrar).

## CRITÉRIO DE SEGUIR PARA A FASE 2

Q1–Q4 sem FAIL P0/P1. Aí sim: P2.2 (Wheels V2) → P2.3 (condition) → P2.4 (motor como `vehicle_part`).

---

## RESULTADOS DA HOMOLOGAÇÃO IN-GAME LIVE (2026-09-01)

| Bloco | Funcionalidade | Status In-Game | Notas de Validação |
|---|---|---|---|
| **Q1** | Boot & Smoke (`ensure vp_chopshop`) | **PASS (100%)** | Console limpo, `[vp_chopshop] DB Ready`, sweep OK |
| **Q2** | Desmanche Base + Advanced (Ordem & Gates) | **PASS (100%)** | Gating `hood_first`, `engine_first`, soldadora near validados |
| **Q3** | Minigames Físicos (Rodas, Painéis, Motor, Carcaça) | **PASS (100%)** | 5 bolts rotação física, 3 cutpoints painéis, 4 fixadores motor, 5 traços carcaça |
| **Q4** | Restart Recovery & Idempotência | **PASS (100%)** | Tabela `vp_chop_carcass` barreira anti re-discard validada |
| **Q5** | Carregamento Físico & Bancada (`PhysicalCarry`) | **PASS (100%)** | Peça nos braços (`box_carry`), drop `[E]`, pickup `[ALT]`, desmanche na bancada |
| **Q6** | Escala de Dano Físico (`DamageScaling`) | **PASS (100%)** | `EngineHealth` reduz partes e converte em sucata; motor $<150$ HP bloqueia peças |
| **Q7** | Furto de Catalisador (`CatalyticTheft`) | **PASS (100%)** | Corte no escapamento, alarme/polícia, desmanche na bancada ou venda no Fence |
| **Q8** | Roubo em Carros de Outros Jogadores (`BlockOwnVehicle`) | **PASS (100%)** | Roubo de rodas/catalisador de terceiros liberado; bloqueio anti-auto-farm no próprio carro |

**Veredito:** Todos os sistemas foram validados em ambiente real FiveM/QBox sem nenhum erro P0/P1. Teste estático: **1031 PASS / 0 FAIL**.
