# RFC — Processamento / Descaracterização de Peças na Bancada

> **Status:** DESIGN / RFC — nenhuma linha de código nesta etapa.
> **Baseline:** branch `pr-h/v1.15-delivercar-terminal-hardening`, code freeze `99371e4`, stack `#2→#11`, harness `493 PASS`.
> **Pré-condição de implementação:** Release Candidate real FiveM/QBox validado (FASE 3–26 de `docs/audit/V115_RELEASE_CANDIDATE.md`). Enquanto o RC não passar, este documento não sai do estado RFC.
> **Escopo proibido nesta feature:** ownable chopshops, employees, workers automáticos, mercado dinâmico, leilões, boosting, MDT policial novo, salvage/refurbishment completos, contracts, Part Registry / Tool Registry globais.

---

## A. CURRENT STATE — como bancada / car_parts / serial funcionam hoje

### A.1 Bancada (`chopshop_bench`)

| Aspecto | Implementação atual |
|---|---|
| Prop | `Config.BenchModel = prop_tool_bench02` |
| Colocação / persistência | `vp_chopshop_benches` (DB). Comando admin insere linha; `server/db.lua:VPChopDbLoadBenches` carrega no boot para `ServerBenches` (array) + `ServerBenchesById` (mapa). Sobrevive a restart. |
| Entidade in-game | `client/bench.lua:VPChopUpsertBench` — `CreateObject` local + `ox_target:addLocalEntity`. Não é entidade de rede. |
| Soldadora | `vp_chopshop_welders` (DB) → `ServerWelders` / `ServerWeldersById`. `Config.WelderModel`, `Config.WelderBenchRadius = 8.0`. `server/main.lua:isWelderNearBench(bench)` = existe welder a ≤ raio do bench (verdade server-side). |
| Menu (ox_target) | recipes de `Config.BenchRecipes` + "forjar placa falsa" (se `Config.Plates.Enable`) + opções de série (`VPChopSerialBenchOptions`) + "pegar item" (`pickupBench`). Opções aparecem condicionalmente. |

### A.2 Crafting da bancada (`vp_chopshop:benchCraft`)

Fluxo atual (`server/main.lua:478` → `server/bench.lua:VPChopServerTryBenchRecipe`):

```
ServerPlayerIsReady
→ rate-limit 3s (_benchCraftRateLimit)
→ BenchCraftBusy[src] mutex
→ benchId = tonumber; benchById()
→ isWelderNearBench(bench)          ← HOJE: TODA recipe exige soldadora
→ recipeIndex = tonumber
→ VPChopServerTryBenchRecipe:
     ValidatePlayerNearCoords(src, bench.coords)
     conferir inputs (InvCount)
     remover inputs   (rollback atômico se falha parcial)
     adicionar outputs (rollback de inputs E outputs se falha)
→ VPChopDiscordLogBench
→ BenchCraftBusy[src] = nil
```

`Config.BenchRecipes[i] = { labelKey, duration, inputs = {item=count}, outputs = {item=count} }`.
Recipes existentes: `metalscrap→steel`, `metalscrap+plastic→copper`, `car_parts+metalscrap→repairkit`, `rubber+plastic→rope`.

**Limitações estruturais do craft atual:**
- Opera **só por nome+contagem de item**. Nenhuma noção de metadata, slot, estado, origem.
- Sem transação server-authoritative com sessão: é um único callback sem yield; a "duração" é só a `progressBar` do client (não revalidado no fim).
- Sem replay idempotente: perda de resposta após remover input = risco de re-clique (mitigado só por rate-limit 3s + mutex).
- Todas as recipes hoje exigem soldadora (`isWelderNearBench` incondicional).

### A.3 car_parts

**Não existe item de peça física individual** (engine / door / ecu / catalytic / …). Existe:

- `car_parts` — **commodity genérico**, `stack = true` no `ox_items`.
- `stolen_plate` — placa roubada (metadata `{plate}`).
- Materiais brutos: `metalscrap`, `steel`, `copper`, `plastic`, `glass`, `rubber`.

O desmanche (base tyre + advanced door/engine/carcass) entrega **`car_parts` diretamente no inventário** via `VPChopAddStolenCarParts(src, netId, count)`. `advanced_chop.lua`: porta = 1× `car_parts`, motor = 5×, carcaça = N×.

### A.4 Serial / metadata de car_parts (`server/partserial.lua`)

`car_parts` roubado carrega metadata `{ serial, state, sourceModel }`:

| Campo | Semântica |
|---|---|
| `serial` | string A-Z0-9, 10 chars. Identificador forense legível, **não** segredo. `nil` quando riscado. |
| `state` | `stolen` \| `scratched` \| `forged` \| `legal`. Peça legada sem metadata = tratada como `stolen`. |
| `sourceModel` | display name do modelo de origem (`GetDisplayNameFromVehicleModel`). **Nunca placa.** `nil` após forja. |

- **1 série por veículo** — cache `VehSerial[netId]`, limpo em `entityRemoved`. Todas as peças de um carro compartilham serial + sourceModel → empilham num stack só.
- **Riscar** (`vp_chopshop:serial:scratch`): `stolen`→`scratched`. Zera `serial`, mantém `sourceModel`. Gate: tier ≥ `ScratchTier` (2), proximidade de qualquer bench, cooldown. **Sem soldadora hoje.**
- **Forjar** (`vp_chopshop:serial:forge`): `stolen`/`scratched`→`forged`. Série falsa **nova**, `sourceModel = nil`, consome `ForgeInputs` (rollback atômico). Gate: tier ≥ `ForgeTier` (4), proximidade de bench, cooldown. Série forjada **não** entra em `vp_chop_legit_serials`.
- **Fonte legal** (`export IssueLegalParts` / vendedor `buyLegal`): gera série, **registra** em `vp_chop_legit_serials` (`serial` PK, `source`), entrega `car_parts` `state='legal'`, `sourceModel = nil`. Cap defensivo 100/emissão. Log de auditoria.
- **Perícia policial** (`vp_chopshop:inspectParts`): gate job policial + `parts_scanner` + proximidade ped-a-ped + cooldown. Lê `car_parts` do alvo (server é a verdade), agrupa por veredito. `classifyNormal`: `forged` → `forged_hidden` (aparece "Registrada" no scan comum). Com `forensic_kit`: cruza séries `legal`/`forged_hidden` em lote (`VPChopDbWhichSerialsLegit`) — não consta → **flagra forjada**. Nunca loga placa no MDT.

