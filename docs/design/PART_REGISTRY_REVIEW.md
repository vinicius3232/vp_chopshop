# PART_REGISTRY_SPIKE_REVIEW

**Data:** 2026-08-28 · **Escopo:** travar o CONTRATO arquitetural do `PartRegistry` + `ToolRegistry` enquanto mudar schema ainda é barato. **Não** implementar `PhysicalPart`, storage genérico ou tool durability.
**Base:** spike local `spike/part-registry` sobre `dd1ee9f` (tip `pr-h`). Harness 493→517, 0 regressão.
**Veredito antecipado:** `GO` na arquitetura do spike · `NO-GO` para consumo runtime antes do RC · **schema v1 → v2** aplicado nesta revisão (5 mudanças, todas parity-safe).

---

## 1. Objetivos

| # | Objetivo | Status |
|---|---|---|
| O1 | Fonte **única** de definição de peça (hoje `ChopParts` é thin; advanced hardcoda kind/tool/deps em `server/action/advanced_chop.lua`) | schema pronto, inerte |
| O2 | Fonte **única** de ferramenta (hoje espalhado: `Config.Tools` + `Config.AdvancedChop.SawItem/ScrewdriverItem` + `Config.Jackstand.Item`) | schema pronto, inerte |
| O3 | Projeção **byte-idêntica** do `ChopParts` legado → migração sem mudança de comportamento | `R.projectChopParts()` + spec provam |
| O4 | Part Graph **declarativo** (`requires`) em vez de `if` no executor (prompt §22) | schema v2: predicados tipados |
| O5 | Preparar `remove` **e** `install` (prompt §6) sem novo fluxo | schema v2: `action.type` |
| O6 | Ser o ponto de encontro `ChopSession × ActionSession × ToolRegistry × PhysicalPart × Workshop` | ver §12 |
| O7 | **Não** criar autoridade nova nem consumo runtime antes do RC | garantido — 0 call sites |

---

## 2. Schema atual (v1 do spike) — e por que muda

`PartDefinition` v1 tinha: `id, category, kind, doorIndex, labelKey, bones, tools[], requiresRaised, requires[], action{kind,minDurationMs,distance,minigame}, carry, reward{source}, serialized, enabled`.
`ToolDefinition` v1 tinha: `id, class, actions[], maxUses, speed, noise, dispatchChance, breakChance, requiredTier, handProp`.

A review adversarial (§11) encontrou 5 defeitos de forma que ficam **caros** de corrigir depois que ActionSession/PhysicalPart/WorkshopBridge consumirem. Corrigidos agora (§12).

---

## 3. Campos compatíveis com o legado (autoridade = `ChopParts` até a FASE F)

| Campo v2 | Legado equivalente | Regra |
|---|---|---|
| `gtaClass` (`'door'\|'tyre'\|nil`) | `ChopParts[id].kind` | **idêntico** p/ as 10 peças GTA; `nil` p/ sintéticas (`adv_engine`/`adv_carcass`) |
| `gtaIndex` (int\|nil) | `ChopParts[id].index` | **idêntico**; `nil` p/ sintéticas → excluídas de `projectChopParts()` |
| `labelKey` | `ChopParts[id].labelKey` | **idêntico** |
| `R.order` (sub-lista GTA) | `ChopPartOrder` | **idêntico**; **regra dura: peça nova SEMPRE anexa no fim, nunca insere** (menus dependem da ordem) |
| `action.kind` p/ doors/engine/carcass | kind hardcoded em `server/action/advanced_chop.lua` | `adv_door`/`adv_engine`/`adv_carcass` — spec cruza |
| `action.minDurationMs` | `Config.ActionSession.MinDurationMs[minDurKey]` | door=1500, engine=2000, carcass=2500, tyre=1500 — spec cruza |
| `action.distance` | `distance` no `RegisterKind` | door=6, engine=6, carcass=8, tyre≈7 — spec cruza |
| `requires` | `VPChopAdvancedState.wasRemoved(sid, 'bonnet'/'adv_engine')` | `adv_engine→bonnet`, `adv_carcass→adv_engine` — spec cruza |
| `gates.raised` | `requiresRaised` / `ChopSession.raised` | wheels=true, doors=false (paridade exata com hoje) |
| `gates.welder` | `VPChopWelderNearVehicle(netId)` | `adv_carcass`=true |
| `toolClass` | `VPChopHasTool(src, wantDrill)` — `wantDrill=false`→`'cut'`, `true`→`'screw'` | tyre/door=`'cut'`, engine=`'screw'`, **carcass=`nil`** (hoje o validate de carcass NÃO checa serra, só welder) |

