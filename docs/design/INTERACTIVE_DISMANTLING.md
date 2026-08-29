# VP INTERACTIVE DISMANTLING — arquitetura (design, sem implementação)

> **Status:** DESIGN ONLY. Nenhuma linha de código runtime nesta etapa.
> **Baseline:** branch `pr-h/v1.15-delivercar-terminal-hardening`.
> **Gate de implementação:** `P2.2 = NOT STARTED`. Toda PR de implementação abaixo está
> **BLOQUEADA** até QA Q1–Q4 (`../audit/V116_INTEGRATION_QA.md`) fecharem sem P0/P1.
> Companheiros: [`INTERACTIVE_DISMANTLING_RESEARCH.md`](INTERACTIVE_DISMANTLING_RESEARCH.md) ·
> [`WHEEL_BOLT_MINIGAME.md`](WHEEL_BOLT_MINIGAME.md) · [`MASTER_IMPLEMENTATION_PLAN.md`](MASTER_IMPLEMENTATION_PLAN.md) §3.

---

## 1. Objetivo

Substituir as progress bars passivas do desmanche por **interações físicas com as partes do
veículo**, mantendo o **servidor como autoridade absoluta** sobre estado de peça e recompensa.

Não é um clone do `filo_bolt` nem do CHOPNET. É um sistema próprio, declarativo (dirigido pelo
Part Registry), com degradação graciosa e sem dependência de asset proprietário.

**Princípios inegociáveis:**
1. O resultado do minigame **nunca** remove peça, entrega item, paga reward, dá XP, mexe em heat
   ou notifica `vp_gangs`. Ele só **autoriza o client a pedir `ActionSession:Complete`**.
2. O minigame é dirigido por `Registry.get(partId).action.minigame` — **não** se cria um sistema
   paralelo ao registry.
3. Asset 3D é **opcional**. Sem modelo → modo marcador. O minigame sempre roda; nunca cai
   silenciosamente no skillCheck por falta de asset (só por câmera/geometria quebrada — RC-FINDING-01).
4. Uma thread por sessão de minigame, encerrada deterministicamente no cleanup. Zero thread global.
5. Providers externos (se algum dia) ficam atrás do bridge, instalados à parte. Nunca no repo.

---

## 1.1 GAMEPLAY TARGET — a experiência-alvo

O objetivo final **não é** um conjunto de minigames isolados. É que **desmontar um veículo
pareça um processo físico contínuo**: aproximar → posicionar ferramenta → câmera contextual →
localizar os pontos → agir em cada ponto → a peça se solta fisicamente → vira prop na mão →
levar até armazenamento. Um único arco, sem "abrir um minigame" com corte de tela.

**Regra dura:** cada tipo de peça tem um **procedimento próprio**. É proibido transformar tudo
em variação visual do mesmo `skillCheck`. Se dois providers só diferem na cor do marcador, o
design falhou.

### 1.1.1 Procedimentos-alvo por peça (referência de UX, não contrato)

Os numéricos (nº de pontos, voltas, tolerância, tempo) **não** são fixados aqui — calibração
in-game na P2.2 (`Config.InteractiveDismantling`).

**RODA** — `minigame = 'bolt'`
```
aproximar da roda → posicionar ferramenta (anim + câmera contextual lateral)
→ localizar os N parafusos (projeção + cursor)
→ soltar cada parafuso manualmente (rotação acumulada real, não clique)
→ cada parafuso avança para fora conforme rosqueia
→ último parafuso concluído → ActionSession COMPLETE (revalidate)
→ servidor marca REMOVED → anim de puxar a roda → roda some do veículo
→ prop físico vai para a mão → estado CARRIED (TyreEntitlement)
→ jogador leva até truck/bancada → STORED (DB)
```

**PORTA** — `minigame = 'cut'`
```
selecionar a porta → câmera enquadra dobradiças/pontos de fixação → ferramenta (serra) aparece
→ jogador realiza os cortes necessários (arrastar o cursor ao longo de cada linha)
→ faíscas + som de serra + feedback por ponto
→ cada ponto de fixação muda de estado de apresentação (ATTACHED→...→CUT)
→ último corte → ActionSession COMPLETE → porta se desprende (física) / quebra
```

**CAPÔ / PORTA-MALAS** — `minigame = 'cut'`
Mesma filosofia da porta, com pontos de corte/fixação próprios (batentes frontais / traseiros,
derivados do bone `bonnet` / `boot` + `GetModelDimensions`).

**MOTOR** — `minigame = 'mechanical'`
```
gate: bonnet REMOVED (requires — já exigido pelo ActionSession no START)
→ acessar o motor → câmera contextual sobre o bloco
→ remover parafusos/suportes (pontos 'bolt', em ordem)
→ desconectar pontos mecânicos (mangueiras, chicote — pontos 'disconnect')
→ desconectar os componentes necessários
→ liberar o motor (ponto 'release')
→ conclusão server-authoritative (revalidate) → rewardProfile engine_bulk
```

**BATERIA / ECU / RÁDIO** — `minigame = 'wiring'` *(peças não existem no registry hoje)*
```
acessar o componente → câmera contextual
→ localizar os conectores → desconectar cabos/plugs (arrastar para longe do conector)
→ remover fixações (pontos 'bolt' curtos, se houver)
→ retirar o componente → COMPLETE
```

**BANCO** — `minigame = 'bolt'` ou `'mechanical'` *(futuro)*
```
abrir/acessar o interior → câmera no trilho do banco
→ localizar os parafusos dos trilhos → soltar cada fixação
→ banco liberado → COMPLETE
```

