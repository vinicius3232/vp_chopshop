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

```
Create(netId, src)          → session|nil, err     idempotente por netId (sessão viva → devolve-a)
Get(sessionId)              → session|nil          revalida liveness (stale → cleanup + nil)
GetByVehicle(netId)         → session|nil          idem
AddParticipant(id, src)     → bool
HasParticipant(id, src)     → bool
SetState(id, state)         → bool, err            recusa transição inválida e estados terminais
CanTransition(from, to)     → bool
MarkRaised(id, src)         → bool                  raised=true; CREATED→RAISED
ClearRaised(id)             → bool                  raised=false; RAISED→DISMANTLING
IsRaised(netId)             → bool                  conveniência p/ consumidores
GetPartState(id, partKey)   → 'REMOVED'|nil
MarkPart(id, partKey, src)  → bool, duplicate       idempotente (2ª vez → true,true)
LockPart(id, partKey)       → bool, token           mutex de ação, token de uso único
UnlockPart(id, partKey, tk) → bool
Touch(id)                   → nil                   bump lastActivity
Complete(id)                → bool                  terminal, idempotente
Cancel(id, reason)          → bool                  terminal, idempotente
CleanupVehicle(netId)       → nil                   entityRemoved
CleanupPlayer(src)          → nil                   playerDropped
Debug()                     → snapshot              observabilidade
ChopSession._test.*         → seam de teste (setEntityAPI / reset / _sessions)
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
| `vp_chopshop:session:requestRaise` | `(netId)` | `{ok=true, sessionId, vsid, already}` | `disabled/player/cooldown/net/vehicle/class/range/no_item/session` |
| `vp_chopshop:session:requestLower` | `(netId)` | `{ok=true, stale?}` | `player/net/not_participant` |
| `vp_chopshop:session:isRaised` | `(netId)` | `{raised=bool}` | — |

`requestRaise` valida: feature on, player ready, cooldown 2 s, netId/entidade,
classe de veículo (server-side `GetVehicleClass`), proximidade
(`Config.Jackstand.MaxCarDistance + 2`), **posse do item** `chopshop_jackstand`
(`InvCount` server-side — antes só o export client implicava posse). Então
`ChopSession.Create` (idempotente) + `AddParticipant` + `MarkRaised`.

Cliente (`client/main.lua`): a progress bar de "colocando macacos" roda primeiro
(UX); **só depois** o client chama `requestRaise`; **só com `ok=true`** aplica o
visual (`spawnJackstandProps` + `doLiftVehicle`) e grava `JackstandData[veh]`
(agora com `sessionId`/`vsid`). Lower: progress bar → `requestLower` → visual
sempre limpo (mesmo se a sessão já sumiu).

**O que NÃO mudou nesta PR:** `chopPart`, `adv:chopPart/chopEngine/chopCarcass`,
`discardVehicle` — nenhum consulta `IsRaised` ainda. `AdvState` e `ChoppedByNetId`
intactos. P1-1 (advanced chop sem checar elevação) **continua aberto** — fecha na
próxima PR, que é o primeiro item do plano de migração abaixo.

## Testes

`server/session/chop_session_spec.lua` — **34 asserts, 34 PASS** (rodado via
harness Lua standalone `run_spec.lua` e pronto p/ rodar no servidor com
`vp_chopshop_selftest 1`). Cobre:

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

**Fora do harness (pendente servidor real):** sweeper de timeout (thread), 2–4
players concorrentes reais, `resmon`, discard concorrente end-to-end, integração
com o fluxo de tyre. Ver seção Riscos.

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
| `entityRemoved` não dispara + netId reciclado no mesmo modelo dentro do timeout | timeout curto + `ownedId`; recheck de placa seria falível (placas falsas) — fora de propósito |
| Advanced chop ainda não checa `IsRaised` (P1-1 aberto) | **1º item do plano de migração** abaixo; não regride nada (comportamento atual preservado) |
| `Config.ChopSession.Enable=false` desliga o módulo → `Create` retorna `nil,'disabled'` → `requestRaise` nega → jackstand para de funcionar | documentado; default `true`. Kill-switch consciente. |
| `_partLocks` sem TTL — lock preso se consumidor esquecer `UnlockPart` | nenhum consumidor usa ainda; a fase que adotar `LockPart` deve pareá-lo com `UnlockPart` em todos os returns (padrão dos mutex do hotfix) ou adicionar TTL |
| Spec usa seam `ChopSession._test` — superfície extra em produção | inerte (só expõe funções); poderia ser `nil`-ado sob convar num hardening futuro |

## Commits

| SHA | Conteúdo |
|---|---|
| `<c1>` | `arch(v1.15): ChopSession core + VehicleSessionId + jackstand server API` — core, jackstand.lua, spec, fxmanifest, config, docs |
| `<c2>` | `arch(v1.15): route client jackstand through ChopSession` — client/main.lua |

Cada commit é carregável isoladamente (c1: callbacks server existem mas o client
ainda usa o fluxo antigo, sem regressão; c2: client passa a usar).

## Plano exato da PRÓXIMA migração (aguardar aprovação)

**PR seguinte — `advanced chop → ChopSession` (ETAPA 5 primeiro, é o consumidor mais limpo):**

1. `server/advanced_chop.lua`: no início de `adv:chopPart`/`chopEngine`/`chopCarcass`,
   resolver `session = ChopSession.GetByVehicle(netId)`; se `Config.ChopSession.EnforceRaised`
   (novo, default `true`) e `not session.raised` → `return { ok=false, err='not_raised' }`.
   **Fecha P1-1.**
2. Substituir `AdvState[netId][key]` por `ChopSession.MarkPart(session.id, key, src)` +
   `ChopSession.GetPartState`. Manter helper `isChopped(netId,key)` como fachada que
   consulta a sessão (call sites não mudam).
3. Substituir o mutex `AdvMutex` por `ChopSession.LockPart`/`UnlockPart` (pareado em
   todos os returns).
4. `leaveAdvancedTrace` e emissão de `PART_CHOPPED` inalterados.
5. Spec: adicionar casos de `EnforceRaised`, dependência capô→motor via `parts`.
6. Teste servidor: adv chop sem jackstand → DENY; com jackstand → OK; 2 players.

**PR +1 — `base chop → ChopSession` (ETAPA 4):** `ChoppedByNetId` → `session.parts`;
`VPChopWasChopped`/`VPChopGetPartCount`/`VPChopClearVehicle` viram fachadas da sessão;
`chopPart` cria/toca a sessão. Discard passa a contar `session.parts` (ETAPA 6),
preservando o mutex `DiscardBusy` do P0-4.

**PR +2 — tyre entitlement (ETAPA 7):** `PlayerTyreStock` → `session.parts[wheel_*]`
com ciclo `REMOVED→CARRIED→STORED→SOLD`; `loadToTruck`/`sellTyres` consomem por
`sessionId+partId` em vez do crédito genérico.

**Depois:** desenho da interface `ActionSession` (só desenho).

Não avançar automaticamente — cada PR passa por revisão.