**Contrato de paridade:** se o `registry_spec` passa, trocar `shared/chop_parts.lua` pela projeção é uma refatoração de 0 bit.

---

## 4. Campos apenas-futuros (INERTES até a PR que os consumir)

| Campo | Consumido por | PR |
|---|---|---|
| `bones[]` | resolver de ponto de interação (`client/interaction.lua`) | Wheels V2 / #14 |
| `action.type` (`'remove'\|'install'\|'inspect'`) | `install` na oficina; `inspect` na perícia | Workshop / #24 |
| `action.minigame` | `bridge/minigames.lua` provider | #15 |
| `carry.{prop,animation}` | carry genérico (`PartEntitlement`) | #14 |
| `rewardProfile` (id opaco) | `RewardResolver` — o registry **não** faz matemática de reward | #16 |
| `provenance` (`nil\|'commodity'\|'component'`) | `vehicle_part` metadata + `PartSerial` v2 | #17/#18 |
| `noise` (0..1, part-inherente) | Heat V2 (soma com `tool.noise`) | #22 |
| `gates.hoodOpen` | "desconectar bateria" (hood **aberto** ≠ **removido**) | #17 |
| `tool.breakChance` / `tool.requiredTier` | Tool durability / gating por tier | pós-#12 |
| `tool.uxSpeed` | **só** a barra de progresso do client — **nunca** o `minDurationMs` server | já documentado |

---

## 5. Invariantes (não-negociáveis do contrato)

| # | Invariante |
|---|---|
| I1 | **`action.minDurationMs` é piso server-authoritative e é INDEPENDENTE de ferramenta.** `tool.uxSpeed` afeta só a barra do client. Uma serra rápida encurta a UX, nunca a janela anti-instant-complete. |
| I2 | **Client manda só o alvo** (`{sessionId, action}`). `kind`, `toolClass`, `minDurationMs`, `distance`, `requires`, `reward` — tudo derivado do registry no servidor. |
| I3 | **`gtaClass`/`gtaIndex` espelham `ChopParts` exatamente** enquanto o legado for autoridade (até FASE F). Divergência = bug, pego pelo spec. |
| I4 | **Ordem legada é imutável.** Peça nova anexa em `R.order`; nunca insere entre peças existentes. |
| I5 | **`requires` são predicados tipados** `{part, state}`, não lista de ids. Permite `REMOVED` hoje e `OPEN`/`DISCONNECTED` no futuro sem quebrar o schema. |
| I6 | **O registry não faz matemática de economia.** `rewardProfile` é um rótulo; a resolução vive num `RewardResolver` separado (autoridade continua no executor/`Config`). |
| I7 | **Ferramenta = item consumível do `ox_inventory`** (`saw_cheap`/`saw_pro`/`mechanic_drill`). Welder e jackstand são **gates**, não tools — `gates.welder` / sistema próprio do jackstand. |
| I8 | **`enabled=false` numa peça nunca quebra consumidor.** Consumidores tratam registry vazio. Sem master-switch ainda (spike é inerte). |
| I9 | **Nada consome o registry antes do RC.** 0 call sites. `git grep VPChopPartRegistry` fora de `shared/registry/` e `tools/` deve ser vazio até a FASE C. |
| I10 | **`metal_saw` / `screwdriver` (Config.AdvancedChop) são config MORTA** — `VPChopHasTool` nunca os lê. O registry **não** os modela; a limpeza deles é chore separado. |