### A.5 ChopSession / ActionSession (primitivas reusáveis)

- **ChopSession** (`server/session/chop_session.lua`, in-memory): fonte server-authoritative do estado físico de desmanche de **um veículo**. API: `Create/Get/GetByVehicle/AddParticipant/HasParticipant/SetState/MarkRaised/GetPartState/GetPartOrigin/MarkPart/CountParts/LockPart/PinPartLock/UnlockPart/Complete/Cancel/ResolveBoundVehicleForCleanup`.
- **ActionSession** (`server/session/action_session.lua`, in-memory): autorização temporal + commit de **ação física sobre veículo levantado**. `START → OPEN → COMMITTING → COMPLETED`. Replay idempotente (zero side-effect). `PinPartLock` fail-closed no COMMITTING. `revalidate()` completo antes do commit. Erros `RECOVERABLE` → `CANCELLED` sem log. Domínio isolado em executor (`RegisterExecutor` / `RegisterKind`).
  **Acoplada a ChopSession**: exige `sessionId`, veículo `raised`, participante, `partKey ∈ ChopParts`. Não é reutilizável *as-is* para a bancada (sem veículo, sem ChopSession) — mas o **padrão** (START/COMPLETE/replay/pin/quarantine) é.
- **Quarantine / transaction_locked**: padrão PR-E (`server/logistics/…`) — quando a compensação de rollback falha, o recurso fica fail-closed marcado, sem 2ª tentativa econômica.

### A.6 Eventos internos

`shared/events.lua:VPChopEvt` = `PART_CHOPPED`, `CAR_DISCARDED`, `FENCE_DELIVERY`, `HEAT_CHANGED`. **Não existe `PART_PROCESSED`.**

### A.7 Integração com oficinas (hoje)

Nenhuma integração ativa. Só um *gancho de intenção*: recipe `bench_repairkit` (`car_parts` 5 + `metalscrap` 10 → `repairkit` 1) e `bench_rope`, comentados como "integração qs-mechanic-creator". `repairkit` é produzido mas o consumo é responsabilidade de outro resource.

---

## B. GAP — o que falta para a cadeia `peça → processamento → oficina`

| # | Gap | Detalhe |
|---|---|---|
| G1 | **Não existe "peça completa identificável"** | O desmanche já entrega `car_parts` (commodity) com metadata de série. Não há um tier físico anterior (`engine`, `door`, `ecu`…) que possa ser *processado*. A cadeia conceitual do prompt (`motor roubado → processar → car_parts`) não tem o elo "motor". |
| G2 | **Bench craft não entende metadata / slot / estado** | `VPChopServerTryBenchRecipe` opera por nome+contagem. Processar exige ler o slot exato, a metadata (`serial`, `state`, `partType`, `sourceModel`) e revalidar server-side. |
| G3 | **Não há estado `processed`** | Só `stolen/scratched/forged/legal`. "Descaracterizado fisicamente" ≠ nenhum dos quatro. Riscar mantém a peça; processar destrói a identidade. |
| G4 | **Bench craft não tem sessão transacional** | Sem START/COMPLETE, sem replay idempotente, sem pin/quarantine. Perda de resposta = risco de duplicação. |
| G5 | **`PART_PROCESSED` não existe** | Sem seam para evidence / heat / dispatch futuro / analytics. |
| G6 | **Contrato de commodity para oficina não é explícito** | `car_parts` sai do chop já "sujo" (state `stolen`). Uma oficina que consuma `car_parts` hoje consumiria peça roubada rastreável. Falta um estado/contrato "matéria-prima processada, sem identidade, mas não legal". |
| G7 | **Soldadora é tudo-ou-nada** | `isWelderNearBench` incondicional em todo craft. Processamento precisa de `requiresWelder` **por tipo de operação**. |
| G8 | **Perícia não classifica `processed`** | `classifyNormal` cairia em "estado desconhecido → stolen". Precisa de um veredito próprio: "componente processado — sem identificação original". |

---

## C. DOMAIN MODEL — estados e itens recomendados

### C.1 Item de entrada — recomendação: **Modelo A (`vehicle_part` genérico + metadata)**

| Modelo | Veredito |
|---|---|
| **A — `vehicle_part` genérico** | ✅ **RECOMENDADO.** 1 item novo em `ox_items`. Metadata carrega `partType`, `serial`, `state`, `sourceModel`, `sourceSession`. Coerente com o padrão já usado em `car_parts` (metadata rica) e `stolen_plate`. Expansão futura = nova entrada em `Config.PartProcessing`, zero item novo. |
| B — itens específicos (`stolen_engine`, …) | ❌ Explosão de `ox_items` + config + locale por tipo. UX marginalmente melhor não compensa. |
| C — evoluir `car_parts` | ❌ Geraria `car_parts → car_parts` sem significado físico e quebraria o contrato de commodity (o mesmo item seria ao mesmo tempo "peça inteira a processar" e "matéria-prima processada"). |

**`vehicle_part` — metadata (server-authoritative, nunca aceita do client):**

```lua
{
    partType    = 'engine',        -- 'engine'|'door'|'ecu'|'catalytic'|'transmission'|... (chave de Config.PartProcessing)
    serial      = 'ABC1234567',    -- compartilhado com as demais peças do mesmo veículo (mesma regra do car_parts)
    state       = 'stolen',        -- 'stolen'|'scratched'|'forged'  (nunca 'legal' saindo do chop; nunca 'processed' — processado deixa de ser vehicle_part)
    sourceModel = 'SULTANRS',      -- display name; NUNCA placa
    sourceSession = 'cs:1739',     -- id da ChopSession de origem (auditoria / anti-arbitragem)
}
```

`vehicle_part` **stack só com metadata idêntica** — na prática 1 stack por `(veículo, partType, state)`.

