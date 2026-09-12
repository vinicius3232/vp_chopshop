# STATUS — vp_chopshop

> Documento vivo. Atualizar a cada PR mergeada. Contexto completo: [`AGENTS.md`](AGENTS.md).

**Atualizado:** 2026-09-12
**Branch de trabalho:** `feat/v1.20-p6-gangs-network` (base: `docs/post-v118-future-roadmap-prep`)
**`main`:** `v1.14.3`
**Harness:** `lua tools/run_spec.lua .` → **2311 PASS / 0 FAIL / 2311 asserts**

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
P4.2       — GPS Tracker / LoJack & Catalytic Theft ✅ HOMOLOGADO & MERGED (PR #49, merge SHA 9c52c52)
P4.3       — DispatchBridge & Police Alert System   ✅ HOMOLOGADO & MERGED (PR #50, merge SHA 3fd6f54)
P4.4.1     — Forensic Domain Integration            ✅ HOMOLOGADO & MERGED (PR #51, merge SHA 7ba2080)
v1.18-RC   — Forensics Gate & Release Candidate 2   ✅ HOMOLOGADO & PR #52 MERGED (HEAD 7a57ecb)
─────────────────────────────────────────────────────────────────────────
v1.18.2 Expansão de Minigames Físicos & Polimento Auditado:
MINIGAME-1 — Painel SVG Furto de Catalisador de Rua ✅ HOMOLOGADO & MERGED (PR #53)
MINIGAME-2 — Lixamento de Chassi/Serial na Bancada   ✅ HOMOLOGADO & MERGED (PR #54)
MINIGAME-3 — Desmonte Estrutural Martelo Pneumático  ✅ HOMOLOGADO & MERGED (PR #55/#56)
POST-v1.18 — Future Roadmap Reconciliation (RFC 5-9)✅ CONCLUÍDO (Docs / RFC Suite)
AUDIT-v1.18— Limpeza de Leaks/Props, NUI & Docs      ✅ APLICADO & HARNESS 2159 PASS
─────────────────────────────────────────────────────────────────────────
FASE 5 (v1.19) Adaptadores de Oficina Mecânica (Workshop Live):
P5.1       — Adapter QBox Mechanics (qbx_mechanics/customs) ✅ HOMOLOGADO (PR #57)
P5.2       — Adapter Multi-API (qs-mechanics / renzu_customs)✅ HOMOLOGADO (PR #57)
P5.3       — Catálogo de Encomendas B2B & Escrow Terminal  ✅ HOMOLOGADO (PR #57)
P5.4       — Peças Físicas Duráveis & Proveniência V2      ✅ HOMOLOGADO & MERGED (PR #58)
P5.5       — Recuperação Seletiva de Boot (RestartRecovery)✅ HOMOLOGADO & MERGED (PR #58)
P5-RC      — Workshop Live Release Gate (10 Invariantes)   ✅ HOMOLOGADO & MERGED (PR #58)
─────────────────────────────────────────────────────────────────────────
FASE 6 (v1.20) Criminal Network & Gangs (vp_gangs):
P6.1       — Territory Tax / Chop Zones (15% retida cofre) ✅ IMPLEMENTADO
P6.2       — Economic Bonus (+10%) & Heat Reduction (50%)  ✅ IMPLEMENTADO
P6.3       — Informant & Multi-Smartphone Alert (lb/qs/etc)✅ IMPLEMENTADO (REQUISITO CANÔNICO)
P6.4       — Cooperative Gang Contracts & Server Payout    ✅ IMPLEMENTADO & 14 ASSERTS
P6-RC      — Gangs & Territory Gate (8 Invariantes)        ✅ 19/19 PASS & PR ABERTO
─────────────────────────────────────────────────────────────────────────
```

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
10. **Inutilização Veicular Anti-Farm:** Remoção do bloco do motor (`vpChopEngineMissing`) ou furto de catalisador com `DisableVehicle = true` inutiliza o carro e bloqueia ignição/condução no client até reparo.
11. **Perícia Policial Veicular:** Policiais com `parts_scanner` ou `forensic_kit` inspecionam o veículo revelando estado do motor, catalisador, VIN raspado, disfarce de placa e sinal de rastreador GPS.
12. **Minigame SVG de Catalisador:** Painel interativo dedicado na rua com corte das duas pontas do escapamento e desmonte de presilhas.
13. **Minigame de Raspagem de Serial:** Lixamento de número de chassi/bloco do motor na bancada via painel abrasivo interativo.
14. **Desmonte com Martelo Pneumático:** Desmanche sonoro e vibratório de carcaça e peças na bancada com ferramenta pesada.
15. **Adapter QBox Mechanics & SAGA (P5.1/P5.2):** SAGA transacional 2-phase com retenção de escrow em sociedades (`qbx_management` / `ox_inventory`) e entrega em cofres de oficina.
16. **Catálogo B2B & Terminal de Ordens (P5.3):** Ordens de compra de oficinas integradas ao Broker com pagamento premium e liquidação atômica anti-race condition.
