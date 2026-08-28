# STATUS — vp_chopshop

> Documento vivo. Atualizar a cada PR mergeada. Contexto completo: [`AGENTS.md`](AGENTS.md).

**Atualizado:** 2026-08-28
**Branch de integração:** `pr-h/v1.15-delivercar-terminal-hardening` @ `866abae`
**`main`:** `v1.14.3` (intocado — nada de v1.16 foi pro main)
**Harness:** `lua tools/run_spec.lua .` → **566 PASS / 0 FAIL**

---

## Onde estamos

```
Fase 0 — base + dores da QA            ✅ CÓDIGO COMPLETO   (#14 #15 #16)
Fase 1 — Part Registry vira autoridade ✅ CÓDIGO COMPLETO   (#17 #18 #19 #20 #21 #22)
P2.1   — client sai de ChopParts       ✅ CÓDIGO COMPLETO   (#23)
Checkpoint de QA                       ✅ escrito           (#24 → docs/audit/V116_INTEGRATION_QA.md)
─────────────────────────────────────────────────────────────────────────
Fase 2 — Wheels V2 / condition / motor ⏸  BLOQUEADO até a QA validar Fase 0+1
Fase 3 — processamento de peça         ⏸
Fase 4 — camada de crime               ⏸
Fase 5 — polish + CI + release         ⏸
```

## Próximo movimento — NÃO é código

**A bola está com a QA.** Deploy da `pr-h` num servidor QBox real e rodar
`docs/audit/V116_INTEGRATION_QA.md` (blocos Q1–Q5). O mais crítico é **Q4**
(restart recovery): **Q4.1** — re-chopar e re-descartar a mesma carcaça depois de
`ensure vp_chopshop` deve dar `already_discarded` com **0 payout**. Se pagar 2× = P0.

Fase 2 (P2.2 Wheels V2 → P2.3 condition → P2.4 motor como `vehicle_part`) só
começa depois de Q1–Q4 sem FAIL P0/P1. Bug encontrado pela QA = RC-FIX pequena e
isolada, mesmo fluxo.

## PRs desta rodada (todas base `pr-h`, squash-merge)

| # | O quê | Muda runtime? |
|---|---|---|
| #14 | P0.2 — minigame de placa frente/traseira-aware; asset pago removido; `stream/` esvaziado | SIM (`Bolt3D.Enable=false` → skillCheck) |
| #15 | P0.3 — 4 notificações server → `L()`; bloco morto removido de `client/fence.lua` | cosmético |
| #16 | P0.4 — restart recovery: `vp_chop_carcass`, barreira anti re-discard, sweep de boot | SIM |
| #17 | P1.1 — `shared/registry/*` inerte + drift check (ZERO drift) | não |
| #18 | P1.2 / FASE B — `chop_parts.lua` vira projeção do registry | refator puro |
| #19 | P1.3 / FASE C — `bonnet` valida via registry (vertical slice) | refator |
| #20 | P1.4 / FASE D — validação avançada 100% via registry | refator |
| #21 | P1.5 / FASE E — remove fallbacks hardcode + `Config.AdvancedChop.SawItem/ScrewdriverItem` mortos; **nova capability:** `enabled=false` por peça → inchopável | refator + capability |
| #22 | P1.6 / FASE F — 11 sites server saem de `ChopParts` → `VPChopPartGtaClass` | refator puro |
| #23 | P2.1 enxuto — 6 sites client saem de `ChopParts`; `chop_parts.lua` → `part_class.lua` | refator client |
| #24 | checkpoint de QA (`docs/audit/V116_INTEGRATION_QA.md`) | doc |

## Decisão de fase (2026-08-28)

O dono suspendeu o RC freeze da v1.15. Motivo: a direção está decidida; testar
uma v1.15 congelada que já vai ser reescrita desperdiça QA. Novo alvo: build
consolidado `v1.16-dev` que a QA valida como um todo. **Não** significa reescrever
o núcleo (ChopSession/ActionSession/discard/deliverCar — fundação de 566 asserts).
Ver `docs/design/MASTER_IMPLEMENTATION_PLAN.md` §1.
