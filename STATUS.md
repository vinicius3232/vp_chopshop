# STATUS — vp_chopshop

> Documento vivo. Atualizar a cada PR mergeada. Contexto completo: [`AGENTS.md`](AGENTS.md).

**Atualizado:** 2026-09-01
**Branch de integração:** `feat/v1.16-ux-e-carcass-minigame` (HEAD: `7a3de41`, base de PR #40)
**`main`:** `v1.14.3`
**Harness:** `lua tools/run_spec.lua .` → **1087 PASS / 0 FAIL / 1087 asserts**

---

## Onde estamos — Estado Real Validado em Runtime

```
Fase 0 — Base + Dores da QA             ✅ HOMOLOGADO & MERGED   (#14 #15 #16)
Fase 1 — Part Registry vira autoridade  ✅ HOMOLOGADO & MERGED   (#17 #18 #19 #20 #21 #22)
P2.1   — Client sai de ChopParts        ✅ HOMOLOGADO & MERGED   (#23)
─────────────────────────────────────────────────────────────────────────
Stack UX & Gameplay v1.16:
UX-0   — DisplayName server-safe fix    ✅ HOMOLOGADO            (956f5fe)
UX-A   — Interaction Core & NUI         ✅ HOMOLOGADO            (d390f29)
UX-B   — Wheel 5-Bolt Rotate Minigame   ✅ TESTADO IN-GAME (OK)  (#37)
UX-C   — Body Panels Cut Minigame       ✅ TESTADO IN-GAME (OK)  (#38)
UX-D   — Engine Removal & Mounts        ✅ TESTADO IN-GAME (OK)  (#39)
UX-E   — Carcass Structural Trace Cut   ✅ TESTADO IN-GAME (OK)  (#40)
UX-F   — Auto-Pan & Smooth Sequencing   ✅ TESTADO IN-GAME (OK)  (e173ee5)
─────────────────────────────────────────────────────────────────────────
Novas Mecânicas Físicas & Oficinas:
PHYS-1 — Physical Part Carry (Braços)   ✅ TESTADO IN-GAME (OK)  (ffe26e5)
PHYS-2 — Workbench Part Dismantling     ✅ TESTADO IN-GAME (OK)  (ffe26e5)
DMG-1  — Damage Health Scaling (Motor)  ✅ TESTADO IN-GAME (OK)  (bedfb9a)
CAT-1  — Catalytic Converter Theft      ✅ TESTADO IN-GAME (OK)  (3feab7a)
OWN-1  — Player-Vehicle Theft & Anti-Exp✅ TESTADO IN-GAME (OK)  (b39dd5e)
─────────────────────────────────────────────────────────────────────────
Hardening de Segurança & Autoridade Econômica:
SEC-1  — Part Entitlement Core Authority✅ HOMOLOGADO & MERGED   (#41)
         (Bench Server Authority, Fence Tokenized Sale, Strict Mode Allowlist,
          Fail-Closed InvCanCarry, Catalytic 2-step Server Timing & Replay TTL,
          Carcass Statebag Fail-safe, Canonical BridgeAddCash Payment)
─────────────────────────────────────────────────────────────────────────
Fase 3 — Processamento de Peça Avançado  ✅ EM ANDAMENTO / INTEGRADO
Fase 4 — Camada de Crime & Perícia       ⏸
Fase 5 — Polish Final + CI + Release     ⏸
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
