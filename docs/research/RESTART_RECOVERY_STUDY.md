# RESTART_RECOVERY_STUDY

**Escopo:** análise. Nenhuma linha de runtime nesta etapa. Alimenta um futuro `RESTART_RECOVERY_RFC.md` **pós-RC**.
**Pergunta central:** depois de `ensure vp_chopshop` (e depois de restart de servidor), qual estado deve sobreviver, qual pode ser perdido, qual deve ser reconstruído ou invalidado?

---

## 1. Como o `vp_chopshop` guarda estado hoje (evidência)

| Estrutura | Armazenamento | Evidência |
|---|---|---|
| ChopSession | Lua table `Sessions = {}` in-memory + sweeper | `server/session/chop_session.lua:82,84` (`Sessions`, `ByVehicleNetId`), sweeper `:604,644` |
| VSID do veículo | statebag **server-local** (`Entity(ent).state:set('vpChopVsid', vsid, false)`) | `server/session/chop_session.lua:68` |
| ActionSession | Lua table in-memory + sweeper (mesmo padrão) | `server/session/action_session.lua` |
| TyreEntitlement | ledger in-memory | `server/logistics/tyre_entitlement.lua` |
| TruckStorage | in-memory + statebag `vpChopTyreStorageId` **server-local** (`:set(MARKER_KEY, sid, false)`) + `chopTyreCount` replicado (só UX) | `server/logistics/truck_storage.lua:41,51` |
| `vpChopDeliveredMark` (barreira anti-revenda do deliverCar) | statebag **server-local** na entidade (`:set('vpChopDeliveredMark', mark, false)`) | `server/session/deliver_car_util.lua:33,44` |
| Discard tombstone | in-memory (sessão) | `server/main.lua:521,530,657` (`cleanupPending`, tombstone) |
| Benches / welders | **DB** (`vp_chopshop_benches`, `vp_chopshop_welders`) | `server/db.lua:24,33,131` — já sobrevive |
| Fake plates | **DB** (`vp_chop_fake_plates`) | `server/db.lua:88` |
| Séries legítimas | **DB** (`vp_chop_legit_serials`) | `server/db.lua:114` |
| Fence trust / orders | **DB** (`vp_chop_fence_trust`, `vp_chop_fence_orders`) | `server/db.lua:50,59` |
| Progression / `last_car_delivery` | **DB** (`vp_chop_progression`) | `server/db.lua:70` |

**Padrão:** tudo que é **econômico e durável** já está em DB. Tudo que é **sessão em progresso** e as **barreiras anti-dupe de operação terminal** são in-memory ou statebag server-local.

---

## 2. O que acontece com um statebag server-local em `ensure <resource>`

`Entity(e).state:set(key, val, false)` grava no **state bag da entidade**, que é gerenciado pelo **core do servidor FiveM**, não pelo resource. Em OneSync:

- **A entidade não é destruída** por um restart de resource. Se a entidade continua no mundo, o **valor** do state bag continua nela.
- O que o resource perde e recria são os **change handlers** (`AddStateBagChangeHandler`) e as tables Lua.
- ⇒ **Expectativa:** `vpChopDeliveredMark` **sobrevive** a `ensure vp_chopshop` enquanto a entidade existir. A leitura `Entity(veh).state.vpChopDeliveredMark` (`deliver_car_util.lua:22`) após o restart deve devolver o mark.

**Isto é uma expectativa de design do core, não uma garantia observada neste servidor.** É exatamente o que a **Fase 19** existe para provar. Motivos pelos quais pode falhar na prática:
1. a entidade foi recriada (netId reuse, respawn por outro resource) → state bag zerado — mas aí o VSID/mark mismatch já protege (Fase 18).
2. o servidor foi reiniciado inteiro (não só o resource) → state bags de entidades transientes **não sobrevivem**; só o DB sobrevive.
3. comportamento de versão do artifact / `state_bag_strict_mode`.

