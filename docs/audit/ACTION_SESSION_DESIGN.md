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

## Interface proposta (server — `ActionSession.*`)

```
Start(src, opts) → { ok, actionId, nonce, startedAt, expiresAt } | { ok=false, err }
  opts = {
    sessionId  = 'cs:<n>',      -- ChopSession a que a ação pertence
    kind       = 'wheel'|'panel'|'engine'|'plate'|'vin'|...,
    partKey    = 'wheel_lf',    -- opcional conforme kind
    toolItem   = 'impact_wrench',
    netId      = <int>,         -- redundante c/ session, revalidado
  }
  valida: IsValidSource, ChopSession.Get(sessionId) vivo, HasParticipant,
          vehicleStillValid, proximidade, posse da tool, Part Graph deps,
          nenhuma ActionSession aberta do mesmo (sessionId, partKey),
          ChopSession.LockPart(sessionId, partKey).
  efeito: cria ActionSessions[actionId] = { src, sessionId, partKey, kind,
          toolItem, netId, vsid, startedAt, expiresAt, nonce, consumed=false }.

Complete(src, actionId) → { ok, rewards? } | { ok=false, err }
  revalida TUDO de novo (não confia em nada guardado do client):
    - ActionSessions[actionId] existe, src bate, consumed==false, now < expiresAt
    - now - startedAt >= minDurationMs[kind]
    - ChopSession ainda viva, participante, veículo válido (VSID), proximidade
    - tool ainda presente
    - ChopSession.GetPartState(partKey) ainda nil (não removida por outro caminho)
  efeito: consumed=true; ChopSession.MarkPart(...); ChopSession.UnlockPart(...);
          gera rewards/entitlement server-side; emite PART_CHOPPED.
  idempotência: Complete de actionId já consumed → { ok=false, err='consumed' }
                (nunca recompensa 2×). Retry legítimo de rede: o client trata
                'consumed' como sucesso se já viu o resultado, ou re-Start.

Cancel(src, actionId)  → bool     (client cancelou o minigame; libera o LockPart)
Expire sweep                      (thread; actionId > expiresAt → Cancel implícito)
CleanupPlayer(src) / CleanupSession(sessionId)   (playerDropped / sessão morta)
```

`actionId` / `nonce`: strings opacas de uso único. `nonce` é um segredo interno
(não vai pro client) usado como reforço anti-forjamento; `actionId` vai pro client
e volta no `Complete`.

## `minDurationMs` (anti instant-complete)

Por `kind`, configurável (`Config.ChopSession.ActionMinDurationMs = { wheel=1500, panel=2500, engine=6000, ... }`).
Não precisa bater frame a frame — só barrar o absurdo (start e complete em 20 ms).

## Relação com ChopSession

ActionSession **depende** de ChopSession — por isso a ChopSession vem primeiro.
Uma ação sempre pertence a uma sessão (`sessionId`) e usa `LockPart` da sessão
como mutex. Quando a ChopSession morre (`entityRemoved`/timeout), todas as
ActionSessions dela são canceladas.

## Migração (quando autorizado)

1. `chopPart` (base): `Start` no lugar do rate-limit atual; `Complete` no lugar
   do corpo atual. `WasChopped` → `ChopSession.GetPartState`.
2. `adv:*`: idem, com `minDurationMs` maior + Part Graph deps.
3. `stealPlate` / `vinScratch`: `kind='plate'`/`'vin'`.
4. Só então: `Config.ChopSession.RequireActionSession` default `true`; flag de
   rollback mantido 1 release.

Nada disto nesta PR — é o desenho para a ChopSession não bloquear.
