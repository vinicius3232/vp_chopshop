# vp_chopshop v1.15 — TASK LIST DA EQUIPE DE TESTE (RC runtime)

> **Build sob teste:** branch `pr-h/v1.15-delivercar-terminal-hardening`, HEAD `99371e4`, `version '1.15.0-rc1'`.
> **Objetivo:** validar em servidor FiveM/QBox real (OneSync, 2–4 jogadores) que os invariantes provados nos 493 testes estáticos se sustentam com statebags reais, callbacks com yield, network IDs reais, disconnect/reconnect e restart de resource.
> **Fonte dos critérios de PASS:** `docs/audit/V115_RELEASE_CANDIDATE.md §3` (tabela das 26 fases). Este documento é o **passo-a-passo operacional** dessas fases.

---

## REGRAS DE OURO (ler antes de começar)

1. **NÃO corrigir bug em silêncio durante o teste.** Primeiro registrar: reprodução + evidência (print/vídeo/log). Correção vira uma RC-FIX pequena e isolada **depois**, decidida pelo dev.
2. **Diferença harness ↔ runtime = PARAR** e reportar. Os 493 PASS estáticos são a linha de base; qualquer divergência no servidor é achado.
3. **Ordem importa.** Rodar os blocos na ordem A → F. Um FAIL P0/P1 num bloco anterior **bloqueia** os seguintes até decisão do dev.
4. **A Fase 19 (restart + `vpChopDeliveredMark`) é a mais crítica.** Se falhar, muda a estratégia de barreira do `deliverCar` — é P1 automático.
5. Todo teste de concorrência precisa de **2 jogadores agindo ao mesmo tempo** (contagem regressiva no voice/discord), não em sequência.

---

## BLOCO 0 — SETUP DO AMBIENTE (pré-requisito, não é fase)

- [ ] Servidor QBox atual: `qbx_core`, `qbx_vehicles`, `ox_lib`, `ox_inventory`, `ox_target`, `oxmysql` nas versões de produção.
- [ ] Importar `sql/vp_chopshop.sql` num banco limpo (ou confirmar migrações aplicadas).
- [ ] Itens do `installation/ox_items_snippet.txt` registrados no `ox_inventory`.
- [ ] `ensure vp_chopshop` — console sobe **sem erro**.
- [ ] Colocar 1 bancada + 1 soldadora (comando admin) a ≤ 8m uma da outra.
- [ ] 2–4 contas de teste; pelo menos 1 com job de polícia; pelo menos 1 veículo **OWNED/persistido de verdade** (registrado em `player_vehicles`/qbx) e 1 veículo **não-owned** (spawn admin).
- [ ] `parts_scanner` + `forensic_kit` no inventário do policial de teste.
- [ ] Acesso ao MySQL para inspecionar `vp_chop_progression.last_car_delivery`, `vp_chop_fence_trust`, `vp_chop_legit_serials`.
- [ ] Ferramenta de captura de tela/vídeo + acesso ao console do servidor (txAdmin/live console) para copiar logs.

> **Nota RC-FINDING-01:** o minigame de parafusos 3D está **desligado** nesta RC (`Config.Plates.Bolt3D.Enable = false`, `Config.Jackstand.Minigame.Bolt3D.Enable = false`). O fluxo cai no `lib.skillCheck` / `lib.progressBar`. Isso é esperado — **não** reportar como bug. O rework do minigame é pós-RC.

---

## BLOCO A — BOOT & SELFTEST  (Fases 1–2)

### A1 — Boot / load order  `[Fase 1]`
1. `ensure vp_chopshop` num servidor recém-iniciado.
2. Ler o console inteiro do boot.

**PASS:** resource sobe sem erro; sem erro em exports `qbx_core`/`qbx_vehicles`; sweepers de ChopSession e ActionSession ativos; TyreEntitlement/TruckStorage ativos; DB Ready = true; console limpo.
**Evidência:** print do console de boot completo.

### A2 — Selftest estático no runtime  `[Fase 2]`
1. Em ambiente DEV: `setr vp_chopshop_selftest 1` → restart do resource.
2. Ler o resultado dos specs no console.

