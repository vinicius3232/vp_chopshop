# ActionSession — DESENHO da interface (não implementado)

v1.15 `arch/v1.15-chop-session`. Só o contrato. Migração vem depois da ChopSession
estar madura (base + advanced migrados). **Nenhum código nesta PR.**

## Propósito

Toda ação física com recompensa (remover roda / painel / motor / placa / VIN /
catalytic no futuro) passa a ter um ciclo **start → UX/minigame → complete**, com
o servidor cunhando um token de uso único que amarra a conclusão à autorização.

## O que ActionSession **prova** (e o que **não** prova)

Prova, no `complete`:

- ação foi **autorizada** (existe um `actionId` válido, não expirado, não usado);
- é o **mesmo jogador** que iniciou;
- pertence a uma **ChopSession válida** e ao **veículo certo** (VSID);
- **peça certa** + **ferramenta certa** ainda presentes;
- **pré-requisitos** satisfeitos (Part Graph — futuro);
- **tempo mínimo decorrido** (`minDurationMs` por tipo de ação — anti instant-complete);
- estado atual da sessão permite a ação.

**NÃO prova** que o minigame client-side foi jogado honestamente — um executor
ainda pode `start` legítimo, esperar `minDurationMs`, e forçar `complete`. O
minigame continua sendo **UX/gameplay**; a autoridade de estado e economia é o que
ActionSession protege. (Correção de terminologia da review: ActionSession ≠
"minigame proof".)

## Definições vêm do servidor (8.4)

O **client NUNCA escolhe autoritativamente** `kind`, `toolItem`, `duration` nem
`reward`. O client pede apenas o **alvo**:

```
Start request (client → server):  { sessionId = 'cs:<n>', action = 'wheel_lf' | 'engine' | 'plate' | ... }
```

O servidor deriva tudo do **Part Registry / Tool Registry** (fases futuras):
`kind`, ferramentas aceitas, `minDurationMs`, `noise`, dependências (Part Graph),
tabela de reward. `netId` sai da própria ChopSession (`session.vehicle.netId`),
não do client.

## Interface proposta (server — `ActionSession.*`)

```
Start(src, req) → { ok, actionId, startedAt, expiresAt } | { ok=false, err }
  req = { sessionId, action }         -- SÓ isto vem do client
  server deriva: kind, toolItem(s), minDurationMs, rewardRule  (Part/Tool Registry)
  valida: IsValidSource, ChopSession.Get(sessionId) vivo (lookup ATIVO — terminal
          nunca passa), HasParticipant, vehicleStillValid, proximidade, posse de
          uma tool aceita, Part Graph deps, GetPartState(action) == nil,
          rate-limit por src (8.3), ChopSession.LockPart(sessionId, action).
  efeito: ActionSessions[actionId] = {
            status='OPEN', src, sessionId, action, kind, toolItem, netId, vsid,
            startedAt, expiresAt, _nonce,      -- _nonce NUNCA sai pro client (8.1)
            result=nil,
          }
  Retorna ao client APENAS: actionId, startedAt, expiresAt.

Complete(src, actionId) → { ok, replay?, rewards? } | { ok=false, err }
  0) ActionSessions[actionId] existe? src bate?  senão → err
  1) status == 'COMPLETED' (8.2 — replay de rede):
       return { ok=true, replay=true, rewards = act.result.rewards }
       — mesmo resultado LÓGICO, SEM repetir MarkPart / reward / XP / item /
         money / PART_CHOPPED.
  2) status == 'CANCELLED' / 'EXPIRED' → { ok=false, err='closed' }
  3) status == 'OPEN' → revalida TUDO (não confia em nada guardado do client):
       - now < expiresAt
       - now - startedAt >= minDurationMs[kind]      (anti instant-complete)
       - ChopSession ainda ATIVA, participante, VSID válido, proximidade
       - tool aceita ainda presente
       - ChopSession.GetPartState(action) ainda nil
     efeito atômico (sem yield no meio):
       ChopSession.MarkPart(sessionId, action, src)
       gera rewards/entitlement server-side (rewardRule)
       emite PART_CHOPPED
       ChopSession.UnlockPart(sessionId, action, token)
       act.status = 'COMPLETED'
       act.result = { rewards = <...> }              -- resultado terminal guardado
     return { ok=true, rewards = act.result.rewards }

Cancel(src, actionId)  → bool     status='CANCELLED'; UnlockPart. (client cancelou o minigame)
Expire sweep                      thread; OPEN & now>expiresAt → status='EXPIRED'; UnlockPart
CleanupPlayer(src) / CleanupSession(sessionId)   fecham as ActionSessions afetadas
```

### 8.1 — Nonce
`actionId` é o único token que vai/volta do client. `_nonce` é **segredo interno**
usado só para reforço anti-forjamento no servidor e **nunca é devolvido ao client**.
(O doc anterior devolvia `nonce` no `Start` — corrigido.)

### 8.2 — Idempotência = resultado terminal, não `err=consumed`
`ActionSessions[actionId]` guarda `status` + `result`. Um retry legítimo do MESMO
`src`+`actionId` sobre uma action `COMPLETED` retorna `{ ok=true, replay=true }`
com o **mesmo resultado lógico**, **sem** repetir reward/MarkPart/XP/item/money/
event. Isso cobre resposta de rede perdida sem punir o jogador nem duplicar.

### 8.3 — Rate limit é defense-in-depth
ActionSession **não substitui** rate-limiting. Os rate-limits por `src` dos
callbacks atuais (`chopPart`, `adv:*`, etc.) permanecem — ActionSession soma a eles.

## `minDurationMs` (anti instant-complete)

Por `kind`, configurável (`Config.ChopSession.ActionMinDurationMs = { wheel=1500, panel=2500, engine=6000, ... }`).
Não precisa bater frame a frame — só barrar o absurdo (start e complete em 20 ms).

## Relação com ChopSession

ActionSession **depende** de ChopSession — por isso a ChopSession vem primeiro.
Uma ação sempre pertence a uma sessão (`sessionId`) e usa `LockPart` da sessão
como mutex. Quando a ChopSession morre (`entityRemoved`/timeout), todas as
ActionSessions dela são canceladas.

## Migração (quando autorizado)

1. `chopPart` (base): `Start`/`Complete` envolvem o corpo atual. O rate-limit
   por `src` **permanece** (8.3). `WasChopped` → `ChopSession.GetPartState`.
2. `adv:*`: idem, com `minDurationMs` maior + Part Graph deps.
3. `stealPlate` / `vinScratch`: `kind='plate'`/`'vin'`.
4. Só então: `Config.ChopSession.RequireActionSession` default `true`; flag de
   rollback mantido 1 release.

Nada disto nesta PR — é o desenho para a ChopSession não bloquear.