---

## 3. Tabela de decisão por estado

Legenda risco: **P0** dupe de dinheiro/item · **P1** barreira "1×" quebrada sob restart · **P2** perda de progresso sem valor duplicado · **OBS** cosmético.

| Estado | Storage hoje | DEVE sobreviver a restart de *resource*? | DEVE sobreviver a restart de *servidor*? | Pode reconstruir? | Pode invalidar? | Risco se perder | Recomendação (pós-RC) |
|---|---|---|---|---|---|---|---|
| **`vpChopDeliveredMark`** | statebag server-local | **SIM** (barreira anti 2º payout) | **SIM** | Não a partir de memória. **Sim a partir de DB** se existir um `vp_chop_delivered(vehicleid\|vsid, mark, paid_to, ts)` | Sim: TTL longo (ex. 24h) ou quando o carro é comprovadamente deletado | **P1** — 2º jogador entrega o mesmo carro e recebe pagamento | **Criar `vp_chop_delivered` em DB.** `markDelivered` escreve no DB **e** no statebag; a checagem lê statebag e, se ausente, consulta o DB por VSID. Reconcile no boot é dispensável (lookup lazy). É o padrão qbx: nunca confiar só no statebag. |
| **Discard tombstone / `cleanupPending`** | in-memory (sessão) | **SIM** (impede re-pagamento do discard) | **SIM** | Sim a partir de DB | Sim, quando o delete confirma | **P1** — re-descarte do mesmo carro paga de novo (se a entidade sobreviveu ao delete pendente) | Mesmo tratamento do mark: um `vp_chop_discarded(vsid, ts)` pequeno. Hoje o risco é mitigado só enquanto o processo vive. |
| **ChopSession** (estado de desmanche de 1 carro) | in-memory + sweeper | **NÃO** (aceitável perder) | **NÃO** | Parcialmente (peças já entregues estão no inventário; o "quanto falta" não) | Sim — a sessão simplesmente some | **P2** + risco de **re-chop**: se as peças voltam ao carro visualmente mas o inventário manteve as peças antigas, jogador re-chopa e duplica reward | **Fase 20 decide.** Opções: (a) aceitar a perda e documentar (v1.15); (b) persistir só um resumo `{vsid, partsChopped[]}` para o boot recolocar o carro em estado "já desmontado" e negar re-chop. Recomendo (a) para v1.15, (b) como item v1.16 **só se a Fase 20 mostrar dupe real**. |
| **ActionSession** (ação sobre carro levantado) | in-memory + sweeper | **NÃO** | **NÃO** | Não | Some | **OBS** se OPEN (nada foi removido); **P2** teórico se COMMITTING no exato frame do restart (janela ~1 frame, sem yield — mesmo risco já aceito no discard) | Nenhuma ação. Documentar a janela COMMITTING como risco conhecido e igual ao do discard/deliverCar. |
| **TyreEntitlement** (direito de vender N pneus) | ledger in-memory | **Idealmente SIM** | **SIM** | Não | Sim | **P1 potencial** — se o entitlement some mas o pneu (item/prop) continua, ou vice-versa: vender duas vezes, ou perder um pneu pago | **Fase 8/F20b decide.** Se a Fase mostra que restart causa "STORED some mas count econômico fica" ou o inverso → migrar o ledger para DB (`vp_chop_tyre_entitlement`). Se a perda é limpa (some tudo junto) → aceitável para v1.15. |
| **TruckStorage** (`ts:*` + `vpChopTyreStorageId`) | in-memory + statebag server-local + `chopTyreCount` replicado (UX) | **Parcial** | **NÃO** (statebag transiente) | Não | Sim | **P1 potencial** — stale storage marker: `chopTyreCount` visual diz 3, mas o estado real foi perdido → vender fantasma, ou não conseguir vender pneu real | **Fase 9/F20b decide.** O `chopTyreCount` replicado ser "só UX" é bom (ele não é a verdade). Se a verdade in-memory sumir e o marker `ts:*` server-local sobreviver na entidade → derivar a contagem do marker no boot. Se ambos somem → contagem 0 e o pneu "guardado" vira LOST (igual ao lifecycle da Fase 10). |
| **VSID** (`vpChopVsid`) | statebag server-local | **SIM** (é a âncora de identidade para os retries destrutivos) | **NÃO** necessário (sem sessão ativa, sem retry) | Não | — | **OBS** — se some junto com a sessão, sem sessão não há retry destrutivo | Nenhuma ação. VSID só importa enquanto há sessão/marker vivos; se a sessão morreu no restart, o VSID perdido não faz mal. |
| Benches/welders/plates/serials/trust/orders/progression | **DB** | já sobrevive | já sobrevive | — | — | — | Nenhuma ação. É o modelo a seguir. |