---

## 6. Relação com `ChopParts`

```
HOJE:   ChopParts (thin) ── autoridade ──▶ base chop / advanced / menus / ActionSession.validate
SPIKE:  ChopParts (thin) ── autoridade ──▶ ... (inalterado)
        VPChopPartRegistry ──(inerte)──▶ nada
        VPChopPartRegistry.projectChopParts() ══(prova de igualdade no spec)══ ChopParts
FASE F: shared/chop_parts.lua  ⟶  return VPChopPartRegistry.projectChopParts()
        (ou o arquivo é deletado e consumidores passam a ler o registry direto)
```

`ChopParts.kind` só tem `'door'|'tyre'`. O registry adiciona `adv_engine`/`adv_carcass` com `gtaClass=nil` — **não vazam** para a projeção (`gtaIndex==nil` filtra). `adv_door` **não é peça** — é o `action.kind` de `bonnet`/`boot`/`door_*` (erro do spec v1, corrigido).

---

## 7. Relação com `ActionSession`

Hoje `server/action/advanced_chop.lua` faz, por kind:
```lua
ActionSession.RegisterKind('adv_engine', {
  minDurKey = 'engine', distance = 6.0,
  validate = function(v)
    if not VPChopAdvancedState.wasRemoved(v.sessionId, 'bonnet') then return 'hood_first' end
    if not VPChopHasTool(v.src, true) then return 'no_screwdriver' end
  end,
})
```
Na **FASE D** isso vira genérico:
```lua
for id, def in pairs(VPChopPartRegistry.defs) do
  ActionSession.RegisterKind(def.action.kind, {
    minDurKey = def.action.kind,           -- Config.ActionSession.MinDurationMs
    distance  = def.action.distance,
    validate  = function(v)
      local pdef = VPChopPartRegistry.get(v.action)
      for _, req in ipairs(pdef.requires) do
        if not VPChopAdvancedState.wasRemoved(v.sessionId, req.part) then return 'dep:'..req.part end
      end
      if pdef.toolClass and not VPChopHasTool(v.src, pdef.toolClass == 'screw') then return 'no_tool' end
      if pdef.gates.welder and not VPChopWelderNearVehicle(v.netId) then return 'no_welder_adv' end
    end,
  })
end
```
**Contrato:** `ActionSession` nunca lê o registry direto no COMPLETE — o `validate` (fornecido pelo wiring) faz. `ActionSession` continua agnóstico. `minDurationMs` continua vindo de `Config.ActionSession` (I1) — o registry só diz **qual chave**.

---

## 8. Relação com `ToolRegistry`

```
PartDefinition.toolClass  ('cut'|'screw'|nil)   ──autoridade──▶  qual família de ferramenta a ação exige
ToolDefinition.class      ('cut'|'screw')       ──────────────▶  a que família um item pertence
ToolDefinition.maxUses/uxSpeed/noise/dispatch   ──────────────▶  comportamento do item (durabilidade / UX / heat)
```
**Sentido único:** peça → classe → itens (`R.toolsForClass('cut')` = `{saw_cheap, saw_pro}`). **Não** existe mapa reverso `tool.actions` (v1 tinha — removido: era drift garantido). Se nenhum item de uma classe existe, o `validate` da ActionSession nega `no_tool` — comportamento correto.

`VPChopHasTool(src, wantDrill)` já usa exatamente esse split (`mechanic_drill` = drill; resto de `Config.Tools` = saw). O registry só o nomeia (`'screw'` vs `'cut'`).

---

## 9. Futuro `PhysicalPart`

