# ROADMAP_RECONCILIATION

A KB de pesquisa propõe `PR-I0 … PR-I10`. O `PART_PROCESSING_RFC.md` já tem `#12 … #17`. **São a mesma coisa vista de dois ângulos** e precisam de uma lista só, senão viram duas fontes de verdade concorrentes.

Regra que resolve os conflitos: **RFC ganha nos detalhes de implementação de peça** (é mais recente e mais específico); **KB ganha na ordem macro** (CI e registry antes de feature).

---

## Lista única — pós-RC

| Ordem | ID | Nome | Conteúdo | Origem | Depende de |
|---|---|---|---|---|---|
| — | **RC** | Validação runtime | Fases 3–26 do `V115_RELEASE_CANDIDATE.md`. Fase 19 e 20 são os blockers. **Nada abaixo começa antes disto.** | ambos | — |
| 1 | **R-0** | Research freeze | Guardar `deliverables/` no repo em `docs/research/`. Zero runtime. | KB PR-I0 | RC |
| 2 | **R-1** | CI gate | Workflow que roda `lua tools/run_spec.lua .` em PR/push. Sem mudança de comportamento. Detalhe em §CI abaixo. | KB PR-I1 / KB §GAP 5 | RC |
| 3 | **R-2** | chore M1+M2 | 1 commit isolado: i18n server hardcoded → `L()` (M1) + remover bloco morto `client/fence.lua` (M2). Regressão 493 asserts. | `V115_AUDIT` §6 | R-1 (pra CI pegar a regressão) |
| 4 | **R-3** | Registry drift/parity | Revalidar `ChopParts`, `ChopPartOrder`, `Config.Tools`, `Config.AdvancedChop`, `ActionSession.MinDurationMs`, `VPChopHasTool`, `advanced_chop.lua RegisterKind`, `speedMult`. **Só depois** do drift check do checkpoint do projeto. Ainda sem Part Registry global. | KB PR-I2 | R-1 |
| 5 | **R-4** | `feat(process): domain model + config` | `ox_items` `vehicle_part`; `Config.PartProcessing` (`Enable=false`); `VPChopEvt.PART_PROCESS_*`; docstrings do contrato de metadata. Sem lógica. | **RFC #12** | R-3 |
| 6 | **R-5** | `feat(process): ProcessSession core + specs` | `server/session/process_session.lua` + `_spec.lua` (PROC1–16). START/COMPLETE/CANCEL/replay/pin/sweeper. Sem callback client. | **RFC #13** | R-4 |
| 7 | **R-6** | `feat(process): domain executor + quarantine` | `server/part_processing.lua` executor (RFC D.4) + `VPChopMarkProcessQuarantine` + PROC11–14,17. Emite `PART_PROCESSED`. | **RFC #14** | R-5 |
| 8 | **R-7** | `feat(process): bench UX + callbacks` | `vp_chopshop:process:start/complete/cancel/availability`; opção "Processar peça" em `client/bench.lua`; locale en/pt(+es/fr/tr). PROC5–10. | **RFC #15** | R-6 |
| 9 | **R-8** | `feat(process): forensic integration` | ramo `processed` em `classifyNormal` + `inspectParts`; locale `parts_verdict_processed`; PROC18–19. | **RFC #16** | R-7 |
| 10 | **R-9** | `feat(process): workshop commodity contract` | `exports:ConsumeCarParts` + `:QueryCarParts`; `bridge/workshop.lua` + `Config.Workshop` (Enable=false); `docs/design/WORKSHOP_CONTRACT.md`; análise de arbitragem final (RFC G.3) versionada. | **RFC #17** | R-8 |
| 11 | **R-10** | Restart Recovery RFC | Escrever `RESTART_RECOVERY_RFC.md` a partir de [RESTART_RECOVERY_STUDY](RESTART_RECOVERY_STUDY.md) + resultados das Fases 19/20. Decidir: `vp_chop_delivered`/`vp_chop_discarded` em DB são v1.15.x ou v1.16. Migrar TyreEntitlement/TruckStorage **só se** a QA provou desync. | KB PR-I10 + GAP 1/2 | Fases 19/20 |
| 12 | **R-11+** | Economia avançada · condition/refurb · vehicle rebuilding | DEFER. Cada um exige GO explícito. | KB §8/§20 | R-10 |