### C.2 Estado novo: **`processed`** em `car_parts`

`car_parts` produzido pelo processamento:

```lua
{
    state       = 'processed',
    serial      = nil,             -- identidade individual destruída
    sourceModel = nil,             -- procedência não mais carregada NO ITEM
    -- sem sourceSession — o lote perde rastro individual
}
```

- Empilha com outros `car_parts processed` → **commodity homogêneo** (o objetivo).
- **`processed` ≠ `legal`.** Nunca é registrado em `vp_chop_legit_serials`. Nunca chama `IssueLegalParts`.
- **`processed` ≠ `stolen`.** Não tem série nem modelo → a perícia não consegue amarrar a um veículo, mas classifica como "processado / sem identificação" (ver F).

### C.3 Tabela de estados consolidada

| Estado | Item | Série | Registrada em legit? | Scan normal | Perícia (forensic_kit) | Semântica |
|---|---|---|---|---|---|---|
| `legal` | car_parts | sim | **sim** | "Registrada" | "Legítima" | Procedência legal comprovada. |
| `forged` | car_parts / vehicle_part | falsa | não | "Registrada" (engana) | **"Série forjada (falsa)"** | Série falsa aplicada. |
| `scratched` | car_parts / vehicle_part | nil | — | "Série riscada (adulterada)" | idem | Série removida fisicamente. Suspeito. |
| `stolen` | car_parts / vehicle_part | real | não | "ROUBADA de um {modelo}" | idem | Procedência criminosa identificável. |
| **`processed`** | car_parts | nil | não | **"Componente processado — sem identificação"** | idem (não escala para "legal") | Peça desmontada/descaracterizada. Origem **não** presumida legal. |

---

## D. ARCHITECTURE — módulos e APIs

### D.1 Novos arquivos (ordem no fxmanifest)

```
shared/config.lua                       + bloco Config.PartProcessing (§K exemplo estrutural)
server/session/process_session.lua      NOVO — sessão transacional (D.3). Depois das bridges, ANTES de server/bench.lua.
server/session/process_session_spec.lua NOVO — self-gated (vp_chopshop_selftest 1)
server/part_processing.lua              NOVO — callbacks bench (start/complete/cancel/availability) + executor de domínio.
                                        Depois de partserial.lua (usa VPChopSerialGen, estados) e process_session.lua.
shared/events.lua                       + VPChopEvt.PART_PROCESS_STARTED / PART_PROCESSED / PART_PROCESS_FAILED
bridge/workshop.lua                     NOVO — adaptador OPCIONAL p/ scripts de oficina (§H.2.4).
                                        Carregado por ÚLTIMO no server_scripts. Só wiring, sem lógica.
                                        Degrada em silêncio se Config.Workshop.Enable=false ou alvo ausente.
```

Nenhuma alteração em `server/session/action_session.lua` nem `chop_session.lua`.

### D.2 `Config.PartProcessing` (separado de `Config.BenchRecipes`)

Não deformar `BenchRecipes` (§11 do prompt). Chave = `partType`. Estrutura (valores ilustrativos — balance em §I/§K):

```lua
Config.PartProcessing = {
    Enable = false,                       -- feature flag; nasce desligada
    RequireBenchProximity = true,
    Tier = 2,                             -- tier mínimo global para processar (sobrescrevível por tipo)
    Session = {
        StartRateLimitMs    = 500,
        CompleteRateLimitMs = 500,
        OpenTtlMs           = 45000,      -- < qualquer lock; sessão OPEN não pode durar mais que isso
        CommitMaxMs         = 60000,      -- backstop de COMMITTING travado (fail-closed, não libera)
        RetentionMs         = 120000,
    },
    Types = {
        engine    = { duration = 45000, requiresWelder = true,  tier = 3, output = { min = 6, max = 10 } },
        catalytic = { duration = 25000, requiresWelder = true,  tier = 2, output = { min = 3, max = 5  } },
        door      = { duration = 20000, requiresWelder = true,  tier = 2, output = { min = 1, max = 3  } },
        ecu       = { duration = 15000, requiresWelder = false, tier = 2, output = { min = 1, max = 2  } },
    },
    OutputItem = 'car_parts',             -- sempre commodity; NUNCA cash
}
```

### D.3 `ProcessSession` — API (espelha ActionSession, sem depender de veículo/ChopSession)

Motivo de **não** reusar `ActionSession` diretamente: ela exige `ChopSession` ACTIVE, veículo `raised`, participante e `partKey ∈ ChopParts`. O processamento acontece na bancada, sem veículo. Reusar forçaria stubs falsos de ChopSession. Uma sessão menor e dedicada é mais segura e testável.

**Invariants preservados de ActionSession:** autorização temporal · revalidação completa no COMPLETE · single-use · replay idempotente (zero side-effect) · sem double-processing · pin fail-closed no commit · erros recuperáveis → CANCELLED sem log.

```lua
ProcessSession.Start(src, payload)   -- payload do client = SÓ { benchId, slot }
  → resolve server-side: item do slot, metadata, partType, Config.PartProcessing.Types[partType],
    welder, distância, tier
  → LOCK triplo: player (1 sessão OPEN/COMMITTING por src) · bench · slotIdentity
  → { ok, processId, replay, startedAt, expiresAt } | { ok=false, err }

ProcessSession.Complete(src, processId)
  → replay: COMPLETED → devolve MESMO result, zero side-effect
  → COMMITTING → 'processing'
  → OPEN → rate-limit → TTL → minDuration (Types[t].duration) → revalidate() completo
  → pin da sessão → COMMITTING
  → executor de domínio (D.4) — único ponto que toca inventário
  → COMPLETED + unlock  |  FAILED/CANCELLED + unlock

ProcessSession.Cancel(src, processId)
ProcessSession.CleanupPlayer(src)      -- playerDropped: OPEN → CANCELLED; COMMITTING intocado
sweepOnce()                            -- event-driven, 1 thread leve global (não por sessão)
```