O registry é o **contrato de nascimento** de um `PhysicalPart` (a instância). Nada aqui implementa `PhysicalPart` — mas o schema garante que ele pode nascer sem mudança de contrato:

```
PartDefinition (o TIPO)                 PhysicalPart (a INSTÂNCIA — PR futuro)
──────────────────────                 ─────────────────────────────────────
id, category, gtaClass                 defId  → PartRegistry.get(defId)
provenance = 'component'                serial, sourceVsid, sourceModel, condition, removedBy, removedAt, org, stolen
carry.{prop,animation}                 state ∈ AVAILABLE→LOCKED→REMOVING→REMOVED→CARRIED→STORED→PROCESSED→SOLD→DESTROYED
rewardProfile                          (usado só se vendido como commodity)
action.type='install'                  (consumido pela WorkshopBridge)
```
`provenance`:
- `nil` → peça não instancia (só remove/destrói — ex.: carcaça)
- `'commodity'` → vira `car_parts` com metadata `{serial,state,sourceModel}` (padrão atual)
- `'component'` → vira `vehicle_part` (`partType`, condição, procedência rica) — RFC #17

### 10. Migration path pós-RC

```
FASE A ─ Registry existe, ninguém consome
         · shared/registry/{tools,parts}.lua + registry_spec.lua   [SPIKE — FEITO]
         · fxmanifest + run_spec wired · 0 call sites · harness 517
         · GATE: RC das 26 fases verde + stack #2→#11 mergeada

FASE B ─ Registry projeta ChopParts legado
         · PR: shared/chop_parts.lua  →  return VPChopPartRegistry.projectChopParts()
         · ZERO mudança de comportamento (spec já prova a igualdade)
         · risco: só rebase; rollback = 1 revert
         · GATE: harness verde + smoke test (menu de desmanche mostra as 10 peças)

FASE C ─ UM vertical slice consulta o Registry
         · escolha: bonnet (base chop, sem economia nova, sem carry)
         · server/chop.lua lê PartRegistry.get('bonnet').gtaIndex em vez de ChopParts
         · resto continua no ChopParts
         · GATE: bonnet chop funciona igual in-game; 2 players; resmon

FASE D ─ ActionSession deriva metadata do Registry
         · server/action/advanced_chop.lua: loop genérico (ver §7)
         · adv_door/adv_engine/adv_carcass: kind/dist/deps/toolClass vêm do registry
         · minDurationMs CONTINUA de Config.ActionSession (I1)
         · GATE: adv chop completo (hood→engine→carcass) idêntico; deps negam na ordem certa

FASE E ─ Advanced hardcodes desaparecem
         · remove os 3 RegisterKind manuais de server/action/advanced_chop.lua
         · remove Config.AdvancedChop.SawItem/ScrewdriverItem (config morta — I10)
         · GATE: regressão advanced completa + matriz de exploit §27

FASE F ─ ChopParts legado deixa de ser autoridade
         · consumidores restantes (client menus, base chop) leem PartRegistry direto
         · shared/chop_parts.lua deletado OU vira alias fino
         · adicionar Config.PartRegistry.Enable (master switch)
         · GATE: full regression suite + soak 30-60 min
```
Cada fase: PR pequena · `Enable`/flag · harness + `luac -p` · body + memória · **PARA para revisão**.

---

## 11. Review adversarial da forma (v1 → defeitos)

