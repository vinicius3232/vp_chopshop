# ADOPT_STUDY_REJECT — lista priorizada

Prioridade = valor × baixo risco × não viola o freeze. Nada aqui é para implementar antes do RC verde.

---

## ADOPT (evidência forte, direção já correta ou pequeno ajuste)

| # | Decisão | Por quê / evidência | Quando |
|---|---|---|---|
| A1 | **Barreiras de operação terminal (`vpChopDeliveredMark`, discard tombstone) ganham espelho em DB.** `vp_chop_delivered` / `vp_chop_discarded` mínimos (VSID, mark, ts, TTL), escritos junto com o statebag, lidos como fallback lazy. | `qbx_core/server/vehicle-persistence.lua:248-258` — qbx nunca confia que statebag/memória sobrevive; salva em DB no stop e antes de restart programado. Statebag server-local **não** sobrevive a restart de servidor. Dupe de pagamento é P0. | R-10 (Restart Recovery RFC), **ou antes** se a Fase 19 com restart de servidor falhar → vira RC-FIX / v1.15.x |
| A2 | **Manter identidade = `vehicleid` (qbx) + VSID/fingerprint; placa só lookup.** | `qbx_core:25-27` e `qbx_vehicles:284-291` fazem exatamente isso; `qb-scrapyard` usa placa e é o anti-exemplo. Já é o que o projeto faz. | já feito — não regredir |
| A3 | **Modelo A para peça física: 1 item `vehicle_part` + metadata `{partType,serial,state,sourceModel,sourceSession}`.** | `ox_inventory:169,220` (stack por metadata é nativo); `renzu_projectcars` mostra o custo de item-por-tipo (9 itens + imagens + config). Ver [PART_PROCESSING_EXTERNAL_REVIEW](PART_PROCESSING_EXTERNAL_REVIEW.md). | RFC #12 / R-4 (pós-RC) |
| A4 | **CI mínimo: `lua tools/run_spec.lua .` em PR/push.** Requer corrigir o exit code do harness (hoje sai 0 mesmo com FAIL de asserção). | KB §GAP 5; harness já é Lua puro, sem FiveM. | R-1 (pós-RC, antes de qualquer feature) |
| A5 | **`ProcessSession` próprio, espelhando invariantes da ActionSession, sem depender de veículo/ChopSession.** | RFC §D.3; nenhuma referência externa tem máquina de estado temporal com replay — não há de quem copiar algo melhor. | RFC #13 / R-5 |
| A6 | **Contrato de oficina = item versionado + eventos + exports + `bridge/workshop.lua` isolado.** Nunca `exports['<oficina>']` no core. | RFC §H já é o desenho da KB §GAP 4; `renzu` acopla direto e por isso é frágil. | RFC #17 / R-9 |
| A7 | **`MySQL.transaction.await` quando (e só quando) uma operação tocar múltiplos registros persistentes.** | CommunityOx docs. Hoje nada no `vp_chopshop` precisa (as transações são de inventário + statebag, não multi-row SQL). | condicional, futuro |

## STUDY (interessante, precisa de dado que só a QA/servidor dá)

| # | Item | O que decide |
|---|---|---|
| S1 | Migrar `TyreEntitlement` para DB | Fases 8–10 + F20b: existe desync econômico real (contagem visual ≠ verdade, pneu pago que some/duplica)? Se não → fica in-memory na v1.15. |
| S2 | Migrar `TruckStorage` para DB / derivar contagem do marker `ts:*` no boot | idem F9/F20b: stale storage marker causa venda-fantasma ou trava? |
| S3 | Persistir resumo da ChopSession (`{vsid, partsChopped[]}`) para negar re-chop no boot | **Fase 20**: o carro volta a estado chopável com o inventário mantendo as peças antigas → dupe de reward? Só então (b); senão aceitar a perda e documentar. |
| S4 | Startup reconciliation ativo (varrer `GetGamePool` × DB × tombstones no boot) | Só vale se A1/S1/S2 colocarem estado suficiente em DB para valer a pena reconciliar. Padrão: `qbx_core:234-246`. Não persistir "porque sim". |
| S5 | Tool Registry / progressão por ferramenta (hands→screwdriver→blowtorch) | `mz-scrap`. Pós-#17. Alimenta `condition`/yield. |
| S6 | Economia de salvage/material (sinks, compradores, obtenção alternativa) | `jim-recycle`. Garantir que o chop não vira a única fonte de material. Pós-#17. |
| S7 | Reuso de peça inteira por oficina (`engine` como item instalável) | `renzu_engine`, `an-engineswap`. Só depois de `vehicle_part → processed → contrato` funcionando. |

## REJECT (não reproduzir)

| # | Padrão | Fonte | Motivo |
|---|---|---|---|
| X1 | Mutação de estado via `RegisterNetEvent` sem `IsValidSource`/rate-limit/mutex | `renzu_projectcars/server/server.lua` (todo o arquivo) | client é autoridade; `GlobalState = data` do client (`:172`). O `vp_chopshop` já abandonou isso — não voltar. |
| X2 | Preço/quantidade/payout calculados a partir de dado enviado pelo client | `renzu:42` (`data.price * Config...`), `:146` | trivialmente explorável. |
| X3 | Placa como lookup principal de ownership | `qb-scrapyard`, `renzu:702` `isPlateOwned` | fake plates, NetID reuse, estado persistente quebram isso. |
| X4 | Item de inventário por tipo de peça (`stolen_engine`, `vehicledoor_lf`, …) | `meta_chopshop`, `renzu` | explosão de `ox_items` + config + locale + imagem por tipo; UX marginal não compensa. Ver A3. |
| X5 | Tratar progressbar/minigame do client como prova de ação | maioria dos chopshops | o `vp_chopshop` já reconhece que UX de client ≠ prova; servidor autoriza/trava/revalida/commita 1×. |

## DEFER (fora de escopo até haver PhysicalPart funcional)

Mercado dinâmico · `condition`/quality/refurbishment · vehicle rebuilding (montar carro completo com peça roubada) · ownable chopshops · employees/workers · leilões · boosting · MDT policial novo. (KB §8, §20.)

---

## RC IMPACT / POST-RC IMPACT

- **RC IMPACT:** nenhum. Nada aqui toca runtime antes do RC. A pesquisa **não** destrava o RC — o gargalo é a QA rodar as Fases 19–20.
- **POST-RC IMPACT:** a ordem de trabalho é `R-1 (CI) → R-2 (chore) → R-3 (drift) → R-4..R-9 (#12–#17) → R-10 (Restart Recovery RFC)`. A única antecipação possível é **A1** virar RC-FIX se a Fase 19 falhar com restart de servidor inteiro.
- **OPEN QUESTIONS:**
  1. `vpChopDeliveredMark` sobrevive a `ensure vp_chopshop`? (Fase 19 — expectativa: sim, statebag em entidade persistente é core-managed)
  2. …e a restart de servidor inteiro? (expectativa: não → A1 vira necessário mais cedo)
  3. Fase 20: restart no meio de um desmanche permite re-chop com dupe de reward? (decide S3)
  4. F20b: restart da logística causa desync entre `chopTyreCount` visual e a verdade econômica? (decide S1/S2)

```
CODE CHANGED: NO
RUNTIME BEHAVIOR CHANGED: NO
RC FREEZE PRESERVED: YES
```