**CATALISADOR / ESCAPAMENTO** — `minigame = 'cut'` *(futuro)*
```
gate: veículo levantado (raised — já é gate de tyre/carcass)
→ jogador entra na área inferior → CÂMERA UNDERBODY (novo enquadramento)
→ localizar os pontos corretos no escapamento
→ cortar / desparafusar os suportes → componente liberado → COMPLETE
```

### 1.1.2 Providers multi-etapa e multi-ponto

Cada provider **deve** conseguir ter **múltiplas etapas** e **múltiplos interaction points**.
O `bolt` já é multi-ponto (conjunto, ordem livre). O `mechanical` é multi-etapa (lista
ordenada, tipos diferentes por etapa). O `cut` é multi-linha. O `wiring` é multi-conector.

**Modelo interno do provider** (sem tocar o schema do registry):

```lua
-- dentro do provider, derivado de partDef — NÃO é um campo novo do registry ainda
steps = {
  { type = 'bolt',       points = {...}, needed = ... },
  { type = 'bolt',       points = {...} },
  { type = 'disconnect', points = {...}, pull = ... },
  { type = 'disconnect', points = {...} },
  { type = 'release',    points = {...} },
}
```

O provider percorre `steps` em ordem; etapa `k+1` só habilita após `k` concluída; HUD "k/N";
cancelar/timeout em qualquer etapa → `'cancel'` (o servidor não commitou nada — não há peça
"meio removida" no estado server).

### 1.1.3 Exemplo de schema declarativo — **FUTURO, requer RFC**

Conceitualmente o ideal seria o registry declarar as etapas:

```lua
part.action = {
  minigame = 'mechanical',
  steps = { 'bolt', 'bolt', 'disconnect', 'disconnect', 'release' },
}
```

**NÃO alterar o schema agora.** `shared/registry/*` é schema v2 **CONGELADO** — qualquer campo
novo reabre a review adversarial. Isto entra só via **RFC própria** (`docs/design/PART_REGISTRY_STEPS_RFC.md`,
a criar) com:
- análise de compatibilidade (projeção `projectChopParts`, drift check, os 566 asserts);
- decisão se `steps` vive no registry ou num arquivo de layout separado (`shared/registry/dismantle_layout.lua`)
  que o provider consome — provável melhor opção, mantém o schema de peça intacto;
- migração das peças existentes sem mudar comportamento.

Até lá, os `steps` são **hardcoded dentro de cada provider**, derivados de `partDef.id` +
bones + `GetModelDimensions`.

### 1.1.4 Estados intermediários de peça — **FUTURO, client-side, NÃO-autoritativos**

Escada de apresentação que um provider multi-etapa exibe enquanto o jogador trabalha:

```text
ATTACHED → PARTIALLY_DISCONNECTED → DISCONNECTED → REMOVED
```

**Regras invioláveis:**
- Estes estados são **puramente de apresentação, no client**. Nunca vão para o `ChopSession`,
  nunca para o DB, nunca para o inventário.
- A **única** transição autoritativa continua sendo `nil → REMOVED`, feita pelo **servidor** no
  `ActionSession.Complete` após `revalidate()`. O servidor não conhece `PARTIALLY_DISCONNECTED`.
- Se o jogador cancela/desconecta no meio: o client descarta a escada; no servidor **nada mudou**
  (a peça nunca saiu de `AVAILABLE`). Não existe "peça 60% removida" que dê 60% de reward ou
  meio-item. É tudo-ou-nada no COMPLETE.
- `Wheels V2` (§5) já segue isso: no servidor `LOCKED` é efêmero e não-committed (libera sozinho);
  só `REMOVED`/`STORED` são verdade. `REMOVING` e os subestados **nem existem no servidor** —
  são view do client. A escada `ATTACHED→...` é o mesmo princípio aplicado **dentro de uma única
  ActionSession multi-etapa**, inteiramente no client.