**PASS:** **493 PASS / 0 FAIL**, idêntico ao harness local.
**FAIL (PARAR):** qualquer número diferente de 493 PASS, ou qualquer FAIL. Copiar o bloco inteiro de saída dos specs.
3. Ao terminar: `setr vp_chopshop_selftest 0` → restart (rodar o resto dos blocos com selftest DESLIGADO).

---

## BLOCO B — SESSÕES CORE: CHOP / ACTIONSESSION / LOGÍSTICA  (Fases 3–11)

### B1 — ChopSession / jackstand  `[Fase 3]`
1. Jogador A leva um carro não-owned ao chop, levanta no jackstand.
2. Confirmar (via `/vpchop debug` ou logs): existe `sessionId`, `VSID`, marker de VSID, `raised=true`, A é participante.
3. Jogador B (sem participar) tenta uma ação de desmanche no mesmo carro.

**PASS:** B recebe **DENY** (com `EnforceRaised=true`). Com `EnforceRaised=false` → comportamento legacy compatível.

### B2 — ActionSession base tyre: START + lock + cancel  `[Fase 4]`
1. A inicia remoção de uma roda → START → OPEN → peça travada.
2. Com A ainda em OPEN, B tenta a **mesma roda**.
3. A cancela (soltar/afastar/ESC).

**PASS:** passo 2 → B recebe `processing`. Passo 3 → sessão CANCELLED, lock liberado, **0** peça / 0 reward / 0 entitlement gerados.

### B3 — COMPLETE real  `[Fase 5]`
1. A completa a remoção da roda (esperar duração mínima).

**PASS:** OPEN → COMMITTING (pinned) → COMPLETED; roda marcada REMOVED com `origin=base`; ferramenta −1; reward entregue **1×**; evento `PART_CHOPPED` **1×**; TyreEntitlement criado **1×**; client recebe `entitlementId`; a roda some do carro; prop de "carry" aparece nas mãos de A.
**Evidência:** print do inventário antes/depois + print do log de evento.

### B4 — Response loss / replay  `[Fase 6]`
1. Provocar a chamada `action:complete` **2×** para a mesma ação (F8→resend, ou latência/duplo clique).

**PASS:** 2ª resposta = `replay=true`, **mesmo** `tyreEntitlementId`, nenhum efeito repetido (sem 2ª roda, sem 2º reward).

### B5 — Timing / tool / distance / disconnect  `[Fase 7]`
Testar cada um isoladamente:
- COMPLETE antes da duração mínima → `too_fast` (não cancela; ao esperar e repetir, conclui).
- Afastar-se durante OPEN e completar → `distance`.
- Largar a ferramenta e completar → `no_tool`.
- Disconnect durante OPEN.

**PASS:** todos fecham a ação (cancel/expired) e **liberam o lock**; nenhum caso remove peça ou paga recompensa.

### B6 — Tyre logistics  `[Fase 8]`
1. Após B3, guardar o pneu no truck.
2. Inspecionar: `storageId` `ts:*`, marker `vpChopTyreStorageId` (write + readback).
3. Tentar recarregar **o mesmo entitlement** de novo.

**PASS:** REMOVED → STORED; contagem derivada do estado real; `chopTyreCount` é só UX; recarregar o mesmo entitlement → **DENY**.

### B7 — Truck concurrency  `[Fase 9]`
Com 2 jogadores simultâneos: load/load, load/sell, sell/sell no mesmo truck.

**PASS:** 1 lock de storage, 0 duplicação, no máx 1 payout, estado SOLD ocorre exatamente **1×**.

### B8 — Truck lifecycle  `[Fase 10]`
- Despawn do truck com pneus dentro → STORED vira LOST.
- Quem carregou desconecta → STORED permanece.
- Quem tem um pneu REMOVED (na mão) desconecta → REMOVED vira LOST.

### B9 — Advanced ActionSession  `[Fase 11]`
1. Sequência: capô → motor → carcaça.
2. Testar fora de ordem: motor antes do capô → `hood_first`; carcaça antes do motor → `engine_first`; carcaça sem soldadora → `no_welder_adv`.

**PASS:** fases 2/3/4 completam; `PART_CHOPPED` 1× por peça; cooldown de 3s entre ações avançadas; ferramenta checada no START **e** no COMPLETE.

---

## BLOCO C — DISCARD & OWNERSHIP  (Fases 12–16)

