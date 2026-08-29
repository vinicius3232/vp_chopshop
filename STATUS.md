# STATUS — vp_chopshop

> Documento vivo. Atualizar a cada PR mergeada. Contexto completo: [`AGENTS.md`](AGENTS.md).

**Atualizado:** 2026-08-29
**Branch de integração:** `pr-h/v1.15-delivercar-terminal-hardening` @ `564ff19`
**`main`:** `v1.14.3` (intocado — nada de v1.16 foi pro main)
**Repo:** `github.com/vinicius3232/vp_chopshop` — **PÚBLICO** (ver §Infra + issue #34)
**Harness:** `lua tools/run_spec.lua .` → **632 PASS / 0 FAIL** — check `harness` no CI (#33)

---

## Onde estamos

```
Fase 0 — base + dores da QA            ✅ CÓDIGO COMPLETO   (#14 #15 #16)
Fase 1 — Part Registry vira autoridade ✅ CÓDIGO COMPLETO   (#17 #18 #19 #20 #21 #22)
P2.1   — client sai de ChopParts       ✅ CÓDIGO COMPLETO   (#23)
Checkpoint de QA                       ✅ escrito           (#24 → docs/audit/V116_INTEGRATION_QA.md)
Docs de contexto (AGENTS/STATUS/plano) ✅                   (#25 #26)
INT-01 — ponte vp_chopshop → vp_gangs  ✅ CÓDIGO COMPLETO   (#27 #28 — contractVersion 1, fallback legado removido)
CI — harness como check + exit code    ✅ MERGED            (#33 — .github/workflows/harness.yml + sanity gate)
Branch protection (main + pr-h)        ✅ ATIVO             (rulesets — ver §Infra)
Design — VP Interactive Dismantling    ✅ FECHADO (doc)     (#29 #30 — ABERTOS, não mergeados; ver abaixo)
─────────────────────────────────────────────────────────────────────────
Fase 2 — Wheels V2 / condition / motor ⏸  BLOQUEADO até a QA validar Q1–Q4
Fase 3 — processamento de peça         ⏸
Fase 4 — camada de crime               ⏸
Fase 5 — polish + CI + release         ⏸
```

## Próximo movimento — NÃO é código

**A bola está com a QA.** Deploy da `pr-h` num servidor QBox real e rodar
`docs/audit/V116_INTEGRATION_QA.md` (blocos Q1–Q5). O mais crítico é **Q4**
(restart recovery): **Q4.1** — re-chopar e re-descartar a mesma carcaça depois de
`ensure vp_chopshop` deve dar `already_discarded` com **0 payout**. Se pagar 2× = P0.

`#27`/`#28` (ponte `vp_gangs`) entraram **depois** do checkpoint `#24` e mexem em
runtime — a QA deve validar `pr-h` no HEAD atual (`564ff19`), não em `866abae`.
`#33` é CI/infra (workflow + runner), não toca runtime FiveM.

Fase 2 (P2.2 Wheels V2 → P2.3 condition → P2.4 motor como `vehicle_part`) só
começa depois de Q1–Q4 sem FAIL P0/P1. Bug encontrado pela QA = RC-FIX pequena e
isolada, mesmo fluxo.

## Design em revisão — VP Interactive Dismantling (`#29` `#30`)

**Pesquisa/design FECHADOS.** Substituir progress bars passivas por interação
física com as peças, servidor mantendo autoridade absoluta. Docs:

- [`docs/design/WHEEL_BOLT_MINIGAME.md`](docs/design/WHEEL_BOLT_MINIGAME.md) (`#29`) — estudo do `filo_bolt`.
- [`docs/design/INTERACTIVE_DISMANTLING.md`](docs/design/INTERACTIVE_DISMANTLING.md) (`#30`) — **fonte canônica**: contrato de provider (`VPChopMinigames.run(partDef, ctx) → 'success'|'cancel'|'fallback'`), mapa `Registry.action.minigame → provider`, state machine Wheels V2 (server: `AVAILABLE→LOCKED→REMOVED→CARRIED→STORED`; `REMOVING` é view do client), threat model, roadmap ID-1..ID-8.
- [`docs/design/INTERACTIVE_DISMANTLING_RESEARCH.md`](docs/design/INTERACTIVE_DISMANTLING_RESEARCH.md) (`#30`) — `filo_bolt` / `offload_carmenu` / CHOPNET / `runBoltSurface`; quadro ADOPT/STUDY/REJECT.

**`#29`/`#30` ficam ABERTOS durante a QA** (não mergear enquanto Q1–Q4 são
certificados). `#30` está empilhado sobre `#29`. Ordem depois do merge:
`#29` → rebase/merge `#30` → **ID-1** (façade inerte) → **ID-2** (Wheels V2
domínio server-side) → **ID-3** (Wheel Bolt físico). Nada de runtime antes de Q1–Q4.

## PRs (todas base `pr-h`, squash-merge)

| # | O quê | Muda runtime? | Estado |
|---|---|---|---|
| #14 | P0.2 — minigame de placa frente/traseira-aware; asset pago removido; `stream/` esvaziado | SIM (`Bolt3D.Enable=false` → skillCheck) | merged |
| #15 | P0.3 — 4 notificações server → `L()`; bloco morto removido de `client/fence.lua` | cosmético | merged |
| #16 | P0.4 — restart recovery: `vp_chop_carcass`, barreira anti re-discard, sweep de boot | SIM | merged |
| #17 | P1.1 — `shared/registry/*` inerte + drift check (ZERO drift) | não | merged |
| #18 | P1.2 / FASE B — `chop_parts.lua` vira projeção do registry | refator puro | merged |
| #19 | P1.3 / FASE C — `bonnet` valida via registry (vertical slice) | refator | merged |
| #20 | P1.4 / FASE D — validação avançada 100% via registry | refator | merged |
| #21 | P1.5 / FASE E — remove fallbacks hardcode + config morta; **capability:** `enabled=false` → inchopável | refator + capability | merged |
| #22 | P1.6 / FASE F — 11 sites server saem de `ChopParts` → `VPChopPartGtaClass` | refator puro | merged |
| #23 | P2.1 enxuto — 6 sites client saem de `ChopParts`; `chop_parts.lua` → `part_class.lua` | refator client | merged |
| #24 | checkpoint de QA (`docs/audit/V116_INTEGRATION_QA.md`) | doc | merged |
| #25 | `AGENTS.md` + `STATUS.md` + plano mestre no repo | doc | merged |
| #26 | `docs(status)`: #25 mergeado | doc | merged |
| #27 | INT-01A — ponte `vp_chopshop → vp_gangs` (contractVersion 1) | SIM | merged |
| #28 | INT-01C — remove fallback legado da ponte `vp_gangs` (cutover fechado) | SIM | merged |
| #29 | `WHEEL_BOLT_MINIGAME.md` — estudo do `filo_bolt` | doc | **aberto** (segurar até QA) |
| #30 | `INTERACTIVE_DISMANTLING.md` + `_RESEARCH.md` + ponteiros no plano | doc | **aberto** (empilhado em #29) |
| #31 | `STATUS.md` + `AGENTS.md` sync + regra `--force-with-lease` | doc | **aberto** (este PR) |
| #32 | `README`/`CHANGELOG`/`GAMEPLAY` sync p/ v1.16-dev | doc | **aberto** |
| #33 | CI `harness` (workflow + exit code + luac hash-literal + sanity gate) | infra | merged |

## Infra — CI + branch protection

**CI (`#33`):** `.github/workflows/harness.yml` roda `luac -p` (hash-literal CfxLua
neutralizado numa cópia, não pula o arquivo) + `lua5.4 tools/run_spec.lua .` em
`pull_request`/`push` para `main` e `pr-h`. Critério = exit code. Sanity gate no
runner: `SPEC.pass + SPEC.fail == 0` → exit 1 (CI verde com 0 testes é inaceitável).

**Branch protection (rulesets ativos):**

| | `main` | `pr-h` |
|---|---|---|
| PR obrigatório | ✅ (0 reviews) | ✅ (0 reviews) |
| status check `harness` | ✅ | ✅ |
| block deletion | ✅ | ✅ |
| block force-push (`non_fast_forward`) | ✅ | ❌ (permitido — rebase da stack) |
| bypass actors | nenhum | nenhum |

Force-push em `pr-h` fica liberado (a stack `#29`→`#30` rebaseia). Restrição
por-actor (só o dono) foi avaliada mas não aplicada: `bypass_actors` isenta o
ator de **todas** as regras do ruleset, não só do force-push.

**Regra de processo:** nunca `git push --force`. Rebase de stack usa
`git push --force-with-lease`. Registrado em [`AGENTS.md`](AGENTS.md) §4.

**Repo é PÚBLICO** — issue **#34** (`PAID_ASSET_HISTORY_PURGE`) assume "repo
privado → risco contido"; **essa premissa está incorreta**. Os blobs de asset
pago (`stream/bolt.ydr` etc.) continuam alcançáveis no histórico Git de um repo
público. Não executar `filter-repo`/BFG/force-push de histórico sem cumprir todos
os gates da #34 + GO explícito — mas a urgência subiu.

## Decisão de fase (2026-08-28)

O dono suspendeu o RC freeze da v1.15. Motivo: a direção está decidida; testar
uma v1.15 congelada que já vai ser reescrita desperdiça QA. Novo alvo: build
consolidado `v1.16-dev` que a QA valida como um todo. **Não** significa reescrever
o núcleo (ChopSession/ActionSession/discard/deliverCar — fundação de 632 asserts).
Ver `docs/design/MASTER_IMPLEMENTATION_PLAN.md` §1.
