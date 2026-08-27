# ChopSession — fundação (v1.15 `arch/v1.15-chop-session`)

Fonte server-authoritative única do estado de um desmanche. **Esta PR é só a
fundação** — o core existe, é testado, e o jackstand é o primeiro consumidor.
**Nada de base/advanced chop, Bolt V2, catalytic, contracts, market, condition,
config split.**

Base: HEAD de `security/v1.15-p0-hotfix` (`1984eee`). Stacked PR — não mergear
antes da #2.

## Arquivos

| Arquivo | Tipo | Papel |
|---|---|---|
| `server/session/chop_session.lua` | novo | módulo core (tabela global `ChopSession`) |
| `server/session/jackstand.lua` | novo | consumidor: jackstand raise/lower server-side |
| `server/session/chop_session_spec.lua` | novo | self-test (só roda com `setr vp_chopshop_selftest 1`) |
| `fxmanifest.lua` | edit | +3 server_scripts após `server/validate.lua` |
| `shared/config.lua` | edit | +`Config.ChopSession` (4 chaves) |
| `client/main.lua` | edit | `VPChopJackstandRaiseCar`/`LowerCar` passam pelo servidor |

Sem mudança de schema. Sem dependência nova.

## API pública (`ChopSession.*`)

**Lookup ATIVO** (gameplay) vs **read TERMINAL/debug** — separados (fix #1 da review):

```
Create(netId, src)          → session|nil, err
    · sessão ATIVA p/ o netId  → devolve-a (idempotente) + AddParticipant
    · sessão CANCELLED         → descarta, cunha NOVA (cs/vsid novos)
    · sessão COMPLETED + veículo ainda existe → nil, 'completed'  (não reabre)
Get(sessionId)              → session|nil    ACTIVE lookup: terminal → nil; revalida liveness
GetByVehicle(netId)        → session|nil    ACTIVE lookup (terminal → nil)
                                            (não há `Peek` público — read terminal/debug é via Debug())
AddParticipant(id, src)     → bool           false se terminal
HasParticipant(id, src)     → bool
SetState(id, state)         → bool, err      recusa transição inválida e estados terminais
CanTransition(from, to)     → bool
MarkRaised(id, src)         → bool            false se terminal; raised=true; CREATED→RAISED
ClearRaised(id)             → bool            false se terminal (fix #4); raised=false; RAISED→DISMANTLING
IsRaised(netId)             → bool            conveniência p/ consumidores
GetPartState(id, partKey)   → 'REMOVED'|nil
MarkPart(id, partKey, src)  → bool, duplicate idempotente (2ª vez → true,true)
LockPart(id, partKey)       → bool, token     mutex de ação, token único, TTL 60s
UnlockPart(id, partKey, tk) → bool
Touch(id)                   → nil
Complete(id)                → bool, err       SÓ de READY_FOR_DISCARD (fix #3); COMPLETED→OK idempotente
Cancel(id, reason)          → bool            terminal, idempotente
CleanupVehicle(netId)       → nil             entityRemoved
CleanupPlayer(src)          → nil             playerDropped
Debug()                     → snapshot        observabilidade
ChopSession._test.*         → seam (só exposto sob convar vp_chopshop_selftest=1)
```

## Estrutura interna da sessão

```lua
{
  id           = 'cs:<n>',
  vehicle = {
    netId, identity = 'vsid:<n>', model, realPlate,
    _fp = { netId, model, plate, ownedId, mintedAt },  -- fingerprint p/ liveness
  },
  state        = 'CREATED',            -- FSM coarse (abaixo)
  startedBy    = <src>,
  participants = { [src] = true, ... },
  createdAt, lastActivity,
  parts        = { [partKey] = { state='REMOVED', by=<src>, at=<t> } },
  _partLocks   = { [partKey] = <token> },
  raised       = false, raisedBy = nil,
  completed    = false,
}
```

Campos só o necessário p/ migrar o gameplay atual. YAGNI — nada de alarm/tracker/
heat/evidence/storage/condition ainda.

## Máquina de estados (coarse)

```
CREATED ──► RAISED ──► DISMANTLING ──► READY_FOR_DISCARD ──► COMPLETED (terminal)
   │          │  ▲           │  ▲                │
   └──────────┴──┴───────────┴──┴────────────────┴──────────► CANCELLED (terminal)
             (RAISED ⇄ DISMANTLING; lower volta p/ DISMANTLING)
```

- `raised` é **booleano dedicado**, não um estado da FSM (o design pede os dois
  campos). Jackstand toca `raised`; `MarkRaised` também move `CREATED→RAISED` por
  conveniência.
- Regras de dependência entre peças (motor exige capô etc.) **NÃO** estão aqui —
  vão para o Part Registry depois. Nada de centenas de `if state ==`.
- Terminais bloqueiam `SetState`/`MarkPart`/`MarkRaised`.

## Lifecycle / cleanup

| Gatilho | Efeito |
|---|---|
| `entityRemoved(veh)` | `CleanupVehicle(netId)` — sessão removida na hora, índice reverso limpo |
| `playerDropped` | `CleanupPlayer(src)` — sai dos participantes. Restam outros → sessão vive, `startedBy` reatribuído. Fica vazia → `Cancel(id,'abandoned')` |
| sweeper (30 s) | inativa > `SessionTimeoutMs` → `Cancel(id,'timeout')`; terminal > 60 s → coletada; veículo inválido → `CleanupVehicle` |
| `Get`/`GetByVehicle` | recheck de liveness — modelo do `netId` mudou ou entidade sumiu → cleanup + `nil` |

Sem polling de entidades. Sweeper itera só a tabela de sessões.

## Idempotência (preparação p/ ActionSession / retry)

- `Create(netId)` — sessão viva → devolve a mesma (não cunha nova).
- `MarkPart` — peça já `REMOVED` → `(true, true)`, sem duplicar.
- `MarkRaised` / `ClearRaised` / `Complete` / `Cancel` — repetir é no-op de sucesso.
- `requestRaise` (jackstand) — já levantado → `{ ok=true, already=true }`.
- IDs estáveis (`cs:n`, `vsid:n`, tokens de lock) já preparam o terreno p/
  operações tolerantes a callback duplicado / retry / resposta perdida.
- **Sem infra distribuída** — tudo em memória, local, simples.

## Jackstand server-authoritative (ETAPA 3)

`server/session/jackstand.lua` — 3 callbacks:

| Callback | req | ok | deny err |
|---|---|---|---|
| `vp_chopshop:session:requestRaise` | `(netId)` | `{ok=true, sessionId, vsid, already}` | `disabled/player/cooldown/net/vehicle/class/range/no_item/completed/session` |
| `vp_chopshop:session:requestLower` | `(netId)` | `{ok=true}` \| `{ok=true, stale=true}` | `player/net/not_participant` |
| `vp_chopshop:session:isRaised` | `(netId)` | `{raised=bool}` | — |

`requestRaise` valida: feature on, player ready, cooldown 2 s, netId/entidade,
classe de veículo (server-side `GetVehicleClass`), proximidade
(`Config.Jackstand.MaxCarDistance + 2`), **posse do item** `chopshop_jackstand`
(`InvCount` server-side, fail-closed). `ChopSession.Create` (pode negar `completed`).
Então **checa explicitamente** (fix #2) `AddParticipant` e `MarkRaised` — se qualquer
um recusar (sessão terminou nesse meio-tempo) → `{ok=false, err='session'}`, nunca
`ok=true` sobre mutação recusada.

`requestLower` (fix #5): exige `HasParticipant(session.id, src) == true`.
Proximidade **não é bypass** — ajuda externa seria regra de gameplay explícita.
Sessão já sumiu → `{ok=true, stale=true}` (o client limpa o visual mesmo assim).

Cliente (`client/main.lua`): a progress bar de "colocando macacos" roda primeiro
(UX); **só depois** o client chama `requestRaise`; **só com `ok=true`** aplica o
visual (`spawnJackstandProps` + `doLiftVehicle`) e grava `JackstandData[veh]`
(agora com `sessionId`/`vsid`). Lower (fix #6): progress bar → `requestLower` →
baixa o visual **só se `ok==true` OU `stale==true`**; `ok==false` (não-participante)
→ mantém o visual + notifica.

**O que NÃO mudou nesta PR:** `chopPart`, `adv:chopPart/chopEngine/chopCarcass`,
`discardVehicle` — nenhum consulta `IsRaised` ainda. `AdvState` e `ChoppedByNetId`
intactos. P1-1 (advanced chop sem checar elevação) **continua aberto** — fecha na
próxima PR, que é o primeiro item do plano de migração abaixo.

## Testes

`server/session/chop_session_spec.lua` — **75 asserts, 75 PASS** (34 originais +
41 dos 3 rounds de review + micro-fix #7). Rodado via `lua tools/run_spec.lua .` e pronto p/
servidor (`setr vp_chopshop_selftest 1`). Cobre:

| # | Cenário (pedido na review) | Assert |
|---|---|---|
| 1 | retry de callback / Create | idempotente por netId; sem veículo → `nil,'vehicle'` |
| 2 | mesma roda 2× | `MarkPart` 2ª vez → `dup=true`, não duplica |
| 3 | dois players mesma roda | `LockPart` — B recusado até A `UnlockPart` (token válido) |
| 4 | dois players partes diferentes | ambas `REMOVED` |
| 5 | **netId reutilizado** | modelo diferente no mesmo netId → `Get`/`GetByVehicle` = `nil`, índice limpo |
| 6 | veículo removido | `CleanupVehicle` → sessão some |
| 7 | player disconnect | sessão vive c/ participante restante; `startedBy` reatribuído; vazia → `CANCELLED` |
| 8 | estados terminais | `Complete`/`Cancel` idempotentes; pós-terminal bloqueia `SetState`/`MarkPart`/`MarkRaised` |
| 9 | transições | `CREATED→RAISED` ok; `CREATED→COMPLETED`, `COMPLETED→*`, estado inválido bloqueados |
| 10 | jackstand raised autoritativo + retry | `IsRaised` reflete `MarkRaised`/`ClearRaised`; repetir não quebra |
| 11 | FSM por peça | 1ª peça leva `CREATED→DISMANTLING` |
| 12 | **CANCELLED → Create mesmo veículo** | cunha NOVA sessão (novo `cs`/`vsid`) |
| 13 | **COMPLETED → Create mesmo veículo** | `nil,'completed'`; após veículo sumir → cunha nova |
| 14 | **requestRaise nunca ok p/ sessão terminal** | COMPLETED → `ok=false`; CANCELLED → `ok=true` (sessão NOVA) |
| 15 | **Complete respeita FSM** | `CREATED/RAISED/DISMANTLING → DENY`; `READY_FOR_DISCARD → OK`; `COMPLETED → idempotente OK` |
| 16 | **non-participant requestLower** | DENY; `raised` intacto; participante → OK |
| 17 | requestLower deny (contrato client) | `ok=false` **sem** `stale` → gatilho p/ o client MANTER o visual |
| 18 | **netId reuse, MESMO modelo, marcador disponível** | marcador server-local não bate → `Get` = `nil` |
| 19 | fallback: `:set` falha | `markerSet=false` → cai no check de modelo/`ownedId` |
| 7A | marker WRITE+READBACK ok | `markerSet=true`, sessão válida |
| 7B | `:set` não lança mas readback `nil` | `markerSet=false`; sessão sobrevive pelo fallback; modelo igual não distingue; modelo ≠ → stale |
| 7C | readback devolve VSID diferente | `markerSet=false` no mint |
| 7D | `markerSet=true` e marcador adulterado depois | `Get` → `nil` (stale) |
| 20 | sweeper: sessão ATIVA inativa > `SessionTimeoutMs` | → `CANCELLED` |
| 21 | sweeper: sessão TERMINAL idle > 60s | coletada de `Sessions` + índice limpo; `Create` volta a cunhar |
| 22 | sweeper: sessão ATIVA com veículo sumido | `CleanupVehicle` |

**Fora do harness (pendente servidor real):** sweeper de timeout (thread), 2–4
players concorrentes reais, `resmon`, **confiabilidade do state bag server-local
`Entity(ent).state:set(...,false)`** (fix #7 — se o runtime não persistir, cai no
fallback; documentar resultado), discard concorrente end-to-end, integração com o
fluxo de tyre. Ver seção Riscos.

## Multiplayer (trace)

- 2 players levantam o mesmo carro: 1º `Create` cunha; 2º `Create` acha a sessão
  viva e só `AddParticipant`. `MarkRaised` idempotente. Ambos participantes.
- 1 player sai: sessão vive p/ o outro (`startedBy` reatribuído). Ambos saem →
  `Cancel('abandoned')`; sweeper coleta.
- Carro explode/despawna com 2 players dentro do fluxo: `entityRemoved` →
  `CleanupVehicle` → próxima chamada de qualquer um vê `GetByVehicle == nil`.
- `LockPart` garante que 2 players não "removem" a mesma peça — mas **nesta PR
  nenhum gameplay chama `LockPart/MarkPart`**; é a base p/ a próxima migração.

## Riscos

| Risco | Mitigação / nota |
|---|---|
| `requestRaise` roda **depois** da progress bar de 8 s — cheater/afastado só descobre o deny no fim | aceitável nesta fase; ActionSession (start-token antes da UX) resolve na fase seguinte |
| `entityRemoved` não dispara + netId reciclado no mesmo modelo dentro do timeout | model + **marcador server-local `vpChopVsid` (fix #7)** + `ownedId` + timeout. Só resta: marcador não confiável no runtime **E** modelo igual **E** `entityRemoved` falhou — muito estreito |
| Marcador `vpChopVsid` pode não persistir/ser legível no runtime | `_fp.markerSet` só vira `true` com **WRITE + READBACK confirmado** (`:set` → relê `Entity(ent).state.vpChopVsid` → `== vsid`). Falha em qualquer etapa → `markerSet=false` e o marcador **não participa** de `vehicleStillValid` (fallback model/ownedId/entityRemoved/timeout). Ausência do marcador **nunca** invalida sessões. Validar no servidor real. |
| Advanced chop ainda não checa `IsRaised` (P1-1 aberto) | **PR A** do plano abaixo; não regride nada |
| `Config.ChopSession.Enable=false` → `Create` = `nil,'disabled'` → jackstand para | documentado; default `true`. Kill-switch consciente. |
| `_partLocks` TTL 60s (`Config.ChopSession.PartLockTtlMs`) | lock não liberado expira sozinho; a fase que adotar `LockPart` ainda deve parear com `UnlockPart` em todos os returns |
| Seam `ChopSession._test` | **só definido sob convar `vp_chopshop_selftest=1`** — em produção é `nil` |
| `Create` de sessão `COMPLETED` cujo veículo foi coletado pelo sweeper (>60s) antes de `entityRemoved` | após a coleta o índice reverso some → `Create` cunha nova. Aceitável: um chop concluído já deveria ter o veículo descartado. Ver **Nota p/ PR B**. |
| **Fallback (sem marcador) + netId reciclado no MESMO modelo + `entityRemoved` perdido, sobre sessão `COMPLETED`** | `vehicleStillValid(raw)` = true (só model) → `Create` do veículo novo é **negado** com `completed` (falso-positivo). É **fail-safe** (nega, não corrompe); auto-cura no `entityRemoved` ou na coleta terminal em 60s. Não vale trocar por um falso-allow de reabertura. |

## Commits

| SHA | Conteúdo |
|---|---|
| `bd334ca` | `arch(v1.15): ChopSession core + VehicleSessionId + jackstand server API` |
| `5eed8e0` | `arch(v1.15): route client jackstand through ChopSession` |
| `<c3>` | `arch(v1.15): follow-up — terminal-session invariants + lower authority + VSID marker` — fixes #1–#8 + round-2 (Peek removido, re-tag em Create idempotente, sweeper testável) + micro-fix #7 (marker WRITE+READBACK). 34 → 75 asserts. |

## Plano exato da PRÓXIMA migração (ordem da review — aguardar aprovação)

**PR A — P1-1 MINIMAL.** *Só* fecha P1-1. `AdvState` **preservado**.
- `server/advanced_chop.lua`: no topo de `adv:chopPart`/`chopEngine`/`chopCarcass`,
  `local session = ChopSession.GetByVehicle(netId)`; se `Config.ChopSession.EnforceRaised`
  (novo, default `true`) e (`not session` ou `not session.raised`) →
  `return { ok=false, err='not_raised' }`.
- `Config.ChopSession.EnforceRaised = true`. Flag de rollback.
- Spec: casos `not_raised` (sem sessão / sessão não-raised / com raised → OK).
- Teste servidor: adv chop sem jackstand → DENY; com → OK; 2 players.
- **Nada mais.** Nenhuma mudança em `AdvState`/`AdvMutex`/rewards.

**PR B — base chop → ChopSession.** `ChoppedByNetId` → `session.parts`.
`VPChopWasChopped`/`VPChopGetPartCount`/`VPChopClearVehicle` viram fachadas que
consultam a ChopSession. `chopPart` cria/toca a sessão. Preserva rate-limit +
mutex + todos os hardenings do hotfix.

**PR C — advanced chop → ChopSession.** *Só depois do base.* `AdvState` →
`session.parts`; `AdvMutex` → `LockPart`/`UnlockPart` (pareado). Neste ponto
base + advanced têm **uma** fonte de verdade.

**PR D — unified discard.** `discardVehicle` conta `session.parts` (base + advanced)
em vez do contador só-base. Preserva o mutex `DiscardBusy` do P0-4.
⚠️ `ChopSession.Complete` só transita de `READY_FOR_DISCARD` (fix #3). O fluxo do
discard deve fazer `SetState(id,'READY_FOR_DISCARD')` **antes** de `Complete(id)` —
não adicionar transição `DISMANTLING→COMPLETED`.

**Nota p/ PR B (base chop):** se o sweeper coletar uma sessão `COMPLETED` (>60s idle)
enquanto o veículo ainda existe, um `Create` seguinte cunha sessão nova com
`parts` vazio. Quando o base chop passar a consumir `session.parts`, a re-criação
nesse veículo deve **semear `parts` a partir do estado real do veículo** (natives
GTA de porta/roda ausente) OU a retenção terminal deve exceder a janela realista
de descarte. Hoje (fundação) nada consome `parts` → inócuo.

**PR E — tyre entitlement.** `PlayerTyreStock` → `session.parts[wheel_*]` com ciclo
`REMOVED→CARRIED→STORED→SOLD`; `loadToTruck`/`sellTyres` consomem por `sessionId+partId`.

**Depois:** implementação da `ActionSession` (desenho já corrigido em `ACTION_SESSION_DESIGN.md`).

Não avançar automaticamente — cada PR passa por revisão.