**Identidade de slot (`slotIdentity`)** — não confiar em `slot` puro:
`slotIdentity = hash(slot .. '|' .. item .. '|' .. serial .. '|' .. state .. '|' .. partType .. '|' .. count)`.
Revalidado no COMPLETE: se o jogador moveu/trocou o item, `slotIdentity` muda → `err = 'moved'` (RECOVERABLE → CANCELLED).

### D.4 Executor de domínio (isolado — não é God object)

```lua
-- server/part_processing.lua
local function processExecutor(sess)
    -- (revalidação já feita por ProcessSession.revalidate antes do COMMITTING)
    local t = Config.PartProcessing.Types[sess.partType]

    -- 1. CAPACIDADE ANTES DE REMOVER: cabe o output?
    local outCount = math.random(t.output.min, t.output.max)   -- server decide a quantidade
    if not InvCanCarry(sess.src, 'car_parts', outCount) then
        return { ok = false, err = 'inv_full' }                -- RECOVERABLE → CANCELLED, input intacto
    end

    -- 2. remover o vehicle_part EXATO (por slot + count 1)
    local removed = InvRemoveSlot(sess.src, sess.slot, 1)      -- captura metadata p/ restauração
    if not removed then return { ok = false, err = 'gone' } end

    -- 3. adicionar o output processado
    local added = exports.ox_inventory:AddItem(sess.src, 'car_parts', outCount,
        { state = 'processed', serial = nil, sourceModel = nil })
    if not (added ~= nil and added ~= false) then
        -- 4. RESTAURAÇÃO EXATA da metadata original
        local back = exports.ox_inventory:AddItem(sess.src, 'vehicle_part', 1, removed.metadata)
        if not (back ~= nil and back ~= false) then
            VPChopMarkProcessQuarantine(sess.src, removed)     -- transaction_locked: fail-closed, sem 2ª tentativa
            return { ok = false, err = 'quarantine' }
        end
        return { ok = false, err = 'inv_full' }
    end

    -- 5. commit terminal — evento UMA vez
    TriggerEvent(VPChopEvt.PART_PROCESSED, sess.src, {
        partType = sess.partType, sourceModel = removed.metadata.sourceModel,
        state = removed.metadata.state, output = outCount, benchId = sess.benchId,
    })
    VPChopDiscordLog('[PROCESS] peça processada', ...)
    return { ok = true, result = { output = outCount } }
end
```

### D.5 Bench UX (client)

`client/bench.lua:VPChopUpsertBench` — nova opção condicional, análoga a `VPChopSerialBenchOptions`:

```
"Processar peça"  (fa-solid fa-screwdriver-wrench)
  canInteract: fora de veículo + callback availability (server) confirma que há vehicle_part elegível
  onSelect:
    - lista os vehicle_part do inventário (Search 'slots')
    - se 1 → confirma; se vários → lib.registerContext para escolher o slot
    - lib.callback 'vp_chopshop:process:start' { benchId, slot }
    - lib.progressBar(duration = Types[partType].duration, canCancel)
        cancel → 'vp_chopshop:process:cancel'
    - lib.callback 'vp_chopshop:process:complete' { processId }
    - notify por res.err (mapa de locale)
```

Menu só aparece quando aplicável (§9). A verdade (tier, welder, distância, estado, slot) é toda revalidada no servidor.

---

## E. TRANSACTION MODEL — START → COMPLETE → commit/rollback

### E.1 Ordem transacional

```
START (client: { benchId, slot })
  ├─ Config.PartProcessing.Enable ................... else 'disabled'
  ├─ ServerPlayerIsReady(src) ...................... else 'player'
  ├─ 1 sessão OPEN/COMMITTING por src .............. else 'busy'
  ├─ rate-limit START (defense-in-depth) .......... else 'processing'
  ├─ benchId = tonumber → benchById() ............. else 'bench'
  ├─ ValidatePlayerNearCoords(src, bench.coords) .. else 'distance'
  ├─ ler slot no ox_inventory (server é a verdade):
  │     item == 'vehicle_part' .................... else 'no_part'
  │     partType ∈ Config.PartProcessing.Types ... else 'bad_type'
  ├─ tier ≥ Types[partType].tier (ou Tier global) . else 'tier'
  ├─ Types[partType].requiresWelder → isWelderNearBench(bench) .. else 'no_welder'
  ├─ LOCK: player + bench + slotIdentity .......... else 'processing'
  └─ cria sessão OPEN { processId, src, benchId, slot, slotIdentity, partType,
                        startedAt, expiresAt = +OpenTtlMs, minDuration = Types[t].duration }
     → { ok, processId, startedAt, expiresAt }

(client roda lib.progressBar por Types[partType].duration)

COMPLETE (client: { processId })
  ├─ sessão existe + src dono ..................... else 'invalid' / 'owner'
  ├─ COMPLETED → replay: devolve MESMO result, ZERO side-effect
  ├─ COMMITTING → 'processing'
  ├─ TERMINAL(outros) → 'closed'
  ├─ rate-limit COMPLETE .......................... else 'processing'
  ├─ now > expiresAt → EXPIRED .................... 'expired'
  ├─ elapsed < minDuration → 'too_fast' (NÃO cancela; client espera e repete)
  ├─ revalidate():
  │     Enable · player · bench · distância · welder (se requiresWelder) · tier
  │     slot ainda tem vehicle_part com slotIdentity IGUAL .. else 'moved' (RECOVERABLE)
  ├─ pin do lock da sessão ....................... else 'lock_lost' → FAILED
  ├─ OPEN → COMMITTING  (sem yield entre revalidate e esta escrita)
  ├─ executor de domínio (D.4) — pode yieldar
  │     inv_full  → CANCELLED, input intacto
  │     gone      → FAILED  (peça sumiu entre revalidate e commit)
  │     quarantine→ FAILED + transaction_locked
  │     ok        → PART_PROCESSED 1× · result = { output }
  └─ COMPLETED + unlock  →  { ok, result }
```

### E.2 Política por modo de falha