- Threat: se algum dia um estado intermediário precisar sobreviver a disconnect (ex.: "porta
  fica pendurada por um fio"), isso vira **estado autoritativo do servidor** com a mesma
  disciplina do `REMOVED` (idempotência, sweep, fail-closed) — e entra por RFC, não por
  conveniência de UX.

---

## 2. Fluxo conceitual (inalterado)

```text
ChopSession  (veículo já roubado, RAISED/DISMANTLING)
      │
      ▼
ActionSession START            ← client manda SÓ { sessionId, action }
      │                          servidor deriva netId/model/vsid/tool/distância/estado
      │                          spec.validate(v) roda AQUI (start)
      ▼
minigame / interação física client-side   ← provider resolvido por Registry.action.minigame
      │
      ├── success  → client pede ActionSession COMPLETE
      ├── cancel   → client pede ActionSession CANCEL
      └── fallback → client roda lib.skillCheck; pass → COMPLETE, fail → CANCEL
      │
      ▼
ActionSession COMPLETE / CANCEL
      │
      ▼
revalidate(act)  ← servidor REFAZ: session · veículo · distância · ferramenta ·
      │             peça · estado · ownership/action-state · minDurationMs decorrido
      ▼
mudança física da peça   (ChopSession.MarkPartRemoved → state)
      │
      ▼
reward / XP / heat / vp_gangs   (RewardResolver + hooks — SÓ aqui, SÓ server)
```

**Regra central, repetida:** entre "success" do minigame e "commit" há sempre um
`revalidate()` server-side. O `bool` do client é uma **sugestão**, não um fato.

---

## 3. Contrato do provider de minigame

### 3.1 Assinatura

```lua
-- bridge/minigames.lua  (client)
---@param partDef PartDefinition        -- Registry.get(partId): rico, já validado
---@param ctx     MinigameContext
---@return 'success' | 'cancel' | 'fallback'
function VPChopMinigames.run(partDef, ctx)
```

Escolha de retorno **string de 3 estados** em vez de `bool`:
- `'success'` — jogador completou a interação.
- `'cancel'` — jogador cancelou (ESC/BACKSPACE) ou timeout.
- `'fallback'` — o provider não conseguiu rodar (geometria/câmera inválida, bone ausente,
  native indisponível). O **caller** decide o que fazer (hoje: `lib.skillCheck`).

`bool` não distingue "cancelou" de "não deu pra rodar" — e essa diferença muda a UX e a telemetria.

### 3.2 `MinigameContext`

```lua
---@class MinigameContext
---@field vehicle   integer     -- handle local (client resolve do netId que o server confirmou)
---@field netId     integer
---@field partId    string       -- redundante com partDef.id, conveniência
---@field actionId  string|integer  -- id do ActionSession aberto (para telemetria/log)
---@field wheelId?  'lf'|'rf'|'lr'|'rr'  -- só quando kind == tyre/wheel
---@field toolClass? 'cut'|'screw'|nil   -- espelha partDef.toolClass (UX: ícone/anim)
---@field config    table        -- Config.InteractiveDismantling resolvido + overrides do partDef
```

O provider **não** recebe `src`, não fala com o servidor, não conhece reward. Só desenha e lê input.

### 3.3 Resolução provider ← `Registry.action.minigame`

`shared/registry/parts.lua` já declara (schema v2 congelado):

```lua
---@field minigame 'bolt'|'cut'|'wiring'|'mechanical'|'skillcheck'|nil  -- UX (client)
```

Valores **reais** no `shared/registry/parts.lua` do HEAD da branch (conferido — **não** há peça
com `minigame = nil`; toda entrada já declara intenção):

| partId | `category` | `action.kind` | `action.minigame` | `toolClass` | `requires` | `gates` |
|---|---|---|---|---|---|---|
| `wheel_lf` `wheel_rf` `wheel_lr` `wheel_rr` | `wheel` | `tyre` | **`bolt`** | `cut` | — | `raised` |
| `bonnet` | `door` | `adv_door` | **`cut`** | `cut` | — | — |
| `boot` | `door` | `adv_door` | **`cut`** | `cut` | — | — |
| `door_dside_f` `door_pside_f` `door_dside_r` `door_pside_r` | `door` | `adv_door` | **`cut`** | `cut` | — | — |
| `adv_engine` | `engine` | `adv_engine` | **`mechanical`** | `screw` | `bonnet` REMOVED | — |
| `adv_carcass` | `panel` | `adv_carcass` | **`cut`** | *`nil`* (carcass não checa serra hoje) | `adv_engine` REMOVED | `welder` |

Notas factuais do registry atual (não mudar nada disto — é o estado congelado):
- Não existe "porta GTA nativa" separada: `bonnet`/`boot`/as 4 portas passam todas pelo helper
  `bodyDoor(...)` → `kind = 'adv_door'`, `minigame = 'cut'`, `toolClass = 'cut'`.
- **Rodas usam `toolClass = 'cut'`** (não `screw`) e `minigame = 'bolt'`. `gates.raised = true`.
- `adv_carcass` tem `toolClass = nil` — o `minigame = 'cut'` é só UX; o gate real é o `welder`.
- `PartRequire.state` hoje só aceita `'REMOVED'` (o próprio schema anota `-- futuro: 'OPEN'|'DISCONNECTED'`).
- `minigame` **não é `nil` em nenhuma peça** → a linha `nil → skillcheck` do mapa abaixo é
  só o comportamento defensivo para uma peça futura que esqueça o campo.

Mapa **declarativo** provider:

```text
Registry.action.minigame → provider
─────────────────────────────────────
'bolt'        → providers/bolt.lua        (WHEEL BOLT — generaliza runBoltSurface)
'cut'         → providers/cut.lua         (linha de corte: porta/capô/mala/carcaça)
'mechanical'  → providers/mechanical.lua  (sequência de pontos mecânicos: motor)
'wiring'      → providers/wiring.lua      (puxar plugs: bateria/ECU/rádio — futuro)
'skillcheck'  → providers/skillcheck.lua  (lib.skillCheck puro)
nil           → providers/skillcheck.lua  (default seguro) OU sem minigame (config)
```

- **Nenhuma lógica de peça no provider.** O provider recebe `partDef` e só lê o que precisa
  para desenhar (bones, layout, sentido). Regras (ferramenta, gates, ordem) já foram checadas
  pelo `ActionSession.startCore` **antes** do minigame abrir.
- Provider desconhecido / `minigame` inválido → `'fallback'` + log. Nunca trava.

### 3.4 Onde mora

`bridge/minigames.lua` (fachada) + `bridge/minigames/providers/*.lua`. Auditar no início da P2.2
se `bridge/` é o lugar certo ou se cria `client/dismantle/`. O **caller** (o handler que abriu o
`ActionSession`) só chama `VPChopMinigames.run(partDef, ctx)` e reage aos 3 estados —
**não conhece provider nem implementação**.

---

## 4. Providers

Parâmetros numéricos (sensibilidade, voltas, tolerância, tempo, nº de pontos) **não são fixados
aqui** — vão para `Config.InteractiveDismantling` com defaults calibrados in-game na P2.2.

Todos os providers são **multi-ponto e multi-etapa** por construção (ver §1.1.2). Os `steps`
de cada peça são hardcoded no provider até a RFC de `steps` declarativos (§1.1.3). O objetivo
de UX de cada um é o procedimento-alvo em §1.1.1 — não um skillCheck repintado.

### 4.1 WHEEL BOLT (`bolt`)

Generaliza `runBoltSurface` + `VPChopBoltMinigame`.

- Parafusos **fisicamente posicionados no wheel bone**:
  `boneId = GetEntityBoneIndexByName(veh, 'wheel_lf'|...)` (cacheado 1×),
  `wheelPos = GetWorldPositionOfEntityBone(veh, boneId)`.
- **N parafusos em círculo:** `angle = 2π/N * i`, `p = wheelPos + up*(cos·r) + fwd*(sin·r) + sideDir*outOff`.
  `sideDir` **derivado** do veículo (`GetEntityForwardVector` → vetor lateral) e do lado do bone
  — nunca hardcoded.
- **Câmera contextual:** scripted cam a ~1.6 m do lado da roda, `PointCamAtCoord(wheelPos)`.
- **Cursor / raycast:** projeção `GetScreenCoordFromWorldCoord` de cada ponto não-concluído →
  distância ao cursor → hover (raio `hoverR`). (Estratégia **B**, ver research §5.)
- **Outline:** se o modelo do parafuso carregou, spawna a entidade **attachada ao bone**
  (`AttachEntityToEntity`, conceito filo_bolt) e usa `SetEntityDrawOutline`. Sem modelo → `DrawMarker`
  vermelho→verde por progresso, opacidade maior sob o cursor.
- **Interação de rotação:** segurando LMB sobre um parafuso, `deg += moveCursor * sens`
  (clamp por frame contra salto). `needed = turns * 360`. **Exige movimento real** — não é clique.
  Opcional (config): `oneAtATime` (um por vez) e sentido alternado aperta/afrouxa.
- **Parafuso avançando para fora:** durante o giro, leve translação no eixo de saída
  (conceito filo_bolt: recuo na rosca).
- **Queda física opcional:** ao concluir, se há entidade: `FreezeEntityPosition(false)`,
  `SetEntityCollision(true)`, `SetEntityVelocity(outward*k, ..., rand)`. Config: `dropBolts`.
- **Cleanup garantido:** ver §6.
- **Fallback sem asset:** obrigatório e já é o comportamento — modo marcador. `'fallback'`
  **só** quando nada projeta > 2.5 s (câmera/geometria) ou native ausente.

### 4.2 CUT (`cut`) — portas, capô, porta-malas, carcaça

- **Pontos/linhas de corte** derivados de bones + `GetModelDimensions`:
  - porta: dobradiça (`door_dside_f`/`door_pside_f`...) → batente;
  - capô: `bonnet` bone → dois cantos frontais;
  - mala: `boot` bone → dois cantos traseiros;
  - carcaça: sequência de 3–4 linhas ao longo do chassi.
- **Ferramenta:** `partDef.toolClass == 'cut'` → o `ActionSession` já exigiu a serra no start;
  o provider só mostra o ícone/anim de serra (`mini@repair` ou `anim@amb@...@welder`).
- **Progressão pela interação, não barra:** o jogador **arrasta o cursor ao longo da linha**
  (do ponto A ao B). Progresso = fração da linha coberta, com **tolerância de desvio**
  (`maxOffLine`) — sair muito da linha pausa o progresso e dá feedback (faísca vermelha / som de trava).
- **Partículas/som:** `ptfx` de faísca (`core` / `scr_...`) no ponto atual do corte; som de
  serra em loop enquanto arrasta; "clunk" ao concluir cada linha.
- **Multi-linha:** carcaça/porta podem ter 2+ linhas sequenciais; a próxima só habilita após a anterior.
- **Variante "ponto de calor" (a avaliar na P2.2, ver research §4.8):** em vez de arrastar uma
  linha, para PORTA/CAPÔ/MALA o corte pode ser **N pontos de dobradiça** — segurar o maçarico
  no ponto (`hold` + mira estável) até derreter; tirar o cursor do ponto **esfria** (perde
  progresso). É interação, não timer. `cut` suporta os dois modos por `step.type` (`'cut_line'`
  / `'cut_point'`); decidir qual usar por peça na calibração.
- Fallback: `lib.skillCheck` (já é o caminho de `adv_door`/`adv_carcass` hoje).

### 4.3 MECHANICAL (`mechanical`) — motor

- **Sequência de pontos mecânicos** ao redor do bloco do motor (bones `engine` / offsets do
  `bonnet` bounding): coxins, mangueiras, chicote, parafusos de cabeçote.
- Cada ponto é um micro-"girar" (rotação acumulada curta) ou "puxar" (wiring-like).
- **Etapas dependentes:** ponto `k+1` só habilita após `k` concluído — HUD mostra "3/6".
  Isto casa com `requires = { { part = 'bonnet', state = 'REMOVED' } }` que o `ActionSession`
  já exige antes de abrir (`hood_first`).
- **Suporte a etapas dependentes** é a diferença central vs. `bolt`: `bolt` é um conjunto
  (qualquer ordem), `mechanical` é uma lista ordenada.
- Ferramenta: `toolClass == 'screw'` (já exigido). Anim de chave de catraca.
- Fallback: `lib.skillCheck` com mais estágios (`{'medium','medium','hard'}`).

### 4.4 WIRING (`wiring`) — futura elétrica (bateria, ECU, rádio, plugs)

- **Desconexão de plugs/cabos:** cada conector é um ponto; o jogador clica e **arrasta o cursor
  para longe** do ponto ao longo do vetor de saída do conector; solta ao passar `pullThreshold`.
- Cabo/plug cai (física) ou some com ptfx de faísca elétrica curta.
- Ordem opcional (ex.: negativo antes de positivo na bateria — RP flavor, config).
- **Nenhuma peça `wiring` existe no registry runtime hoje** — o provider entra "dormindo",
  exercitado só por teste, até a Fase 4 (`vehicle_security`) ou uma peça física elétrica.
- Fallback: `lib.skillCheck`.

---

## 5. Wheels V2 — máquina de estados

### 5.1 Dois planos: estado do servidor × view do client

**A máquina de estados AUTORITATIVA do servidor tem 5 estados — `REMOVING` não é um deles:**

```text
SERVER (autoritativo, ChopSession / entitlement / storage)
  AVAILABLE ──► LOCKED ──► REMOVED ──► CARRIED ──► STORED
      ▲           │
      └───────────┘   (Cancel / disconnect / timeout / restart → volta a AVAILABLE)

CLIENT VIEW (só apresentação, durante LOCKED)
  o provider representa "REMOVING" e seus subestados
  (ATTACHED → PARTIALLY_DISCONNECTED → DISCONNECTED → ...) — §1.1.4
```

O servidor sabe apenas: **existe uma `ActionSession`/lock aberto para esta roda por este `src`**
(estado `LOCKED`). O client sabe: **visualmente estou removendo a peça** (`REMOVING` + subestados).
`REMOVING` **não** é promovido a estado server-authoritative nesta fase. Só via RFC futura, se
surgir necessidade real de persistir "removendo" através de um disconnect.

| Estado (server) | Significado | Dono | Persistência |
|---|---|---|---|
| `AVAILABLE` | roda presente, nenhum lock | **servidor** (sem entrada em `ChopSession.parts[wheelKey]` e sem lock) | in-memory |
| `LOCKED` | `ActionSession` aberto para esta roda por um `src` (o minigame está rodando no client dele — ou não; o servidor não distingue) | **servidor** | in-memory (`ChopSession` lock) |
| `REMOVED` | `ActionSession.Complete` revalidou → roda saiu | **servidor** (`ChopSession.MarkPartRemoved` → `state='REMOVED'`) | in-memory + tombstone |
| `CARRIED` | jogador carregando o prop da roda | **servidor** (`TyreEntitlement` — seam já existe) | in-memory (entitlement) |
| `STORED` | roda depositada (truck/stash) | **servidor** (`TruckStorage`/`PartStorage`) | **DB** |

| View (client, durante `LOCKED`) | O que é |
|---|---|
| `REMOVING` | rótulo genérico: o provider está ativo |
| `ATTACHED` / `PARTIALLY_DISCONNECTED` / `DISCONNECTED` | subestados de apresentação de um provider multi-etapa (§1.1.4) — **nunca** saem do client |

### 5.2 Transições

| Transição | Gatilho | Autoridade | Client faz |
|---|---|---|---|
| `AVAILABLE→LOCKED` | `ActionSession.StartBaseTyre(src, sessionId, wheelKey)` | **servidor** — `startCore` valida distância/ferramenta/estado/`isPartMissing`; grava lock | recebe `ok`, abre o provider (view entra em `REMOVING`) |
| `LOCKED→AVAILABLE` | provider retornou `'cancel'` ou `'fallback'`+fail → `ActionSession.Cancel` | **servidor** — libera o lock | notifica, restaura câmera; view volta a nada |
| `LOCKED→REMOVED` | provider retornou `'success'` → `ActionSession.Complete` | **servidor** — `revalidate` (session/veh/dist/tool/part/state/**minDurationMs**) → `MarkPartRemoved` | esconde a roda visualmente, toca som; view encerra |
| `LOCKED→AVAILABLE` | disconnect / timeout / resource-restart **antes** do `Complete` | **servidor** — `ActionSession.CleanupPlayer` / `ChopSession` sweep libera o lock | — |
| `REMOVED→CARRIED` | jogador pega o prop | **servidor** — `TyreEntitlement.grant(src, ...)` | anim carry + prop attach |
| `CARRIED→STORED` | depósito | **servidor** — grava no storage (DB) | anim, feedback |
| `CARRIED→AVAILABLE`? | **não existe** — roda removida não "volta" | — | — |

Dentro de `LOCKED`, o client transita livremente `REMOVING`↔subestados sem falar com o servidor.
Nenhuma dessas transições de view é reportada frame-a-frame nem persiste.

**Invariante herdado:** "tempo sozinho nunca destrói committed state". `LOCKED` é efêmero e
libera sozinho (o lock some com o `src` ou com o restart); `REMOVED`/`STORED` são committed e só
mudam por ação explícita.

**Hoje** o `ChopSession` tem só `{nil, 'REMOVED'}`. A V2 acrescenta **`LOCKED`** como estado
autoritativo (formaliza o lock de `ActionSession` que já existe conceitualmente). `REMOVING` e
seus subestados **ficam no client** — não entram no `ChopSession`. `CARRIED`/`STORED` já são
território de `TyreEntitlement`/`TruckStorage`.

### 5.3 Anti-race (já coberto, confirmar na P2.2)

- 2 jogadores na mesma roda: o 2º `StartBaseTyre` bate em lock/`isPartMissing` → erro `part`/`busy`.
  (`LockPart`/`PinPartLock`/`OpenBySrc` já existem.)
- `REMOVED` é idempotente (`MarkPartRemoved` já trata re-entrada).

---

## 6. Lifecycle START / SUCCESS / CANCEL / FALLBACK + cleanup

### 6.1 Estados do provider

```text
idle
 └─► starting   (resolve bones, carrega modelo c/ timeout, cria câmera, textUI, anim)
      └─► active (loop único: cursor, hover, giro/arrasto, marcador/outline, timeout)
           ├─► success    → cleanup → return 'success'
           ├─► cancelled  → cleanup → return 'cancel'
           ├─► failed      (geometria/câmera > 2.5s, native ausente) → cleanup → return 'fallback'
           └─► (pcall pegou erro) → cleanup → return 'fallback'
```

### 6.2 Cleanup — **em todos os caminhos**

Um `cleanup()` idempotente, chamado dentro e fora do `pcall` do loop (padrão já usado no
`runBoltSurface`). Cobre: sucesso, falha, cancelamento, timeout, entidade sumiu, veículo inválido,
`onResourceStop`.

Restaura sempre:
- câmera → `RenderScriptCams(false, true, t, true, true)` + `DestroyCam`;
- ped → `ClearPedTasks`, `ResetEntityAlpha`, `FreezeEntityPosition(false)`, `SetEntityCollision(true)`;
- controles → fim do `DisableControlAction`/`DisablePlayerFiring` (o loop parou);
- cursor → `lib.hideTextUI()`, para de chamar `SetMouseCursorActiveThisFrame`;
- outline → `SetEntityDrawOutline(ent, false)` antes de deletar;
- objetos temporários → `DeleteEntity` de cada parafuso/plug spawnado;
- ptfx → `StopParticleFxLooped` de qualquer handle de faísca/serra.

`onResourceStop(GetCurrentResourceName())` → varre a lista de entidades spawnadas pela sessão
ativa (se houver) e deleta. **Nenhuma entidade órfã, em nenhum caminho.**

Registro de entidades: a sessão mantém `spawned = {}` local; nunca um global acumulador
(o bug do `spawnedBolts` global do filo_bolt).

---

## 7. Threat model

| # | Vetor | Impacto se ignorado | Mitigação (arquitetura VP) |
|---|---|---|---|
| T1 | `stop`/`replace` do resource de minigame; export sempre `'success'` | pular a UX | servidor exige `minDurationMs` decorrido + todas as gates no `revalidate`; UX pulada ≠ peça grátis |
| T2 | Hook no retorno de `VPChopMinigames.run` | idem T1 | idem — `bool`/string do client nunca credita |
| T3 | Editar `Config.InteractiveDismantling` local (voltas=0, timeout=∞) | minigame trivial | é só UX; servidor não lê esse config; `minDurationMs` é server-side (`Config.ActionSession.MinDurationMs`, não o do minigame) |
| T4 | `ActionSession.Complete` chamado **sem** abrir minigame | remover peça sem interação | `Complete` exige um `actionId` de um `Start` que passou `startCore`; `revalidate` refaz tudo; `minDurationMs` desde o `Start` |
| T5 | `Complete` spam / replay | dupe de peça/reward | `MarkPartRemoved` idempotente; `ActionSession` consome o `actionId`; estado `REMOVED` barra o 2º |
| T6 | 2 players, mesma peça, corrida no COMPLETE | dupe | lock de peça + `isPartMissing` + `REMOVED` idempotente |
| T7 | `Cancel` após `success` para "soltar o lock" e refazer | farm | `Complete` já commitou `REMOVED`; `Cancel` em ação terminal é no-op |
| T8 | netId de veículo reciclado pós-restart | agir sobre carro errado | `vsid` (identidade real) + sweeps já existentes; `ChopSession` não confia em netId como identidade |
| T9 | Distância: abrir minigame perto, concluir longe | peça remota | `revalidate` checa `spec.distance` **de novo** no COMPLETE |
| T10 | Ferramenta: largar a serra durante o minigame | peça sem ferramenta | `revalidate` re-checa `toolClass` no COMPLETE (`VPChopHasTool`) |
| T11 | Ptfx/entidade órfã por erro no meio | leak visual/perf | `cleanup()` idempotente + `pcall` + `onResourceStop` sweep |
| T12 | `fallback` forçado (quebrar geometria de propósito) para cair no skillCheck fácil | trocar minigame difícil por skillCheck | skillCheck do fallback usa dificuldade ≥ à do minigame; e ainda passa por `revalidate` |

**Resumo:** o pior caso de um minigame 100% comprometido é o jogador **pular a apresentação**.
Ele ainda não recebe peça, item, reward, XP nem dispara heat/gangs sem o servidor revalidar
session + veículo + distância + ferramenta + peça + estado + tempo mínimo.

---

## 8. Performance budget

| Momento | Alvo | Como |
|---|---|---|
| Minigame **inativo** | **0.00 ms** | nenhuma thread; providers são funções chamadas sob demanda |
| `starting` | pico < 5 ms, uma vez | `RequestModel` timeout 1500 ms; `GetEntityBoneIndexByName` cacheado |
| `active` (por frame) | **< 0.10 ms** client | 1 thread `Wait(0)`; ≤ 8 pontos projetados; pula `done`; sem shape-test |
| Entidades | ≤ N parafusos/plugs **temporários**, deletados no cleanup | `spawned={}` local |
| Câmeras | **1** por sessão | `CreateCamWithParams` → `DestroyCam` no cleanup |
| Ptfx | ≤ 1 loop ativo (faísca/serra), parado no cleanup | `StartParticleFxLoopedAtCoord` + `StopParticleFxLooped` |
| Servidor | O(1) por `Start`/`Complete` | sem varredura; lock em tabela |
| Rede | 2 eventos por peça (`Start`, `Complete`/`Cancel`), payload `{sessionId, action}` / `{actionId}` | sem stream de progresso |

**Proibido:** thread global, loop de reposicionamento se o attach ao bone resolver, shape-test
por frame, mandar progresso do minigame para o servidor frame a frame.

---

## 9. Plano de testes

### 9.1 Harness estático (`tools/run_spec.lua` — roda fora do FiveM)

O minigame em si é client/visual e **não** é coberto pelo harness. O que **é** testável e
**precisa** de spec nova:

| Suite | Asserts |
|---|---|
| `minigame_registry_spec` | `Registry.action.minigame` de cada peça mapeia para um provider conhecido; `nil` → default; valor inválido → resolve para `skillcheck`+log, nunca erro |
| `action_session_spec` (estender) | `Complete` sem `Start` → erro; `Complete` após `minDurationMs` não decorrido → erro; `revalidate` re-checa distância/ferramenta; `Cancel` em ação terminal → no-op |
| `chop_session_spec` (estender) | `AVAILABLE→LOCKED→REMOVED` idempotência; lock libera em `CleanupPlayer`; 2º ator na peça travada → erro `part`/`busy` |
| `wheels_v2_spec` (nova) | máquina de estados server-side (5 estados, sem `REMOVING`): transições válidas/inválidas; `REMOVED`/`STORED` sobrevivem a "tempo sozinho"; `LOCKED` não (libera em `CleanupPlayer`/restart) |
| `reward_gate_spec` | nenhum caminho de `RewardResolver` é alcançável sem `revalidate` ter retornado sucesso |

Meta: manter **0 regressão** no total atual (566) e somar as novas.

### 9.2 QA in-game (novo bloco no `V116_INTEGRATION_QA.md`, ou doc próprio Q6)

- Q6.1 — roda: 4 rodas, 4 veículos diferentes (sedan/SUV/desportivo/pickup), parafusos projetam,
  giro por movimento real conclui, sem asset custom (modo marcador) funciona.
- Q6.2 — câmera propositalmente ruim (veículo contra parede) → degrada para skillCheck em ≤ 3 s,
  **não** trava.
- Q6.3 — `cut` porta/capô/mala/carcaça: linha visível, arrastar conclui, sair da linha pausa.
- Q6.4 — `mechanical` motor: exige `bonnet REMOVED` antes; sequência ordenada; HUD "k/N".
- Q6.5 — cancelar em cada provider (ESC/BACKSPACE/timeout) → câmera/ped/cursor/controles restaurados,
  **zero entidade órfã** (`GetGamePool('CObject')` antes/depois).
- Q6.6 — `ensure vp_chopshop` no meio de um minigame → sem crash, sem prop preso, sem câmera travada.
- Q6.7 — 2 jogadores mesma roda → o 2º recebe erro, não abre minigame.
- Q6.8 — largar a serra durante o `cut` → COMPLETE nega (`revalidate` → `no_saw`).
- Q6.9 — resmon do `vp_chopshop` durante minigame ativo < 0.10 ms; inativo = 0.00 ms.
- Q6.10 — economia: concluir desmanche completo com minigames == mesmo payout que a barra passiva
  dava (o minigame não muda reward).

---

## 10. Futuras peças físicas (NÃO adicionar ao registry agora)

Quando a Fase 3/4 destravar, estas peças entram como entradas novas no registry (schema v2 já
suporta: `bones`, `toolClass`, `requires`, `gates`, `carry`, `action.minigame`, `rewardProfile`):

| Peça | `minigame` provável | `requires` provável | Notas |
|---|---|---|---|
| `battery` | `wiring` | bonnet REMOVED | negativo→positivo; leve, `carry` |
| `ecu` | `wiring` | — / bonnet REMOVED | high value, provenance forte |
| `alternator` | `mechanical` | bonnet REMOVED, correia | 2–3 pontos |
| `radio` | `wiring` | — | rápido, low value |
| `front_seats` | `bolt` ou `mechanical` | doors REMOVED (opcional) | 4 parafusos por assento |
| `catalytic_converter` | `cut` | raised | 2 cortes no escapamento; heat alto |
| `exhaust` | `cut` | raised | linha longa; low value, `carry` |

Cada uma vira **um PR próprio**, com rewardProfile, provenance, specs de parity — fora do escopo
deste design. Aqui só se registra que a arquitetura comporta.

---

## 11. Roadmap de PRs (TODAS bloqueadas pelo gate Q1–Q4)

> Ordem, base `pr-h`, uma mudança lógica por PR, harness verde, OmniRoute challenge conferido,
> **GO explícito do dono por PR**, PARAR após abrir. Nada começa antes de Q1–Q4 fecharem sem P0/P1.

| PR | Escopo | Runtime? | Depende de |
|---|---|---|---|
| **ID-0** | *(este design + research + brief — já feito, doc-only)* | não | — |
| **ID-1** | `bridge/minigames.lua` fachada + `providers/skillcheck.lua` + `minigame_registry_spec`. Mapa `Registry.action.minigame → provider`, resolução + fallback. **Nenhum caller ligado ainda** (inerte). | client, inerte | Q1–Q4 |
| **ID-2** | **Wheels V2 — domínio/estado server-side.** `LOCKED` formalizado como estado autoritativo no `ChopSession`/`ActionSession` (o lock de ação); `wheels_v2_spec` (transições válidas/inválidas, `LOCKED` libera em `CleanupPlayer`/restart, `REMOVED`/`STORED` sobrevivem a "tempo sozinho", anti-race 2 atores). **Sem mudança de UX, sem provider.** `REMOVING` **não** entra no servidor. | server | ID-1 |
| **ID-3** | **Bolt provider + integração da roda.** `providers/bolt.lua` extrai `runBoltSurface`/`VPChopBoltMinigame` sem mudar comportamento; specs de projeção onde testável; o caller da RODA passa a: `StartBaseTyre` → `VPChopMinigames.run` → `Complete`/`Cancel`. Liga a nova apresentação ao domínio já formalizado em ID-2. | client | ID-2 |
| **ID-4** | `providers/cut.lua` — linha de corte, ptfx/som, multi-linha. Callers `adv_door` (inclui `bonnet`/`boot`/as 4 portas) e `adv_carcass` migram de `lib.skillCheck` para o provider (fallback mantido). | client | ID-3 |
| **ID-5** | `providers/mechanical.lua` — sequência ordenada de pontos. Caller `adv_engine`. HUD "k/N". | client | ID-4 (compartilha helpers de ponto) |
| **ID-6** | `providers/wiring.lua` — puxar plugs. Entra **dormente** (nenhuma peça usa ainda); exercitado só por spec + `Config.Debug` target. | client | ID-1 |
| **ID-7** | `Config.InteractiveDismantling` consolidado + calibração dos defaults (voltas, sens, tolerância, timeouts, nº de pontos) a partir da QA in-game. Remove `Config.Jackstand.Minigame`/`Config.Plates.Bolt3D` legados se cobertos. | config | ID-3..ID-6 |
| **ID-8** | Bloco Q6 no plano de QA in-game + CI: adicionar as suites novas ao harness e (se a Fase 5 já tiver corrigido o exit code) ao gate de CI. | doc + tools | ID-3..ID-7 |

**Princípio da ordem (2026-08-29):** *formalizar domínio/estado antes de ligar a nova
apresentação ao gameplay.* Por isso **ID-2 (Wheels V2 server-side) vem antes de ID-3 (bolt
provider + integração)** — invertido em relação ao rascunho inicial. Razão: o provider de roda
só deve ser plugado quando o `ChopSession` já sabe representar `LOCKED` e o `wheels_v2_spec` já
trava as transições; caso contrário a integração da UX e a mudança de domínio entram no mesmo
PR e a review adversarial fica com dois alvos. Não há razão arquitetural para manter a ordem
antiga (o provider extraído do `runBoltSurface` não é pré-requisito da state machine — a state
machine é sobre lock/estado, não sobre desenho).

**PR fora da série ID (pré-requisito só se aprovado):** `PART_REGISTRY_STEPS_RFC` — RFC para
`steps` declarativos por peça (§1.1.3). Doc-only. Se aprovada, os providers passam a ler o
layout de `shared/registry/dismantle_layout.lua` (ou campo novo) em vez de hardcode. Sem ela,
ID-3..ID-6 seguem com `steps` hardcoded no provider — não bloqueia.

Peças físicas novas (`battery`, `ecu`, ...) são PRs da Fase 3/4, **depois** de ID-1..ID-8, cada
uma isolada.

---

## 12. Decisões em aberto para a P2.2 (não fechar agora)

1. `bridge/minigames.lua` vs. `client/dismantle/` — decidir na auditoria de abertura da ID-1.
2. Parâmetros numéricos de cada provider — calibração in-game (ID-7).
3. `cut`: partícula de faísca exata (asset base-game a escolher).
4. `mechanical`: usar `engine` bone (nem todo veículo tem) ou offsets do bounding do `bonnet`.
5. Modelo de parafuso opcional: escolher um prop base-game pequeno OU aceitar 1 `.ydr` livre
   (nunca `bolt_01.ydr` da referência). Ver `WHEEL_BOLT_MINIGAME.md` §9.
6. `oneAtATime` como default on/off.
7. Se `minigame == nil` numa peça deve significar "skillcheck" ou "sem minigame, barra passiva
   legada" — provavelmente config global `Config.InteractiveDismantling.DefaultForNil`.
8. `steps` declarativos: campo no schema da peça vs. arquivo de layout separado
   (`shared/registry/dismantle_layout.lua`). Preferência atual: layout separado, mantém o
   schema v2 da peça intacto. Decisão via `PART_REGISTRY_STEPS_RFC` (§1.1.3).
9. Estados intermediários (`ATTACHED→PARTIALLY_DISCONNECTED→DISCONNECTED→REMOVED`): confirmar
   que ficam 100% client-side; só promover a autoritativo via RFC se um caso real exigir
   persistir "peça meio-solta" através de disconnect (§1.1.4).
10. Câmera underbody (catalisador/escapamento) — enquadramento novo, precisa de teste de
    colisão de câmera dentro do volume do carro levantado.