> **Nota de numeração:** o PR **#12** real já está aberto (`chore/repo-hygiene-docs`, sem código). Os `#12→#17` do RFC são nomes lógicos — os números reais de PR começam em **#13+**. Usar os IDs `R-4…R-9` desta tabela para não confundir.

**Diferença vs. a KB:** a KB colocava "PR-I3 PhysicalPart" e "PR-I4 RewardResolver" como itens separados. O RFC já dissolveu `RewardResolver` dentro de `#12→#17` (não há big-bang de migração de reward; o `vehicle_part` nasce do executor de advanced_chop e o `car_parts` legado continua). Mantida a decisão do RFC — **não** criar um `RewardResolver` como módulo separado a menos que a implementação de R-4/R-6 mostre necessidade.

**Cada PR:** implementar → `lua tools/run_spec.lua .` verde → `luac -p` → commit → push → body → memória → **PARAR** para revisão. Nenhuma mergeia sozinha. Mesmo workflow da stack `#2→#11`.

---

## CI — proposta mínima (item R-1)

### Fato apurado
- Não existe `.github/workflows/` no repo.
- O harness é **Lua puro**, roda fora do FiveM: `tools/run_spec.lua` faz stub de todos os globals CFX (`CreateThread`, `Entity`, `NetworkGetEntityFromNetworkId`, …). `GetConvarInt`/`GetConvar` retornam `1`/`'1'` → **ativa os specs self-gated automaticamente** no harness.
- Resultado atual: `493 PASS / 0 FAIL` (8 suites).
- `fxmanifest.lua:63-95` lista os `*_spec.lua` como self-gated (`vp_chopshop_selftest 1`) — o CI não precisa do FiveM, só do `run_spec.lua`.

### Workflow proposto (NÃO commitar até R-1, e conferir a stack de PRs antes)

```yaml
# .github/workflows/spec.yml
name: spec
on:
  push:
    branches: [main, 'pr-*/**', 'arch/**', 'security/**']
  pull_request:
jobs:
  harness:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Lua 5.4
        run: sudo apt-get update && sudo apt-get install -y lua5.4
      - name: Run static harness
        run: lua5.4 tools/run_spec.lua .
```

- **Apurado:** `tools/run_spec.lua` (fim do arquivo) só faz `os.exit(1)` em **THREAD ERROR** (spec que dá `error()`/crash). O helper `check(name, cond)` de cada spec, em caso de asserção falsa, apenas incrementa `fail` e dá `print('... FAIL ...')` — **não levanta erro** (ex.: `server/session/deliver_car_spec.lua:18-21`). Ou seja: um spec com 5 FAIL e nenhum crash **hoje sai com exit 0**. Para o CI valer, o harness precisa somar os `fail` das suites e `os.exit(1)` se o total > 0. É edição **no harness** (`tools/`), não em runtime — mas ainda assim pós-RC, dentro de R-1.
- Fase 2 (`getr vp_chopshop`) continua manual: o CI cobre o estático, não o runtime FiveM.

### Depois (não agora)
- `luacheck` com config permissiva (o projeto tem convenções próprias — calibrar o `.luacheckrc` para não afogar em falso positivo de globals CFX).
- Contract test: um spec que falha se `Config.PartProcessing.Types` tiver `partType` sem entrada em locale (quando R-7 existir).
- Registry drift: script que compara `ChopParts` × `ChopPartOrder` × imagens × locale e falha no CI (suporta R-3).

**Ordem:** CI (R-1) **antes** de qualquer PR de feature (R-4+), como a KB §GAP 5 pede. Não modificar o workflow enquanto a stack `#2→#11` não estiver mergeada — um workflow novo em branch não-mergeada roda em contexto que ainda vai mudar.