| # | Defeito (v1) | Por que é caro depois | Correção (v2) |
|---|---|---|---|
| **A1** | `kind` sobrecarregado: `PartDefinition.kind` (`tyre\|door\|engine\|carcass`) **e** `action.kind` (`tyre\|adv_door\|adv_engine\|adv_carcass`) — dois conceitos, um nome | consumidor lê o `kind` errado; `engine`/`carcass` não são famílias GTA e poluem a paridade com `ChopParts.kind` | `gtaClass` (`door\|tyre\|nil`, = `ChopParts.kind` EXATO) + `action.kind` (roteamento ActionSession). Nome `kind` sozinho eliminado. |
| **A2** | `doorIndex` — para rodas é índice de **roda**, não de porta. Misnomer | quem lê `doorIndex` numa roda passa índice errado p/ `SetVehicleDoorBroken` | `gtaIndex` (neutro, = `ChopParts.index` EXATO) |
| **A3** | `tools = {'weld','cut'}` lido como **OR**, mas `adv_carcass` exige welder **obrigatório** (AND) + serra opcional. Schema não expressa AND. Pior: **welder não é item** (`VPChopWelderNearVehicle` = proximidade de world object), nem jackstand (`Config.Jackstand.Item`) | executor deriva "serra OU welder serve" → carcaça desmontável sem welder = **exploit econômico** | `toolClass` (string única, `cut\|screw\|nil` — a família de **item consumível** exigida) **+** `gates = {raised, welder, hoodOpen}` (requisitos não-inventário, explícitos). `metal_saw`/`screwdriver`/`welder`/`jackstand` saem do Tool Registry. |
| **A4** | `reward = { source = 'AdvancedChop.EngineReward' }` — string apontando p/ path de `Config`. Stringly-typed. E não captura que `bonnet` paga diferente via base chop vs advanced | typo = silêncio; a matemática de reward acaba meio no registry meio no executor; muda balance sem intenção | `rewardProfile` = id opaco (`'wheel_commodity'`, `'engine_bulk'`, …). Um `RewardResolver` (PR #16) mapeia. Registry **não** faz economia (I6). |
| **A5** | `action` singular, sem `type`. `requires` = lista de ids = "must be REMOVED" (predicado único implícito) | `install` (prompt §6) e "hood **aberto**" (§17) não cabem; adicionar depois quebra todo consumidor de `requires` | `action.type` (`remove\|install\|inspect`) + `requires = { {part='bonnet', state='REMOVED'} }` (predicado tipado — I5) |
| A6 | `bones = {id}` assume nomes GTA-padrão (moto não tem `bonnet`) | resolver quebra em veículos exóticos | documentado como **hint**; resolver cai em `gtaIndex`/offset. Sem mudança de schema. |
| A7 | `ToolRegistry.class` enum tem `scan\|hack\|lift` sem nenhum tool — e o spec valida `CLASSES[d.class]`, então classe typo que esteja no enum passa | falsa sensação de cobertura | `CLASSES` derivado dos `defs` reais + lista `RESERVED` documentada à parte |
| A8 | `tool.actions[]` (mapa reverso peça←tool) duplica `part.toolClass` | drift: part diz `cut`, nenhum tool `cut` lista aquela ação → set vazio silencioso | **remover** `tool.actions`. Sentido único: `part.toolClass` → `R.toolsForClass()`. Spec assere "todo `action.kind` tem ≥1 tool da classe". |
| A9 | `speed` (`0.7 = mais rápido`) ambíguo vs `minDurationMs` | alguém aplica `speed` ao piso server → quebra anti-instant-complete (I1) | renomeado `uxSpeed` + I1 explícito: **só a barra do client** |
| A10 | `maxUses` sem default documentado; metadata key não especificada | durabilidade diverge do runtime (`uses_remaining`, default 6) | `maxUses` default **6** (= `VPChopConsumeTool`), metadata key `uses_remaining` documentada |
| A11 | `enabled` por peça, sem `R.isEnabled()` nem master switch | consumidor da FASE C quebra com registry parcialmente desabilitado | `R.isEnabled(id)` no v2; master `Config.PartRegistry.Enable` fica p/ FASE F (I8) |

**Parity risk fechado:** v1 listava `metal_saw`/`screwdriver` como ferramentas reais. Confirmado em `server/main.lua:237` que `VPChopHasTool`/`VPChopConsumeTool` iteram **só `Config.Tools`** (saw_cheap/saw_pro/mechanic_drill). `metal_saw`/`screwdriver` de `Config.AdvancedChop` **nunca são lidos** — config morta (I10). Modelá-los teria criado uma ferramenta fantasma.

---

## 12. Schema v2 (aplicado ao spike nesta revisão)

### `ToolDefinition` v2
```lua
{
  id             = 'saw_pro',        -- item ox_inventory (só saw_cheap / saw_pro / mechanic_drill)
  class          = 'cut',            -- 'cut' | 'screw'   (famílias REAIS; ver R.RESERVED p/ futuras)
  maxUses        = 6,                -- default 6 (== VPChopConsumeTool); metadata key 'uses_remaining'
  uxSpeed        = 1.0,              -- multiplicador da BARRA DE PROGRESSO do client. NUNCA toca minDurationMs (I1)
  noise          = 0.6,             -- 0..1  (Heat V2)
  dispatchChance = 0.25,            -- 0..1  (client-side hoje)
  breakChance    = 0.0,             -- futuro
  requiredTier   = 2,               -- futuro
  handProp       = { model=..., offset=..., rotation=... } | nil,
}
```
Removidos: `actions[]` (A8), `metal_saw`/`screwdriver`/`welder`/`chopshop_jackstand` (A3).

### `PartDefinition` v2
```lua
{
  id            = 'adv_engine',
  category      = 'engine',                         -- agrupamento econômico/UI
  gtaClass      = nil,                              -- 'door'|'tyre'|nil  (== ChopParts.kind; nil = sintética)  [A1]
  gtaIndex      = nil,                              -- int|nil  (== ChopParts.index)                            [A2]
  labelKey      = 'part_engine',
  bones         = { 'engine' },                     -- HINT; resolver cai em gtaIndex/offset                    [A6]
  toolClass     = 'screw',                          -- 'cut'|'screw'|nil  (família de ITEM exigida)             [A3]
  gates         = { raised=false, welder=false, hoodOpen=false },  -- requisitos NÃO-inventário                 [A3]
  requires      = { { part='bonnet', state='REMOVED' } },          -- predicados tipados (Part Graph)           [A5]
  action        = { type='remove', kind='adv_engine', minDurationMs=2000, distance=6.0, minigame='mechanical' },-- [A5]
  carry         = { enabled=false, prop=nil, animation=nil },
  rewardProfile = 'engine_bulk',                    -- id opaco; RewardResolver mapeia (PR #16)                 [A4]
  provenance    = nil,                              -- nil|'commodity'|'component'  (futuro vehicle_part)       [A4]
  noise         = 0.5,                              -- part-inerente (Heat V2)
  enabled       = true,
}
```
Removidos: `kind` (→`gtaClass`), `doorIndex` (→`gtaIndex`), `requiresRaised` (→`gates.raised`), `tools[]` (→`toolClass`+`gates`), `reward.source` (→`rewardProfile`), `serialized` (→`provenance`).

---

## 13. Veredito

| Item | Veredito |
|---|---|
| **Arquitetura do spike** (registry como ponto de encontro §6/§12) | **`GO`** — ataca a fundação, não é lateral |
| **Schema v1** | `NO-GO` — 11 defeitos de forma (§11) |
| **Schema v2** (§12) | **`GO`** — todas as mudanças são parity-safe; spec continua provando a igualdade com `ChopParts` |
| **Consumo runtime antes do RC** | **`NO-GO`** — 0 call sites até FASE C; RC + merge da stack primeiro (I9) |
| **Próximo passo concreto** | aplicar v2 aos 3 arquivos do spike + rodar harness (feito nesta revisão) → congelar o contrato → esperar o RC |

O momento de mudar schema é **agora**. Depois que `ActionSession` (FASE D), `PhysicalPart` e `WorkshopBridge` consumirem, cada campo renomeado é um PR de refactor multi-arquivo.
