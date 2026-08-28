# ActionSession — FOUNDATION + BASE TYRE (PR-F) + ADVANCED (PR-G)

**PR-F** (PR #9): base tyre (wheel_*). **PR-G** (PR #10): desmanche AVANÇADO
(door/engine/carcass). Plate/VIN, Part/Tool Registry **NÃO** migrados.
`_nonce` do desenho antigo **removido**
(YAGNI — segredo que nunca sai do servidor não acrescenta nada sobre
`actionId + src ownership + server state`; `actionId` é ID opaco, não segredo).

## Arquivos

| Arquivo | Papel |
|---|---|
| `server/session/action_session.lua` | `ActionSession` — lifecycle, ownership, timing, revalidação, action lock, idempotência (replay). Callbacks `vp_chopshop:action:start/complete/cancel`. |
| `server/action/base_tyre.lua` | executor de domínio p/ tyre — delega a `VPChopChopPartCommit` (sem duplicar código). `ActionSession.RegisterExecutor('tyre', …)`. |
| `server/main.lua` | `VPChopChopPartCommit` (domínio extraído do callback legacy) + gate `action_required` p/ tyre no `vp_chopshop:chopPart`. |
| `server/session/jackstand.lua` | +`vp_chopshop:session:getActive` (read-only — client obtém o sessionId). |
| `client/main.lua` | fluxo wheel: getActive → action:start → UX → action:complete/cancel. Kill-switch cai no legacy. |
| `shared/config.lua` | `Config.ActionSession`. |

## Fluxo (BASE TYRE)

```
client: getActive(netId) → sessionId
        action:start { sessionId, action='wheel_lf' }   (client manda SÓ isto)
   server START: enabled · src · partKey · ChopParts.kind=='tyre' · ChopSession.Get
          ativa · vehicle.identity · HasParticipant · raised · not READY_FOR_DISCARD
          · entidade existe · distância · GetPartState==nil · VPChopHasTool · rate limit
          · ChopSession.LockPart  →  ActionSession OPEN  (as:<n>)
        START idempotente por (src, sessionId, partKey) → replay=true, MESMO actionId
client: roda UX (bolt minigame + progress bar); cancela → action:cancel(actionId)
        action:complete(actionId)   (client manda SÓ o actionId)
   server COMPLETE: rate limit · não existe→invalid · src≠→owner ·
          COMPLETED→{ok,replay,result} ZERO side effects · COMMITTING→processing ·
          terminal→closed · expirou→EXPIRED+unlock · elapsed<minDuration→too_fast
          (continua OPEN, waitMs) · REVALIDA TUDO (src/session/vsid/netId/participant/
          raised/entity/distância/tyre/tool/GetPartState==nil/not READY_FOR_DISCARD/
          enabled) → falha: FAILED|CANCELLED + unlock, SEM reward/entitlement/PART_CHOPPED
          · OPEN→COMMITTING (sem yield) · executor (VPChopChopPartCommit) · ok →
          COMPLETED, result={tyreEntitlementId}, unlock · domínio nega ('done') →
          FAILED + unlock
```

## Timing / TTL

- `GetGameTimer()` (ms), nunca `os.time()`.
- `ActionTtlMs` (45000) **clampado abaixo de** `PartLockTtlMs` (60000) — uma action
  OPEN nunca dura mais que o lock autoritativo da peça.
- `MinDurationMs.tyre` (1500) — só `too_fast` (nunca cancela; client espera e rechama).
- Sweeper leve (5s): OPEN expirado → EXPIRED+unlock; OPEN sem ChopSession → FAILED;
  COMMITTING → nunca expira (executor pode estar yieldando); terminal → coletado após
  `RetentionMs` (90s, retenção p/ replay).

## Legacy bypass gate

`Config.ActionSession.RequireBaseTyres` (default **true**): o callback legacy
`vp_chopshop:chopPart` retorna `action_required` p/ qualquer `ChopParts[pk].kind=='tyre'`.
Um executor **não** consegue bypassar start/complete. Peças base não-tyre (bonnet/boot)
seguem no legacy nesta PR. `RequireBaseTyres=false` = emergency switch (legacy tyre
volta; ChopSession + TyreEntitlement seguem verdade; `PlayerTyreStock` **não** ressuscita).

## O que ActionSession **prova** / **NÃO prova**

Prova: ação autorizada · jogador certo · ChopSession certa · veículo/VSID certo ·
peça certa · participante · raised · distância · ferramenta · estado · tempo mínimo ·
single-use · mutex.

**NÃO prova** que o minigame foi jogado honestamente — um executor ainda pode
`start` → esperar `MinDurationMs` → `complete`. **ActionSession ≠ minigame proof ≠
anti-cheat completo ≠ prova de input humano.** É autorização temporal + commit
server-authoritative.

## Tool durability / rewards / entitlement

- START **nunca** consome ferramenta. CANCEL / too_fast **nunca** consomem.
- COMPLETE consome durabilidade **1×** no executor, no commit real.
- `MarkPart` ANTES de reward (commit-before-reward preservado). Duplicate → domínio
  nega `done` → ActionSession FAILED, sem reward.
- `TyreEntitlement.Issue` só no COMPLETE committed, idempotente por `(sessionId, partKey)`.
  `act.result.tyreEntitlementId` → replay devolve o MESMO id, nunca novo.
- `PART_CHOPPED(src, netId, partKey, 1)` — assinatura preservada, 1×, replay = 0.

## PR-G — Advanced (door / engine / carcass)

Core generalizado: `ActionSession.RegisterKind(kind, { minDurKey, distance, validate })`
+ `RegisterExecutor(kind, fn)`. `startCore(src, sessionId, partKey, kind)` faz a
validação COMUM (ChopSession ativa · participante · raised · not READY_FOR_DISCARD ·
entidade · distância do kind · `GetPartState==nil`) e chama `spec.validate`; a
`revalidate` do COMPLETE re-roda `spec.validate`.

| kind | partKey | minDur | dist | validate (START + revalidate) |
|---|---|---|---|---|
| `tyre` | wheel_* | 1500 | ~7 | serra |
| `adv_door` | bonnet/boot/door_* (kind='door') | 1500 | 6 | serra |
| `adv_engine` | `adv_engine` | 2000 | 6 | `bonnet` REMOVED (hood_first) + chave de fenda |
| `adv_carcass` | `adv_carcass` | 2500 | 8 | `adv_engine` REMOVED (engine_first) + `VPChopWelderNearVehicle` |

- **Kind derivado 100% server-side** (`vp_chopshop:action:start` roteia: `adv_engine`/
  `adv_carcass` → special; `ChopParts.kind=='tyre'` → tyre; `=='door'` → adv_door).
- **Executores** (`server/action/advanced_chop.lua`) delegam a
  `VPChopAdv{Door,Engine,Carcass}Commit` (extraídos de `server/advanced_chop.lua`) —
  consume tool → `markPart` (commit ANTES de reward) → `advMarkCooldown` → reward →
  trace → `PART_CHOPPED(src, netId, part, 2|3|4)` → (door) breakDoor broadcast.
- **Legacy gate:** `Config.ActionSession.RequireAdvanced` (default true) → os 3
  callbacks `adv:*` retornam `action_required`. Kill-switch = false. Peça base
  não-tyre (bonnet/boot com AdvancedChop OFF) segue legacy (`chopPart`).
- **Lock unificado:** `VPChopAdvancedState.lockPart` **É** `ChopSession.LockPart` — o
  fluxo legacy e a ActionSession disputam o MESMO mutex de peça (interlock correto).
- **AdvCooldown (3s)** preservado: `StartAdvanced` checa `VPChopAdvOnCooldown` no
  START; o executor marca via `advMarkCooldown`.
- **1 action OPEN/jogador** cobre tyre + advanced juntos (não pode ter door OPEN e
  tyre OPEN ao mesmo tempo).
- `COMMIT_MAX_MS` 30s → **60s** (folga p/ inventory ops sob carga).

## Hardening (revisão adversarial OmniRoute)

9 vetores. 5 refutados (race OPEN→COMMITTING — FiveM Lua é single-thread cooperativo,
o 2º COMPLETE só roda depois do 1º yieldar dentro do executor, e a transição é
yield-free = mutex; `actionId` incremental — ownership validado em complete/cancel;
`TyreEntitlement.Issue` duplo — `if not ok return` ANTES do bloco Issue + Issue
idempotente por `(sessionId,partKey)`; config-flip do gate legacy — `ChopInProgress`
+ `MarkChopped` duplicate + Issue idempotência já cobrem; too_fast spam — limitado a
1 lock/jogador pelo cap abaixo). **4 procedentes, corrigidos:**
1. **Executor travado em COMMITTING** (edição futura com yield infinito) vazaria o
   lock da peça — sweeper agora tem backstop `COMMIT_MAX_MS` (30s) → `FAILED` + unlock.
2. **Clamp de TTL abaixo de MinDuration** tornava a action impossível de concluir
   (`too_fast` → espera → `expired`) — START agora recusa `misconfigured` + log em
   vez de criar uma action doomed.
3. **START com partKey diferente no retry** abria uma 2ª action (griefer travava as
   4 rodas) — **1 action OPEN por jogador** (`OpenBySrc[src]`); 2ª peça enquanto a
   1ª OPEN → `busy` (cancelar/concluir a atual primeiro).
4. **`RetentionMs`** 90s → 120s (janela de replay mais folgada p/ retry lento).

## PR-G follow-up — 4 hardenings no core

1. **`EnforceRaised=false` preservado.** Predicate único `shared/action_gate.lua`:
   `VPChopActionModeAdvanced()` = `Enable ~= false AND RequireAdvanced ~= false AND
   NOT (ChopSession.EnforceRaised == false)`. Quando false → **modo legacy compat**:
   client advanced usa o callback legacy · o callback legacy **não** gate
   `action_required` · `ActionSession.StartAdvanced` → `action_disabled`. O contrato
   PR-C (advGate compat → `ensureSession` → ChopSession state) segue funcionando.
   **`EnforceRaised=false` REDUZ a proteção temporal da ActionSession p/ advanced —
   é compatibility/emergency mode.**
2. **Kill-switch EXCLUSIVO.** Nunca ActionSession + legacy ativos juntos.
   `VPChopActionModeTyre()` = `Enable ~= false AND RequireBaseTyres ~= false`.
   Client `useAction`, gates legacy (`chopPart`/`adv:*`) e `StartBaseTyre`/
   `StartAdvanced` (→ `action_disabled`) usam o MESMO predicate.
3. **Replay idempotente ANTES do rate-limit.** START: `OpenByKey` (replay) → depois
   `StartRate`. COMPLETE: `COMPLETED`(replay)/`COMMITTING`(processing)/terminal(closed)
   → depois `CompleteRate`. Um retry idêntico em <500ms nunca vira `processing`.
4. **COMMITTING FAIL-CLOSED.**
   - `ChopSession.PinPartLock(sessionId, partKey, token)` → o lock deixa de expirar
     por TTL. `Complete` faz PIN **antes** de COMMITTING; pin falha → `FAILED lock_lost`,
     domínio NÃO roda.
   - Sweeper: COMMITTING > `COMMIT_MAX_MS` → **NÃO libera** (a coroutine pode voltar
     → dois commits). Continua COMMITTING · `commitStalled=true` · log SEVERE 1×. A
     peça fica presa até o executor retornar / restart / admin futuro.
   - `OpenBySrc`/`OpenByKey`: **OPEN OU COMMITTING** = ocupado (`busy`/`processing`),
     índice NÃO limpo.
   - `_test.reset` limpa `OpenBySrc`.

## Testes — AS1–AS23 + AS-C1–4 + AS-R1/R3/R4 + AT1–AT13 + ADV1–ADV20 + clamp (`action_session_spec`, 91 asserts)

START (AS1–AS9): OPEN · replay mesmo id · outro player→processing · fake session ·
nonparticipant · raised=false · non-tyre · no_tool · distance. COMPLETE/timing
(AS10–AS19): too_fast (continua OPEN) · COMMITTING→COMPLETED · replay · replay não
re-commita · owner · expired+unlock · cancel+unlock · disconnect+unlock · session
gone→FAILED · READY_FOR_DISCARD→discarding. Legacy gate (AS20/21). Vertical slice
(AT1–AT13): part REMOVED · 1 entitlement · replay mesmo id · reward/tool/PART_CHOPPED
não repetem · cancel→não removida · too_fast→não removida · afastou→distance · tool
sumiu→no_tool · outro player removeu→done sem reward · discard freeze→discarding ·
response loss→replay mesmo id. Clamp ActionTtl < PartLockTtl.

## TEST_PLAN de servidor (só o dono roda)

carry/prop no client · ox_target · minigame real · A e B na mesma roda → só 1 START ·
A wheel_lf + B wheel_rf → independentes · A start + disconnect → lock liberado, B
inicia depois · A completa e perde resposta → retry não duplica · `resmon` · kill-switch.

---

## (histórico) desenho original

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
