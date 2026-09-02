# STATUS — vp_chopshop

> Documento vivo. Atualizar a cada PR mergeada. Contexto completo: [`AGENTS.md`](AGENTS.md).

**Atualizado:** 2026-09-02
**Branch de trabalho:** `feat/v1.18-p4.2-gps-lojack` (base: `pr-h/v1.15-delivercar-terminal-hardening`, SHA `423fbfe`)
**`main`:** `v1.14.3`
**Harness:** `lua tools/run_spec.lua .` → **1688 PASS / 0 FAIL / 1688 asserts**

---

## Onde estamos — Estado Real Validado em Runtime

```
Fase 0 — Base + Dores da QA             ✅ HOMOLOGADO & MERGED   (#14 #15 #16)
Fase 1 — Part Registry vira autoridade  ✅ HOMOLOGADO & MERGED   (#17 #18 #19 #20 #21 #22)
P2.1   — Client sai de ChopParts        ✅ HOMOLOGADO & MERGED   (#23)
─────────────────────────────────────────────────────────────────────────
Stack UX & Gameplay v1.16:              ✅ HOMOLOGADO & MERGED   (#40)
(Minigames Rodas/Painéis/Motor/Carcaça, Physical Carry, Unificação Bancada,
 Dano de Motor, Furto Catalisador, Roubo Player Vehicles, SEC-1, PAY-1.1)
─────────────────────────────────────────────────────────────────────────
v1.17 Chop Broker, Dynamic Market & Workshop Economy:
BROKER-0   — Architecture Frozen & Canonical Design ✅ CONCLUÍDO (Docs)
BROKER-1.2 — Final Parity & Fail-Closed Boot Engine ✅ HOMOLOGADO & MERGED (PR #42)
BROKER-2.1 — Fence Integration & Dynamic Payouts   ✅ HOMOLOGADO & MERGED (PR #43)
BROKER-3.2 — Contracts & High-Demand Lists         ✅ HOMOLOGADO & MERGED (PR #44)
BROKER-4.2 — Final SAGA Consistency & Migration    ✅ HOMOLOGADO & MERGED (PR #45, merge SHA e2cbcdb)
BROKER-5.1 — NPC Context UI & Readiness Hardening   ✅ HOMOLOGADO & MERGED (PR #46, merge SHA 5d508b1)
BROKER-6.2 — Static Gate Approved & Live QA Matrix ✅ HOMOLOGADO & MERGED (PR #47, merge SHA ebcf8fb)
─────────────────────────────────────────────────────────────────────────
v1.18 Camada de Crime & Perícia Policial Profunda:
P4.1.1     — EvidenceBridge Provider Hardening      ✅ HOMOLOGADO & MERGED (PR #48, merge SHA 423fbfe)
P4.2       — GPS Tracker / LoJack & Minigame        🚧 EM VALIDAÇÃO (feat/v1.18-p4.2-gps-lojack)
─────────────────────────────────────────────────────────────────────────

## Resumo dos Testes In-Game Realizados (100% Aprovados)

1. **Minigame de Rodas:** 5 parafusos com rotação física individual, câmera ortogonal calibrada, entrega de `TyreEntitlement`.
2. **Minigame de Painéis:** Corte de portas, capô e porta-malas com serra circular (`prop_tool_consaw`) na mão.
3. **Minigame de Motor:** 4 fixadores desacoplados com chave inglesa/boca (`prop_tool_wrench`), com bypass automático se o capô foi arrancado em batidas.
4. **Minigame de Carcaça:** 5 traçados estruturais com maçarico de solda (`prop_weld_torch`), auto-avanço fluido de câmera entre seções e isolamento de linhas de corte na tela.
5. **Carregamento Físico:** Peças retiradas (`door`, `bonnet`, `engine`, `catalytic`) são carregadas nos braços do jogador, podendo ser largadas `[E]` e recolhidas do chão `[ALT]`.
6. **Desmanche na Bancada:** Peça carregada é processada no `ox_target` da `chopshop_bench` gerando sucatas e partes.
7. **Escala de Dano (EngineHealth):** Motor danificado tem recompensas reduzidas e convertidas em sucata de metal. Motor fundido ($<150$ HP) bloqueia reaproveitamento de peças.
8. **Furto de Catalisador:** Corte de escapamento em veículos de rua, chance de disparar alarme/polícia, e opção de desmanchar na bancada ou vender direto no NPC Fence.
9. **Roubo em Carros de Jogadores:** Permite furtar catalisadores e rodas de veículos pertencentes a outros jogadores, bloqueando o dono de roubar o próprio veículo (`BlockOwnVehicle` anti-auto-farm).