| Cenário | Política |
|---|---|
| `RemoveItem` (input) falha | output não é criado. Sessão FAILED. Nada consumido. |
| `AddItem` (output) falha após remover input | **restaurar `vehicle_part` com metadata EXATA** capturada em `removed.metadata`. Sessão CANCELLED (`inv_full`). |
| Restauração do input falha | `VPChopMarkProcessQuarantine` — fail-closed, **sem 2ª tentativa econômica**, log SEVERE. Sessão FAILED (`quarantine`). Peça fica "presa" no registro de quarentena até tooling admin futuro. |
| Inventário cheio (detectado ANTES de remover) | `InvCanCarry` no início do executor → `inv_full` → CANCELLED, input nunca tocado. |
| Disconnect com sessão OPEN | `CleanupPlayer`: OPEN → CANCELLED, nada consumido. |
| Disconnect com sessão COMMITTING | executor (coroutine) continua até `unlock` (sem Wait no domínio). Backstop `CommitMaxMs` só loga, **não** libera. |
| Restart de resource | Sessões in-memory perdidas (mesma limitação de ChopSession/ActionSession — **documentar**). Sessão OPEN no momento do restart: input nunca foi removido → sem perda. COMMITTING no restart: risco teórico de output sem input (janela de ~1 frame, sem yield) — aceitável e idêntico ao risco já existente no discard/deliverCar. |
| Perda de resposta do COMPLETE | client repete → replay idempotente devolve o mesmo `result`, sem novo output. |

---

## F. SERIAL / FORENSICS — como `processed` interage com os demais estados

### F.1 Regras duras

1. **Processar peça inteira ≠ riscar série.** Riscar mantém a peça (`car_parts scratched`, ainda "de um X"). Processar **destrói a identidade física**: o `vehicle_part` deixa de existir; nasce `car_parts processed` sem série nem modelo.
2. **`processed` nunca vira `legal`.** Não chama `IssueLegalParts`, não insere em `vp_chop_legit_serials`.
3. **`forged` continua detectável.** O processamento não toca no fluxo de forja. Uma `vehicle_part` `forged` também pode ser processada → vira `car_parts processed` (a fraude some junto com a identidade — coerente: não há mais o que periciar).
4. **A perícia distingue `processed` de `legal`.**

### F.2 Mudança em `classifyNormal` / `inspectParts` (§8 do prompt)

`server/partserial.lua:classifyNormal` ganha um ramo:

```lua
if state == 'processed' then return 'processed' end
```

E `inspectParts` agrupa `processed` num veredito próprio:
- Scan normal: **"Componente automotivo processado — identificação original inexistente."**
- Com `forensic_kit`: **igual** — a perícia confirma "sem série, sem registro; não classificável como legal". Nunca escala para "Registrada"/"Legítima".

Locale novo: `parts_verdict_processed` (en/pt no mínimo; es/fr/tr seguem o padrão do arquivo).

### F.3 Counterplay preservado

| Fase | Counterplay |
|---|---|
| Transporte da `vehicle_part` | metadata `state='stolen'`, `serial`, `sourceModel` presentes → scanner identifica procedência; a peça é volumosa (peso alto em `ox_items`). |
| Antes do processamento | polícia flagrando `vehicle_part stolen` no inventário = flagrante de receptação. |
| Durante o processamento | duração longa (15–45 s), imobiliza o jogador (`disable move/car/combat`), som/faísca da soldadora (visível/audível), `PART_PROCESSED` seam para evidence/dispatch futuro. |
| Depois | `car_parts processed` não é "limpo": perícia diz "processado / sem identificação". Não é contrabando óbvio, mas não passa como peça legal de oficina séria. |

---

## G. ECONOMY — evitar geração artificial de valor

### G.1 Regra absoluta: **processamento não gera cash** (§15)

`Config.PartProcessing.OutputItem = 'car_parts'` sempre. Nenhum `BridgeAddCash` no caminho. O jogador sai com mercadoria e **precisa achar comprador** (oficina / outro jogador) — cria RP B2B (§14).

### G.2 Cadeia de valor (§16)

```
vehicle_part (bruto, ilegal, rastreável, volumoso, "valor de rua" baixo)
   │  + tempo (15–45s) + risco (imobilizado, som) + logística (transporte) + soldadora
   ▼
car_parts processed × N   (commodity, empilhável, vendável a oficinas)
```

Garantir: `valor(vehicle_part cru vendido a fence/NPC)` **<** `valor(N × car_parts processed vendido a oficina)` **<** `valor infinito/exploitável`.

### G.3 Análise de arbitragem (obrigatória antes de implementar)

Ciclos a **provar impossíveis com ganho líquido** (`A→B→A` positivo):

| Ciclo candidato | Bloqueio |
|---|---|
| `vehicle_part → processar → car_parts → bench_repairkit → …` | `repairkit` é terminal; nenhuma recipe produz `vehicle_part` a partir de `car_parts`/`repairkit`. **Verificar:** nenhuma recipe futura deve reconstituir `vehicle_part`. |
| `car_parts processed` reentra como input de processamento | `ProcessSession.Start` exige `item == 'vehicle_part'`. `car_parts` (qualquer state) rejeitado → `no_part`. |
| Farm de `vehicle_part` sem desmanche real | `vehicle_part` só nasce do executor de desmanche (advanced_chop) — mesma origem consumível e cooldown do chop atual. `sourceSession` amarra ao `cs:` de origem para auditoria. |
| Duplicação via replay do COMPLETE | replay idempotente (E.1). |
| Duplicação via mover item mid-process | `slotIdentity` revalidado → `moved`. |
| Output inflado pelo client | quantidade decidida **server-side** (`math.random(min,max)` no executor); client nunca envia count. |

**Entregável antes de P2:** planilha curta com `min/max` de output por tipo, peso do `vehicle_part`, e o preço-alvo de `car_parts processed` na oficina, mostrando as 3 desigualdades de G.2 satisfeitas para cada tipo.

### G.4 Irreversibilidade

Todo output tem origem consumível (`vehicle_part` removido por slot, count 1) e **irreversível** (série destruída; não há "recuperar peça do lote").

---

## H. WORKSHOP CONTRACT — integração com scripts de oficina

### H.1 Princípio: contrato + adaptador, nunca acoplamento direto (§26/§27)

`vp_chopshop` **não** implementa a oficina e **não** faz `require`/`exports` de nenhum script de mecânico específico no core. A ponte é:

- um **contrato público estável** (item + evento + exports), que qualquer resource consome;
- um **arquivo de adaptador opcional e isolado** (`bridge/workshop.lua`), carregado por último, que traduz o contrato para o script de oficina do servidor. Se o adaptador falhar ao resolver o resource-alvo, **degrada em silêncio** — o processamento continua funcionando, só sem o gancho externo.

Isso mantém o code freeze da arquitetura interna intacto: uma integração nova = editar só `bridge/workshop.lua` + `Config.Workshop`, nunca `part_processing.lua`/`process_session.lua`.

### H.2 Contrato público (4 camadas, da mais fraca à mais forte)

#### 1. Item + metadata (contrato de dados)

`car_parts` é a commodity. `state` documentado e **versionado** — o significado dos 5 estados (`legal/forged/scratched/stolen/processed`) não muda sem major version. Uma oficina consome por nome via `ox_inventory` normal e decide sua própria política:

| Perfil de oficina | Política sugerida sobre `state` |
|---|---|
| Legal / concessionária | aceita só `processed` + `legal`; recusa `stolen/scratched/forged`. |
| "Cinza" / independente | aceita `processed` + `scratched`; paga menos por `scratched`. |
| Black-market / boosting | aceita qualquer estado. |

#### 2. Eventos de saída (vp_chopshop → oficina)

| Evento | Quando | Payload (server-authoritative) | Uso na oficina |
|---|---|---|---|
| `VPChopEvt.PART_PROCESS_STARTED` | START aceito | `{ src, partType, benchId }` | telemetria de atividade; dispatch/heat opcional. |
| `VPChopEvt.PART_PROCESSED` | commit, **1×**, nunca em replay | `{ src, partType, sourceModel, fromState, output, benchId }` | contabilizar **oferta** de commodity; alimentar preço/demanda dinâmica **do lado da oficina**. |
| `VPChopEvt.PART_PROCESS_FAILED` | FAILED/quarentena | `{ src, partType, err }` | métrica de erro; nada econômico. |

Eventos são *fire-and-forget*: a oficina escuta se quiser; a ausência de listener não afeta nada.

#### 3. Exports de entrada (oficina → vp_chopshop)

```lua
-- Debitar car_parts de forma validada (rollback atômico, trust-no-client).
exports['vp_chopshop']:ConsumeCarParts(src, amount, opts?)
  -- opts.states   = { processed = true, legal = true }   -- default: qualquer estado
  -- opts.reason   = 'workshop:repair'                     -- rótulo de auditoria
  -- opts.nearBench = false                                -- se true, exige proximidade de bancada
  -- → ok:boolean, consumedByState:{ [state] = n }, serialsConsumed:string[]

-- Consulta sem debitar (para a oficina montar a UI de "peças disponíveis").
exports['vp_chopshop']:QueryCarParts(src, opts?)
  -- → { total = n, byState = { processed = n, legal = n, ... } }

-- Emitir peça LEGAL (já existe hoje — reaproveitado pela oficina para refurbishment futuro).
exports['vp_chopshop']:IssueLegalParts(src, amount, source?)  -- → ok, serial
```

`ConsumeCarParts` espelha o padrão de `IssueLegalParts` (export público → função local, cap defensivo, log de auditoria, rollback atômico igual a `VPChopServerTryBenchRecipe`).

#### 4. Adaptador configurável (`bridge/workshop.lua` + `Config.Workshop`)

Ponto único de tradução. Nenhuma lógica de negócio — só *wiring*.

```lua
Config.Workshop = {
    Enable   = false,               -- gancho externo desligado por padrão
    Resource = 'auto',              -- 'auto' | nome do resource | 'none'
                                    -- 'auto' → tenta detectar na ordem de Adapters abaixo
    -- Quando a oficina consome car_parts, opcional: gerar heat/dispatch se a peça era suja.
    HeatOnDirtyConsume = false,

    -- Adaptadores conhecidos. O primeiro cujo GetResourceState(...) == 'started' vence.
    Adapters = {
        -- exemplos ESTRUTURAIS (confirmar export real de cada script antes de usar):
        ['qs-mechanicjob'] = {
            -- oficina PEDE peça → nós debitamos e devolvemos ok
            onRequestParts = function(src, amount, filter)
                return exports['vp_chopshop']:ConsumeCarParts(src, amount, { states = filter, reason = 'qs-mechanic' })
            end,
        },
        ['qb-mechanicjob'] = { onRequestParts = function(src, amount, filter) --[[ idem ]] end },
        ['cd_dealership']  = { onIssueLegal   = function(src, amount) return exports['vp_chopshop']:IssueLegalParts(src, amount, 'dealership') end },
        ['rcore_mechanic'] = { onRequestParts = function(src, amount, filter) --[[ idem ]] end },
        ['custom']         = { --[[ o servidor preenche à mão ]] },
    },
}
```

`bridge/workshop.lua` (carregado por ÚLTIMO no `server_scripts`, depois de `part_processing.lua`):

```lua
-- resolve o adaptador ativo (1×, no boot; re-resolve em onResourceStart/Stop do alvo)
-- registra os listeners de PART_PROCESSED etc. SÓ se Config.Workshop.Enable
-- expõe exports['vp_chopshop']:WorkshopBridgeStatus() para /debug
-- se nada resolver → loga 1 linha e segue; processamento intacto
```

### H.3 Fluxos de integração suportados

| Direção | Fluxo | Mecanismo |
|---|---|---|
| chopshop → oficina | jogador processa peça → oficina registra +N de oferta e ajusta seu preço | `PART_PROCESSED` listener |
| oficina → chopshop | mecânico usa `car_parts` num reparo → débito validado, rollback atômico | `ConsumeCarParts` export |
| oficina → chopshop | oficina mostra "você tem X peças processadas" na UI | `QueryCarParts` export |
| oficina → chopshop | refurbishment/venda legal futura entrega peça com procedência limpa | `IssueLegalParts` export (já existe) |
| chopshop → polícia/dispatch | oficina consome peça **suja** → heat opcional | `Config.Workshop.HeatOnDirtyConsume` + `serialsConsumed` do retorno |
| bidirecional | trocar de script de oficina = editar só `Config.Workshop.Adapters` | adaptador isolado |

