# PR-I — checklist de nascimento (pós-RC)

**Status do artefato:** `PR-I.patch` está **CONGELADO** contra `dd1ee9f` (tip de `pr-h` em 2026-08-28).
Schema v2. Não editar mais o spike — qualquer mudança de forma reabre a review adversarial.

**Gate para começar:** RC das 26 fases verde **E** stack `#2→#11` estabilizada/mergeada no `main`.

---

## Processo (na ordem)

```
1. nova branch sobre HEAD limpo
     git fetch origin
     git checkout -b pr-i/v1.15-part-registry origin/main      # (ou o que virou autoridade pós-merge)

2. reaplicar / rebasear o spike
     git apply --3way PR-I.patch
     # se falhar: aplicar os 3 arquivos novos à mão + re-fazer as 8 linhas de wiring
     #   fxmanifest.lua: +tools.lua/+parts.lua em shared_scripts, +registry_spec.lua em server_scripts
     #   tools/run_spec.lua: +2 dofile (módulos, antes de specStart) +1 dofile (spec, depois)

3. DRIFT CHECK  ← o passo que o patch sozinho não cobre (ver §Drift abaixo)

4. parity specs
     lua tools/run_spec.lua .        # registry_spec: 28/28, e a projeção == ChopParts do main

5. harness completo
     lua tools/run_spec.lua .        # total anterior + 28, 0 regressão, exit 0
     luac -p shared/registry/*.lua

6. só então: commit → push → body → memória → PARAR p/ revisão
```

---

## §Drift check — "o contrato ainda representa o runtime que chegou ao main?"

O `registry_spec.lua` **embute** o contrato atual como constantes (`CHOP_PARTS`, `CHOP_PART_ORDER`,
`ADV_CONTRACT`). O patch aplica contra `dd1ee9f`; o RC pode ter mudado qualquer uma dessas fontes.
Reler no HEAD mergeado e comparar **campo a campo** com o que o spec embute:

| Fonte no repo (HEAD pós-merge) | O que o spike assume | Onde conferir no spike |
|---|---|---|
| `shared/chop_parts.lua` — `ChopParts` (labelKey/kind/index das 10) + `ChopPartOrder` | idem `dd1ee9f` | `registry_spec.lua` → `CHOP_PARTS`, `CHOP_PART_ORDER` + `parts.lua` `wheel()`/`bodyDoor()` + `R.order` |
| `server/action/advanced_chop.lua` — `RegisterKind` de `adv_door`/`adv_engine`/`adv_carcass` (minDurKey, distance, `validate` deps + `VPChopHasTool` split) | door=1500/6, engine=2000/6/bonnet/screw, carcass=2500/8/adv_engine/welder-only | `registry_spec.lua` → `ADV_CONTRACT` + `parts.lua` `adv_engine`/`adv_carcass`/`bodyDoor` |
| `shared/config.lua` — `Config.ActionSession.MinDurationMs` (tyre/door/engine/carcass) | 1500/1500/2000/2500 | `ADV_CONTRACT.minDurationMs` |
| `shared/config.lua` — `Config.Tools` (saw_cheap/saw_pro/mechanic_drill: MaxUses) | 2 / 6 / 10 | `tools.lua` `maxUses` + `registry_spec` "maxUses parity" |
| `server/main.lua` — `VPChopHasTool`/`VPChopConsumeTool` (ainda iteram SÓ `Config.Tools`? metadata key `uses_remaining`? default 6?) | sim / `uses_remaining` / 6 | `tools.lua` doc + I10 do review |
| `shared/config.lua` — `Config.AdvancedChop.SawItem`/`ScrewdriverItem` ainda existem e ainda mortos? | mortos (não lidos) | I10; se viraram vivos no RC → schema muda |
| `client/main.lua` — `speedMult` ainda é só client (barra de progresso)? | sim (I1) | `parts.lua` I1 assert |
| peça/porta nova adicionada ao `ChopParts` durante o RC? | não | `R.order` (I4: anexar, nunca inserir) — adicionar a nova peça ao registry + à projeção |

**Regra:** se QUALQUER linha divergir → atualizar **os dois lados** (dado do registry **e** constante embutida no spec) na mesma edição, re-rodar o harness, e registrar a divergência no body do PR. O spec falhar aqui é o sistema funcionando.

---

## Depois do PR-I

O próximo passo **deixa de ser desenhar Registry** e passa a ser o **primeiro consumidor real**:
o vertical slice que transforma uma peça removida em `PhysicalPart` (FASE C do migration path — provável alvo: `bonnet`, sem economia nova, sem carry).

**Só depois do gate atual.** Nada de `PhysicalPart` antes do RC.