### C1 — Discard básico  `[Fase 12]`
1. Remover 2 peças base + 2 advanced (`MinPartsToDiscard=4`).
2. Descartar o carro.

**PASS:** descarte permitido; `VPChopGetPartCount` ainda conta só base (esperado); READY_FOR_DISCARD → pagamento → COMPLETED → `BridgeDeleteWorldVehicle` (carro some).

### C2 — Discard concurrency  `[Fase 13]`
A e B descartam o **mesmo carro** ao mesmo tempo.

**PASS:** 1 sessão, 1 lock, **1 payout**, 1 evento `CAR_DISCARDED`, 1 tombstone.

### C3 — Owned vehicle  `[Fase 14]`  ⚠ usar o carro OWNED real
1. Tentar descartar o carro persistido.
2. Tentar `deliverCar` (fence) o carro persistido.

**PASS:** ambos **DENY `owned`**; `state.vehicleid` presente; lookup em `qbx_vehicles` ocorre; registro no DB permanece; **entidade NÃO é deletada**.

### C4 — Fake plate + ownership  `[Fase 15]`
1. Aplicar placa falsa num carro OWNED.
2. Repetir C3 (discard + deliverCar).

**PASS:** ownership continua `OWNED`; a placa falsa **não** faz o carro virar `not_owned`; ambas as operações continuam DENY.

### C5 — QBox delete (not_owned legítimo)  `[Fase 16]`
1. `deliverCar`/discard num carro não-owned spawnado.

**PASS:** `DisablePersistence` **ocorre** + `DeleteEntity`; entidade não reaparece; **0** registro em `player_vehicles` afetado.

---

## BLOCO D — FAILURE INJECTION & IDENTIDADE  (Fases 17–18, 21–23)

> Estas fases precisam de **injeção de falha**. Se não houver build de dev com hooks de injeção, marcar como "N/A — precisa build instrumentado" e reportar; **não** pular silenciosamente.

### D1 — Delete failure  `[Fase 17]`
- **Discard:** forçar a deleção de mundo a falhar. → jogador **pago** + sessão COMPLETED + `cleanupPending=true` + retry **não re-paga**.
- **deliverCar:** forçar delete a falhar. → cooldown reservado + jogador pago + **marker permanece** + `cleanupPending` + retry não re-paga.

### D2 — NetID reuse  `[Fase 18]`
Provocar reciclagem de netId (despawn + spawn até repetir o id) e deixar o retry destrutivo rodar.

**PASS:** o retry destrutivo **nunca** toca uma entidade cujo VSID / delivery marker / storage marker não corresponda. **Mesmo modelo de carro NÃO basta** para deletar.

### D3 — deliverCar: ordem observável  `[Fase 21]`
1. `deliverCar` num carro not_owned real. Observar a ordem: cooldown reserve → marker → cash → delete → trust/evento.
2. Conferir `last_car_delivery` no MySQL logo após.
3. 2º jogador tenta a **mesma entidade** → não recebe nada.
4. Mesmo jogador, **outro** carro, < 20 min → cooldown.

### D4 — Failure injection deliverCar (4 sub-casos)  `[Fase 22]`
- **A:** `reserve affected=0` (cooldown já ocupado) → cash **0**.
- **B:** marker write/readback falha → cash **0**.
- **C:** `BridgeAddCash` retorna false → rollback do cooldown + marker removido + carro **fica**.
- **D:** delete falha → payout válido + marker fica + `cleanupPending`.

### D5 — Observabilidade RC-FIX-1a/1b  `[Fase 23]`
Durante D4, confirmar no log do servidor:
- `rollbackCooldown` só considera sucesso com `affectedRows == 1` (log forte se não).
- Falha de `clearMark` no caminho de pagamento-falho → log **SEVERE** (`marcador de entrega NÃO pôde ser removido`).

**PASS:** comportamento reproduzível = já coberto por `99371e4`. Se não reproduzir, nada a fazer.

---

## BLOCO E — ★ RESTART DE RESOURCE (O MAIS CRÍTICO)  (Fases 19–20)