### H.4 Garantias do contrato

- **Estável entre minor versions:** nomes de item, chaves de `state`, assinatura dos exports, nomes/payload dos eventos. Mudança = major + entrada no CHANGELOG + nota de migração.
- **Trust-no-client em ambos os lados:** `ConsumeCarParts` valida `src`, lê inventário server-side, remove com rollback; nunca aceita quantidade/estado/serial do client da oficina.
- **Degradação graciosa:** `Config.Workshop.Enable = false` ou resource-alvo ausente → zero erro, processamento normal, exports continuam disponíveis para chamada manual.
- **Sem dependência circular:** `vp_chopshop` nunca chama `exports['<oficina>']` fora de `bridge/workshop.lua`; o adaptador só chama para dentro (`vp_chopshop:*`) ou reage a eventos.

### H.5 O que **não** entra agora (§27)

Preço player-driven nativo, wholesale orders, mechanic demand dinâmica *dentro* do vp_chopshop, market/leilão. O contrato H.2 + adaptador H.2.4 é o suficiente para uma oficina externa consumir `car_parts` e construir esses sistemas **do lado dela**. Documento dedicado `docs/design/WORKSHOP_CONTRACT.md` na PR #17 com os exports finais e um exemplo de adaptador completo.

---

## I. TEST PLAN

### I.1 Specs (harness `tools/run_spec.lua`, self-gated `vp_chopshop_selftest`)

`server/session/process_session_spec.lua` — seams controláveis: `INV_CAN_CARRY`, `REMOVE_OK`, `ADD_OK`, `RESTORE_OK`, `WELDER_NEAR`, `TIER`, `SLOT_ITEM`, `SLOT_META`, `CLOCK`. Observabilidade: `quarantineMarked`, `partProcessedEmits`.

| ID | Cenário | Asserção |
|---|---|---|
| PROC1 | `vehicle_part` stolen válida, welder ok, tier ok | 1× COMPLETE → `car_parts` `state='processed'`, count ∈ [min,max]; `vehicle_part` removido; `PART_PROCESSED` 1×. |
| PROC2 | slot sem item / item ≠ vehicle_part | START → `no_part`. |
| PROC3 | metadata adulterada pelo client no payload | payload só tem `{benchId, slot}`; metadata é lida do servidor → adulteração impossível/ignorada. |
| PROC4 | `partType` fora de `Config.PartProcessing.Types` | START → `bad_type`. |
| PROC5 | `benchId` inexistente | START → `bench`. |
| PROC6 | longe da bancada | START → `distance`; e no COMPLETE → `distance` (RECOVERABLE → CANCELLED). |
| PROC7 | `requiresWelder=true`, sem welder no raio | START → `no_welder`. |
| PROC8 | welder no raio | START ok. |
| PROC9 | COMPLETE duplo (2ª chamada) | 2ª = replay, `result` idêntico, **0** side-effect extra; `PART_PROCESSED` continua 1×. |
| PROC10 | 2 jogadores mesma peça (mesmo slot conceptual) | LOCK slotIdentity + 1-sessão-por-player → só 1 commit; o 2º recebe `processing`/`moved`. |
| PROC11 | `InvCanCarry` = false | CANCELLED `inv_full`; `vehicle_part` **intacto** (nunca removido). |
| PROC12 | `RemoveItem` falha | output 0; FAILED; nada consumido. |
| PROC13 | `AddItem` output falha após remove | `vehicle_part` restaurado com **metadata EXATA** (`serial`, `state`, `sourceModel`, `partType`, `sourceSession`); CANCELLED `inv_full`. |
| PROC14 | restauração do input falha | `quarantineMarked == 1`; FAILED `quarantine`; sem 2ª tentativa; log SEVERE. |
| PROC15 | disconnect com sessão OPEN | `CleanupPlayer` → CANCELLED; sem consumo. |
| PROC16 | perda de resposta → client repete COMPLETE | replay, sem novo output. |
| PROC17 | após processar, série não entra em legit | `VPChopDbRegisterLegitSerial` **nunca** chamado; DB legit inalterado. |
| PROC18 | scanner sobre `car_parts processed` | veredito `processed` ("sem identificação"); **nunca** "legal"/"Registrada". |
| PROC19 | `vehicle_part forged` → processar; depois periciar outra `forged` intacta | forja continua flagrável pela perícia no fluxo normal (regressão de `partserial`). |
| PROC20 | suite completa | **0 regressão** nos 493 asserts anteriores; novo total registrado. |

### I.2 Runtime QA (após specs verdes, servidor real)

- `vehicle_part` nasce do advanced chop com metadata correta (netId → serial compartilhado).
- Processar com/sem soldadora conforme `Types`.
- `lib.progressBar` cancelável → `process:cancel` → peça intacta.
- 2 jogadores disputando a mesma peça.
- Restart de resource durante sessão OPEN e durante COMMITTING.
- Perícia policial vê `processed` corretamente.
- resmon da bancada permanece ~0.00ms idle (sem thread por sessão; §29).

---

## J. IMPLEMENTATION PLAN — PRs pequenas e stacked (só após RC verde)

| PR | Nome | Conteúdo | Depende de |
|---|---|---|---|
| **#12** | `feat(process): domain model + config` | `ox_items` `vehicle_part`; `Config.PartProcessing` (Enable=false); `VPChopEvt.PART_PROCESS_*`; docstrings do contrato de metadata. Sem lógica. | RC verde |
| **#13** | `feat(process): ProcessSession core + specs` | `server/session/process_session.lua` + `_spec.lua` (PROC1–PROC16 no nível da sessão, com seams). START/COMPLETE/CANCEL/replay/pin/sweeper. Nenhum callback client ainda. | #12 |
| **#14** | `feat(process): domain executor + quarantine` | `server/part_processing.lua` executor (D.4) + `VPChopMarkProcessQuarantine` + specs PROC11–14, PROC17. Emissão de `PART_PROCESSED`. | #13 |
| **#15** | `feat(process): bench UX + callbacks` | `vp_chopshop:process:start/complete/cancel/availability`; opção "Processar peça" em `client/bench.lua`; locale keys (en/pt + es/fr/tr). Specs PROC5–10. | #14 |
| **#16** | `feat(process): forensic integration` | `classifyNormal` + `inspectParts` ramo `processed`; `parts_verdict_processed` locale; specs PROC18–19. | #15 |
| **#17** | `feat(process): workshop commodity contract` | `exports:ConsumeCarParts` + `:QueryCarParts`; `bridge/workshop.lua` + `Config.Workshop` (adaptador, Enable=false); `docs/design/WORKSHOP_CONTRACT.md` com exports finais + exemplo de adaptador completo; análise de arbitragem final (G.3) versionada. Specs: `ConsumeCarParts` rollback atômico, filtro por `state`, degradação com alvo ausente. | #16 |

