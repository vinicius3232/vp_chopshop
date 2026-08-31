# STATUS — vp_chopshop

> Documento vivo. Atualizar a cada PR mergeada. Contexto completo: [`AGENTS.md`](AGENTS.md).

**Atualizado:** 2026-08-31
**Branch de integração:** `pr-h/v1.15-delivercar-terminal-hardening`
**`main`:** `v1.14.3` (intocado — nada de v1.16 foi pro main)
**Harness:** `lua tools/run_spec.lua .` → **996 PASS / 0 FAIL**

---

## Onde estamos

```
Fase 0 — base + dores da QA            ✅ CÓDIGO COMPLETO   (#14 #15 #16)
Fase 1 — Part Registry vira autoridade ✅ CÓDIGO COMPLETO   (#17 #18 #19 #20 #21 #22)
P2.1   — client sai de ChopParts       ✅ CÓDIGO COMPLETO   (#23)
─────────────────────────────────────────────────────────────────────────
Stack UX v1.16 (Mecânicas Físicas & Interativas):
UX-0   — DisplayName server-safe fix   ✅ MERGED            (956f5fe)
UX-A   — Interaction Core & NUI        ✅ MERGED            (d390f29)
UX-B   — Wheel 5-Bolt Rotate Minigame  ✅ MERGED            (#37)
UX-C   — Body Panels Cut Minigame      ✅ APROVADO / RC     (#38)
UX-D   — Engine Drill Removal          ✅ APROVADO / RC     (#39)
UX-E   — Carcass Structural Trace Cut  ✅ APROVADO / RC     (#40)
UX-F   — Full Integration / RC QA      ✅ CODE RC READY     (#40 @ 9db1696)
─────────────────────────────────────────────────────────────────────────
Fase 3 — processamento de peça         ⏸  (Pós-homologação in-game v1.16)
Fase 4 — camada de crime               ⏸
Fase 5 — polish + CI + release         ⏸
```

## Próximo movimento — Homologação In-Game

**A bola está com a QA/In-Game Testing.** Deploy da `pr-h` num servidor FXServer/QBox real e rodar o roteiro de homologação do RC:
1. Rodas (5 bolts, rotação física, `TyreEntitlement`).
2. Painéis (3 pontos de corte por porta/capô/porta-malas).
3. Motor (4 fixadores com parafusadeira, `hood_first`).
4. Carcaça (5 linhas estruturais com maçarico de solda, anti-jump, sem serra, `engine_first`, proximidade de `chopshop_welder`).
5. Replay idempotente, concorrência e restart recovery (`carcass_ledger`).

## PRs da Stack UX v1.16 (base `pr-h`, squash-merge)

| # | O quê | Status |
|---|---|---|
| #37 | UX-B / UX-B.1 / UX-B.2 — Wheel Physical Minigame (5 bolts, rotate primitive, clock domain safety) | MERGED |
| #38 | UX-C — Body Panels Physical Dismantling (cut primitive, 3 cutpoints, camera framing) | OPEN / RC |
| #39 | UX-D / UX-D.1 — Engine Physical Removal (drill primitive, 4 mounts, `prop_tool_drill`) | OPEN / RC |
| #40 | UX-E / UX-E.1 / UX-E.2 / UX-F — Carcass Physical Structural Trace & Full Integration QA | OPEN / RC |