### E1 — Resource restart + `vpChopDeliveredMark`  `[Fase 19]`  ★★★
1. `deliverCar` num carro not_owned, **forçando o delete a ficar pendente** (D1/D4-D): jogador pago, carro continua no mundo, marker `vpChopDeliveredMark` presente na entidade.
2. `ensure vp_chopshop` (restart do resource) com o carro ainda no mundo.
3. Jogador B tenta `deliverCar` **na mesma entidade**.

**PASS:** B recebe **`already_delivered`**, **0** segundo payout.
**O QUE REGISTRAR EXPLICITAMENTE:** o statebag server-local `vpChopDeliveredMark` **sobreviveu ao restart no OneSync real?** (SIM/NÃO + evidência: `/vpchop debug` ou leitura do statebag antes e depois).
**FAIL = P1 automático:** se o marker **não** sobrevive → a estratégia de barreira do `deliverCar` precisa mudar. Reportar com prioridade máxima.

### E2 — Discard + resource restart  `[Fase 20]`
1. Desmontar um carro **parcialmente** (2–3 peças), sem descartar.
2. `ensure vp_chopshop`.
3. Observar e registrar: estado visual do carro / peças removidas / entidade / é possível re-chopar as mesmas peças? / impacto econômico (dupe de reward?).

**PASS/OUTCOME:** a ChopSession é in-memory — a perda da sessão é **esperada**. O objetivo é **documentar o comportamento**, não corrigir. O dev decide se persistência da ChopSession é requisito v1.15 ou v1.16. **NÃO** corrigir nesta RC.

---

## BLOCO F — ECONOMIA / RESMON / SOAK  (Fases 24–26)

### F1 — Economia  `[Fase 24]`
Para cada operação (tyre sale, discard, deliverCar): anotar antes/depois de **cash, inventory, tyre count, XP, trust, heat**.

**PASS:** nenhuma operação gera valor **2×**. Toda tabela antes/depois fecha.

### F2 — Resmon  `[Fase 25]`
`resmon` (F8 client + `resmon` server) em cada situação: idle · perto do chop · ActionSession OPEN · advanced · truck load · truck sale · discard.

**Registrar:** client ms + server ms de cada. **Esperado:** event-driven, sem loop por action; idle perto de 0.00ms. Estes números viram os **oficiais** da auditoria (hoje são só estimativa estática).

### F3 — Soak test  `[Fase 26]`
2–4 jogadores, **30–60 min** de uso misto: chops, cancels, disconnects, loads, sells, advanced, discard, deliverCar, repetidamente.

**Procurar:** locks presos, tombstones errados, leak de session/storage/entitlement, duplicate payouts, erros no console.
**Evidência:** console do servidor completo do período + resmon no fim.

---

## COMO REPORTAR CADA ACHADO

Um card por achado, com:

```
[ID]        RC-<bloco><n>  ex.: RC-E1-01
FASE        19
SEVERIDADE  P0 (bloqueia release) | P1 (bloqueia, precisa RC-FIX) | P2 (anotar, não bloqueia) | OBS
O QUE       1 frase
REPRO       passos numerados exatos, nº de jogadores, timing
ESPERADO    (cópia do critério PASS desta task)
OBSERVADO   o que aconteceu de fato
EVIDÊNCIA   print / vídeo / trecho de log do servidor (colar cru)
BUILD       99371e4 / 1.15.0-rc1
```

**Classificação rápida de severidade:**
- **P0** — pagamento duplicado, dupe de item, player vehicle deletado, crash/erro que derruba o resource.
- **P1** — Fase 19 falhando; qualquer invariante de "1×" quebrado sob concorrência; lock preso permanente.
- **P2** — UX, notify errada, cosmético, timing folgado.
- **OBS** — comportamento in-memory esperado (ex.: Fase 20), número de resmon.

---

## CRITÉRIO DE ACEITE DO RC (quem decide é o dev, não a QA)

O build sai de `C) NOT READY` para `A/B` quando:
1. Fase 2 = 493 PASS no servidor;
2. Fases 3–18 e 21–26 sem FAIL P0/P1;
3. **Fase 19** confirmando que `vpChopDeliveredMark` sobrevive a `ensure vp_chopshop` no OneSync real;
4. Fase 20 documentada + veredito explícito do dev (release com a limitação in-memory, ou adiar p/ v1.16).

Entregar à QA-lead: esta lista preenchida + todos os cards de achado + os prints de console (boot, selftest, soak).