---

## 4. Contrato de restart proposto (rascunho para o RFC pós-RC)

> **Regra 1 — Barreiras de operação terminal vão para DB.** `vpChopDeliveredMark` e o discard tombstone protegem contra pagamento duplicado. Pagamento duplicado é P0. Logo essas duas barreiras **não podem** depender apenas de memória/statebag. Um `vp_chop_delivered` e um `vp_chop_discarded` mínimos (chave = VSID ou vehicleid, timestamp, TTL), escritos junto com o statebag, lidos como fallback. Sem reconcile ativo no boot — lookup lazy na hora da checagem.

> **Regra 2 — Sessões em progresso podem ser perdidas.** ChopSession/ActionSession/ProcessSession são efêmeras por design. A perda é aceitável **desde que** a perda não crie valor: peças já no inventário são reais; a sessão perdida só significa "recomeçar o desmanche". O único perigo é **re-chop** — e só se a Fase 20 provar que o carro volta a um estado chopável com o inventário mantendo as peças antigas.

> **Regra 3 — Entitlement e storage seguem a Fase de QA.** Migrar `TyreEntitlement`/`TruckStorage` para DB **só** se as Fases 8–10 e a F20b mostrarem desync econômico real (contagem visual ≠ verdade, ou pneu pago que some/duplica). Persistência tem custo e cria novos estados inconsistentes — não persistir "porque sim" (KB §GAP 2).

> **Regra 4 — Restart de servidor ≠ restart de resource.** Statebags de entidades transientes **não** sobrevivem a restart de servidor. Qualquer barreira que precise valer após restart de servidor **tem** que estar em DB. Isso reforça a Regra 1.

---

## 5. Entrada para a QA (não muda a Fase 19, complementa o registro)

Na Fase 19, além de "o marker sobreviveu SIM/NÃO", registrar:
1. a entidade continuou com o **mesmo netId** após `ensure`? (se mudou, o teste real é o de netID reuse, Fase 18)
2. `Entity(veh).state.vpChopDeliveredMark` lido no console **antes** e **depois** do `ensure` — colar os dois valores crus.
3. repetir com **restart de servidor inteiro** (não só o resource) e registrar o resultado separadamente — esse caso é o que decide se o `vp_chop_delivered` em DB é v1.15 ou v1.16.

Mesma coisa para a F20b (logística): registrar `chopTyreCount` (statebag replicado) **e** a contagem econômica real, antes e depois, para achar o gap.

---

## 6. Referência externa

`qbx_core/server/vehicle-persistence.lua` — o qbx trata isto assim: `saveAllVehicle()` em `onResourceStop` (`:248-252`) e em `txAdmin:events:scheduledRestart` @ 60s (`:254-258`); `onResourceStart` reconcilia `cachedVehicles` do DB contra `GetGamePool('CVehicle')` (`:234-246`). Nunca assume que memória/statebag sobrevive. É a fonte do padrão da Regra 1 e da Regra 4.