Cada PR: implementar → harness → `luac -p` → commit → push → body → memória → **PARAR** para revisão (mesmo workflow da stack #2→#11). Nenhuma PR mergeia sozinha.

---

## K. RISKS

| # | Risco | Mitigação |
|---|---|---|
| R1 | **Duplicação por replay / perda de resposta** | replay idempotente `ProcessSession.Complete` (COMPLETED → mesmo result, 0 side-effect); `PART_PROCESSED` só no caminho não-replay. |
| R2 | **Duplicação por mover item mid-process** | `slotIdentity` (slot+item+serial+state+partType+count) revalidado no COMPLETE → `moved` → CANCELLED. |
| R3 | **Metadata spoof** (client força `state='forged'` barato, ou `partType` inválido) | payload client = só `{benchId, slot}`. Tudo lido do `ox_inventory` server-side. `partType` fora de `Types` → `bad_type`. |
| R4 | **Output inflado** | quantidade `math.random(min,max)` **no executor server**; client nunca envia count. |
| R5 | **Restart de resource** | sessões in-memory perdidas (limitação documentada, = ChopSession/ActionSession). OPEN no restart = input nunca removido → sem perda. COMMITTING = janela ~1 frame sem yield, risco idêntico ao já aceito no discard. |
| R6 | **Inventário cheio destruindo a peça** | `InvCanCarry` **antes** de `RemoveItem`; se ainda assim `AddItem` output falhar → restauração EXATA da metadata; se ela falhar → quarentena fail-closed, sem 2ª tentativa. |
| R7 | **Arbitragem / ciclo econômico positivo** | G.3: nenhuma recipe reconstrói `vehicle_part`; `car_parts` rejeitado como input; output só a partir de peça consumível de origem `cs:` real; planilha das 3 desigualdades antes de P2. |
| R8 | **Welder-presence spoof** | `isWelderNearBench(bench)` já é verdade server-side (welders vêm do DB); revalidado no START **e** no COMPLETE. |
| R9 | **`processed` interpretado como `legal` por oficina** | veredito de perícia próprio; contrato H.2 documenta que `processed ≠ legal`; export `ConsumeCarParts` expõe `consumedByState` para a oficina decidir. |
| R10 | **Feature muda balance/economia sem intenção** | `Config.PartProcessing.Enable = false` no nascimento; nenhum `BridgeAddCash`; `car_parts` (item já existente) é o único output. |
| R11 | **God object / ActionSession contaminada** | `ProcessSession` é módulo novo e separado; `action_session.lua` e `chop_session.lua` **não** são tocados. |
| R12 | **Integração de oficina acopla o core / quebra em restart de outro resource** | toda ponte externa vive em `bridge/workshop.lua` (carregado por último, só wiring); `Config.Workshop.Enable=false` por padrão; re-resolve o adaptador em `onResourceStart/Stop` do alvo; alvo ausente → 1 log, processamento intacto. `vp_chopshop` nunca chama `exports['<oficina>']` fora desse arquivo. |
| R13 | **`ConsumeCarParts` chamado por resource malicioso/bugado** | valida `src`, lê inventário server-side, cap defensivo de `amount`, rollback atômico, log de auditoria com `opts.reason`; sem efeito se `src` inválido. Debita apenas — nunca credita cash. |

---

## L. RECOMMENDATION

**GO — com modificações**, sujeito a: RC real (FASE 3–26) verde primeiro.

| Decisão | Recomendação |
|---|---|
| Item de entrada | **Modelo A** — `vehicle_part` genérico com metadata (`partType`, `serial`, `state`, `sourceModel`, `sourceSession`). |
| Estado novo | `processed` em `car_parts` (`serial=nil`, `sourceModel=nil`). `processed ≠ legal ≠ stolen`. |
| Config | `Config.PartProcessing` **separado** de `Config.BenchRecipes`. |
| Transação | `ProcessSession` **novo**, espelhando os invariants da ActionSession, **sem** depender de veículo/ChopSession. Não reusar ActionSession diretamente. |
| Bancada | reusar `chopshop_bench` (prop, persistência, `ox_target`); nova opção condicional. Sem prop novo. |
| Soldadora | `requiresWelder` **por tipo** em `Config.PartProcessing.Types`. |
| Economia | processamento **nunca** paga cash; produz `car_parts processed`; planilha de arbitragem obrigatória antes de P2. |
| Oficina | contrato público (item+metadata versionados · eventos `PART_PROCESS_*` · exports `ConsumeCarParts`/`QueryCarParts`/`IssueLegalParts`) **+ adaptador isolado** `bridge/workshop.lua` + `Config.Workshop.Adapters` (qs/qb/rcore/cd/custom). `vp_chopshop` **não** implementa a oficina e nunca chama `exports['<oficina>']` fora do adaptador; degradação graciosa. |
| Roadmap | 6 PRs stacked `#12→#17`, mesmo workflow da stack atual, nenhuma mergeia sozinha. |

**NÃO fazer agora:** abrir código, criar branch, tocar em `action_session.lua`/`chop_session.lua`, implementar oficina/market/contracts, quebrar o `v1.15 CODE FREEZE`.

**Próximo passo real:** nada no código. Retomar quando o RC FiveM/QBox estiver validado; então iniciar pela PR #12 (domain model + config, sem lógica).
