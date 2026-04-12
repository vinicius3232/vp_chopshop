# Heavy RP Gameplay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adicionar três pilares de heavy RP ao vp_chopshop: sistema de Heat (risco por veículo), Fence rotativo com trust (economia criminal) e Progressão por tiers (desbloqueios persistentes).

**Architecture:** Event-driven interno via `VPChopEvt` — nenhum módulo chama outro diretamente. Heat calculado on-demand (zero loop). Fence é o único NPC criminal, rotativo entre 4 locais. Progressão persistida em SQL com tiers que desbloqueiam mecânicas.

**Tech Stack:** FiveM lua54, ox_lib (callbacks/notify/target/progressbar), ox_inventory, oxmysql, ox_target

**Spec:** `docs/superpowers/specs/2026-04-11-heavy-rp-gameplay-design.md`

**Nota:** Este repositório não usa git. Marcar cada `- [ ]` como concluído após completar o passo.

---

## Mapa de Arquivos

### Criar (novos)
| Arquivo | Responsabilidade |
|---------|-----------------|
| `shared/events.lua` | Constantes VPChopEvt — barramento interno |
| `bridge/mdt.lua` | Bridge plugável para MDT (ps-mdt, próprio, etc.) |
| `server/heat.lua` | Cálculo de heat on-demand + callback VIN scratch |
| `server/fence.lua` | Trust, rotação NPC, ordens, entregas, compra de itens |
| `server/progression.lua` | XP, tiers, desbloqueios, persistência |
| `client/fence.lua` | Blip rotativo, ox_target no fence, props de pneu, tyre carry |
| `client/progression.lua` | HUD de XP flutuante, notificações de tier |
| `sql/vp_chopshop_rp.sql` | 4 novas tabelas RP |

### Modificar (existentes)
| Arquivo | O que muda |
|---------|-----------|
| `shared/config.lua` | Adiciona `Config.Fence`, `Config.Progression`, `Config.Ambush.ReferralDropChance` |
| `server/db.lua` | Carrega `vp_chopshop_rp.sql` na inicialização |
| `server/ambush.lua` | Assinatura `VPChopAmbushMaybe(src, netId, plate)` + usa `VPChopHeatGetMultiplier` |
| `server/chop.lua` | Emite `VPChopEvt.PART_CHOPPED`; passa plate ao ambush |
| `server/advanced_chop.lua` | Emite `VPChopEvt.PART_CHOPPED` em cada fase |
| `fxmanifest.lua` | Adiciona novos arquivos; remove server/npc.lua, server/tyres.lua, client/npc.lua, client/tyres.lua |

### Substituir por tombstone (esvaziados)
| Arquivo | Motivo |
|---------|--------|
| `server/npc.lua` | Substituído por server/fence.lua |
| `client/npc.lua` | Substituído por client/fence.lua |
| `server/tyres.lua` | Lógica migrada para server/fence.lua |
| `client/tyres.lua` | Props de pneu migrados para client/fence.lua |

---

## Fase 1 — Fundação (arquivos base, sem lógica de jogo)

### Task 1: SQL — 4 novas tabelas

**Files:**
- Create: `sql/vp_chopshop_rp.sql`
- Modify: `server/db.lua`

- [ ] **1.1 Criar `sql/vp_chopshop_rp.sql`**

```sql
-- vp_chopshop_rp.sql
-- Executar APÓS vp_chopshop.sql (não substitui, apenas adiciona)

CREATE TABLE IF NOT EXISTS vp_chop_vin_scratched (
    plate        VARCHAR(12) PRIMARY KEY,
    scratched_by VARCHAR(50),
    scratched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS vp_chop_fence_trust (
    identifier  VARCHAR(50) PRIMARY KEY,
    trust_level TINYINT     DEFAULT 0,
    trust_xp    INT         DEFAULT 0,
    last_seen   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS vp_chop_fence_orders (
    id             INT AUTO_INCREMENT PRIMARY KEY,
    for_identifier VARCHAR(50) NOT NULL,
    order_data     LONGTEXT,
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    fulfilled_at   TIMESTAMP NULL,
    INDEX idx_identifier (for_identifier)
);

CREATE TABLE IF NOT EXISTS vp_chop_progression (
    identifier        VARCHAR(50) PRIMARY KEY,
    tier              TINYINT     DEFAULT 1,
    xp                INT         DEFAULT 0,
    total_chops       INT         DEFAULT 0,
    last_car_delivery TIMESTAMP   NULL,
    updated_at        TIMESTAMP   DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
```

- [ ] **1.2 Executar o SQL no banco de dados do servidor**

Abrir o cliente MySQL (HeidiSQL, phpMyAdmin, ou CLI) e executar `sql/vp_chopshop_rp.sql` na base do servidor.

- [ ] **1.3 Adicionar criação das tabelas no `server/db.lua`**

Localizar a função `VPChopDbInit` em `server/db.lua`. O `CreateThread` interno tem esta estrutura:
```
MySQL.query.await(benches)
MySQL.query.await(welders)
VPChopDBReady = true   ← as novas queries DEVEM ir antes desta linha
```
Adicionar **antes** de `VPChopDBReady = true` (e após a criação de `vp_chopshop_welders`):

```lua
    -- Tabelas RP (heat, fence, progression)
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS vp_chop_vin_scratched (
            plate        VARCHAR(12) PRIMARY KEY,
            scratched_by VARCHAR(50),
            scratched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS vp_chop_fence_trust (
            identifier  VARCHAR(50) PRIMARY KEY,
            trust_level TINYINT     DEFAULT 0,
            trust_xp    INT         DEFAULT 0,
            last_seen   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS vp_chop_fence_orders (
            id             INT AUTO_INCREMENT PRIMARY KEY,
            for_identifier VARCHAR(50) NOT NULL,
            order_data     LONGTEXT,
            created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            fulfilled_at   TIMESTAMP NULL,
            INDEX idx_identifier (for_identifier)
        )
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS vp_chop_progression (
            identifier        VARCHAR(50) PRIMARY KEY,
            tier              TINYINT     DEFAULT 1,
            xp                INT         DEFAULT 0,
            total_chops       INT         DEFAULT 0,
            last_car_delivery TIMESTAMP   NULL,
            updated_at        TIMESTAMP   DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        )
    ]])
```

- [ ] **1.4 Verificar no console do servidor**

Iniciar o servidor. No console verificar: sem erros `[MySQL]` durante o boot. Tabelas criadas com sucesso (verificar no MySQL: `SHOW TABLES LIKE 'vp_chop_%'`).

---

### Task 2: Event bus + Bridge MDT

**Files:**
- Create: `shared/events.lua`
- Create: `bridge/mdt.lua`

- [ ] **2.1 Criar `shared/events.lua`**

```lua
-- shared/events.lua
-- Barramento de eventos interno. Nenhum módulo chama outro diretamente:
-- publicar com TriggerEvent(VPChopEvt.XXX, ...) / escutar com AddEventHandler.

VPChopEvt = {
    --- Emitido por server/chop.lua e server/advanced_chop.lua após cada peça.
    --- params: src (number), netId (integer), partKey (string), phase (integer 1-4)
    PART_CHOPPED   = 'vp_chopshop:evt:partChopped',

    --- Emitido por server/main.lua após discard bem-sucedido.
    --- params: src (number), netId (integer), plate (string), cash (number)
    CAR_DISCARDED  = 'vp_chopshop:evt:carDiscard',

    --- Emitido por server/fence.lua após entrega de itens ao fence.
    --- params: src (number), items (table), totalValue (number)
    FENCE_DELIVERY = 'vp_chopshop:evt:fenceDelivery',

    --- Emitido por server/heat.lua quando o nível de heat muda de faixa.
    --- params: plate (string), newLevel (string) 'frio'|'morno'|'quente'|'queimando'
    --- Consumido por bridge/mdt.lua para notificar MDT externo.
    HEAT_CHANGED   = 'vp_chopshop:evt:heatChanged',
}
```

- [ ] **2.2 Criar `bridge/mdt.lua`**

```lua
-- bridge/mdt.lua
-- Bridge plugável para integração com qualquer MDT (ps-mdt, shot-spotter, próprio).
-- Para integrar: implementar as 3 funções abaixo com a lógica do seu MDT.
-- Sem implementação: sistema funciona de forma autossuficiente (sem dados externos).

VPChopMDT = {}

--- Retorna true se o veículo com esta placa está marcado como roubado no MDT.
---@param plate string
---@return boolean
function VPChopMDT.IsVehicleStolen(plate)
    -- Exemplo ps-mdt:
    -- return exports['ps-mdt']:isVehicleStolen(plate)
    return false
end

--- Retorna um modificador externo de heat (0.0 = nenhum, 1.0 = máximo).
--- Use para adicionar heat baseado em dados do MDT (ex: veículo marcado BOLO).
---@param plate string
---@return number 0.0..1.0
function VPChopMDT.GetHeatModifier(plate)
    -- Exemplo: veículo roubado = +50% do modificador externo
    -- if VPChopMDT.IsVehicleStolen(plate) then return 1.0 end
    return 0.0
end

--- Notifica o MDT de atividade de desmanche.
---@param plate string
---@param src number|nil  source do jogador (nil se evento do servidor)
---@param action string  'chop_started'|'part_removed'|'vin_scratched'|'heat_escalated'
function VPChopMDT.ReportActivity(plate, src, action)
    -- Exemplo ps-mdt:
    -- exports['ps-mdt']:addReport({ plate=plate, action=action, src=src })
    -- No-op por padrão.
end

-- Escuta mudanças de heat e reporta ao MDT quando escala para quente/queimando.
AddEventHandler(VPChopEvt.HEAT_CHANGED, function(plate, newLevel)
    if newLevel == 'quente' or newLevel == 'queimando' then
        VPChopMDT.ReportActivity(plate, nil, 'heat_escalated')
    end
end)
```

- [ ] **2.3 Verificar no console**

Adicionar temporariamente em `server/main.lua` (topo, após init):
```lua
print('[vp_chopshop] events.lua loaded — VPChopEvt.PART_CHOPPED = ' .. tostring(VPChopEvt and VPChopEvt.PART_CHOPPED))
```
Reiniciar recurso. Console deve mostrar a string do evento. Remover o print após confirmar.

---

### Task 3: Config — novos blocos

**Files:**
- Modify: `shared/config.lua`

- [ ] **3.1 Adicionar `Config.Fence` ao final de `shared/config.lua`**

```lua
--- ─────────────────────────────────────────────────────────────────────────────
--- SISTEMA DE FENCE — NPC rotativo, trust, ordens, venda de itens
--- ─────────────────────────────────────────────────────────────────────────────

Config.Fence = {
    --- Minutos entre cada rotação de local do NPC.
    RotationMinutes     = 45,
    --- Tempo (ms) antes de props de pneu no chão despawnarem.
    TyrePropDespawnMs   = 600000,
    --- Cooldown (min) entre entregas de carro inteiro por jogador (Tier 4).
    WholeCarCooldownMin = 20,
    --- Cash base ao entregar carro inteiro.
    WholeCarBasePayout  = 8000,
    --- Dias sem aparecer antes de perder 1 nível de trust.
    TrustDecayDays      = 7,
    --- XP de trust ganho por entrega concluída.
    XpPerDelivery       = 20,
    --- XP de trust bônus por ordem cumprida no prazo.
    XpOrderBonus        = 80,

    --- Preço base por item (multiplicado por trust_mult, tier_fence_mult, heat_penalty).
    BasePrices = {
        metalscrap    = 80,
        copper        = 150,
        rubber        = 120,
        aluminum      = 130,
        steel         = 100,
        plastic       = 70,
        glass         = 90,
        car_parts     = 400,
        chopshop_tyre = 400,
    },

    --- TrustXpPerLevel[N] = XP acumulado para ATINGIR o nível N.
    --- Guard: nível 0 não tem threshold (acesso via fence_referral item).
    TrustXpPerLevel = { [1]=100, [2]=300, [3]=600, [4]=1000 },

    --- Templates de ordens de encomenda (geradas aleatoriamente para trust ≥ 3).
    --- items = tabela {item=quantidade}, mult = multiplicador de preço, hours = prazo em horas reais.
    OrderTemplates = {
        { items = { metalscrap=20, copper=8,  rubber=5  }, mult=1.4,  hours=6 },
        { items = { car_parts=5,   steel=15             }, mult=1.5,  hours=8 },
        { items = { aluminum=20,   glass=3              }, mult=1.35, hours=4 },
        { items = { copper=12,     plastic=15, rubber=8 }, mult=1.45, hours=5 },
    },

    --- Locais de rotação do NPC fence.
    Locations = {
        { coords=vector4(2339.8,   3146.3,  48.2,  86.2),  scenario='WORLD_HUMAN_CLIPBOARD',    label='Sandy Shores' },
        { coords=vector4(-1072.3, -2673.8,  13.8, 330.0),  scenario='WORLD_HUMAN_STAND_MOBILE', label='LSIA'         },
        { coords=vector4(844.0,   -1016.8,  27.5, 180.0),  scenario='WORLD_HUMAN_CLIPBOARD',    label='La Mesa'      },
        { coords=vector4(-280.0,   6231.5,  31.5, 270.0),  scenario='WORLD_HUMAN_STAND_MOBILE', label='Paleto Bay'   },
    },
}

--- ─────────────────────────────────────────────────────────────────────────────
--- SISTEMA DE PROGRESSÃO — Tiers lineares com desbloqueios
--- ─────────────────────────────────────────────────────────────────────────────

Config.Progression = {
    --- Chance (0.0-1.0) de falha ao fazer VIN scratch em veículo com heat > 75.
    VinFailChanceHot = 0.40,
    --- XP total acumulado necessário por tier (índice = tier).
    TierXp       = { [1]=0, [2]=500, [3]=2000, [4]=5000 },
    --- Multiplicador de velocidade de progresso por tier.
    SpeedMult    = { [1]=1.0, [2]=1.10, [3]=1.20, [4]=1.30 },
    --- Multiplicador de materiais recebidos por tier.
    MaterialMult = { [1]=1.0, [2]=1.05, [3]=1.10, [4]=1.15 },
    --- Multiplicador de preço no fence por tier (aplicado junto com trust_mult).
    FencePriceMult = { [1]=1.0, [2]=1.0, [3]=1.0, [4]=1.10 },
}
```

- [ ] **3.2 Adicionar `ReferralDropChance` ao `Config.Ambush` existente**

Localizar `Config.Ambush = {` em `shared/config.lua`. Antes do `}` de fechamento, adicionar:

```lua
    --- Chance (0.0-1.0) de dropar item fence_referral ao matar ped de emboscada.
    ReferralDropChance = 0.15,
```

- [ ] **3.3 Verificar** — Reiniciar recurso. Console sem erros de sintaxe Lua.

---

## Fase 2 — Sistema de Heat

### Task 4: `server/heat.lua`

**Files:**
- Create: `server/heat.lua`

- [ ] **4.1 Criar `server/heat.lua`**

```lua
-- server/heat.lua
-- Calcula heat de veículo on-demand (sem loop). Heat afeta ambush e preço fence.
-- Expõe: VPChopHeatCalc(plate), VPChopHeatGetMultiplier(plate), VPChopHeatGetLabel(plate)
-- Callback: 'vp_chopshop:vinScratch' — recebe netId, resolve placa server-side.

--- Cache do nível anterior para emitir HEAT_CHANGED só em transições reais.
local LastHeatLevel = {} ---@type table<string, string>

--- Contador de peças removidas por placa — atualizado pelo PART_CHOPPED event.
--- GetAllVehicles() NÃO existe server-side; rastreamos em memória pelo evento.
local PartCountByPlate = {} ---@type table<string, integer>

-- Escuta PART_CHOPPED e incrementa contador por placa.
-- Nota: heat.lua é carregado DEPOIS de events.lua, então VPChopEvt já está disponível.
AddEventHandler(VPChopEvt.PART_CHOPPED, function(src, netId, partKey, phase)
    -- Resolver placa a partir do netId para manter rastreio server-side
    local veh = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        local plate = GetVehicleNumberPlateText(veh):gsub('%s+', '')
        if plate and plate ~= '' then
            PartCountByPlate[plate] = (PartCountByPlate[plate] or 0) + 1
        end
    end
end)

--- Retorna o heat numérico (0-100) de um veículo pela placa.
--- Chamado apenas quando o jogador inicia uma ação — zero overhead.
---@param plate string
---@return integer
function VPChopHeatCalc(plate)
    if not plate or plate == '' then return 0 end

    local heat = 0

    -- Componente 1: modificador MDT externo (0..50)
    local mdtMod = tonumber(VPChopMDT.GetHeatModifier(plate)) or 0.0
    heat = heat + math.floor(mdtMod * 50)

    -- Componente 2: peças removidas (rastreadas em memória via PART_CHOPPED event)
    -- +5 por peça, máx +20.
    local partCount = PartCountByPlate[plate] or 0
    heat = heat + math.min(partCount * 5, 20)

    -- Componente 3: VIN scratch reduz em 60
    local scratched = MySQL.scalar.await(
        'SELECT COUNT(*) FROM vp_chop_vin_scratched WHERE plate = ?', {plate}
    )
    if scratched and scratched > 0 then
        heat = math.max(0, heat - 60)
    end

    return math.min(heat, 100)
end

--- Retorna o rótulo de nível: 'frio' | 'morno' | 'quente' | 'queimando'
---@param plate string
---@return string
function VPChopHeatGetLabel(plate)
    local h = VPChopHeatCalc(plate)
    if h <= 25 then return 'frio'
    elseif h <= 50 then return 'morno'
    elseif h <= 75 then return 'quente'
    else return 'queimando' end
end

--- Retorna multiplicador de chance de ambush baseado no heat.
---@param plate string
---@return number
function VPChopHeatGetMultiplier(plate)
    local label = VPChopHeatGetLabel(plate)
    if label == 'frio'      then return 1.0
    elseif label == 'morno'  then return 1.15
    elseif label == 'quente' then return 1.35
    else return 1.80 end
end

--- Retorna penalidade de preço (0.0 = sem penalidade, 1.0 = preço zero).
--- Usado pelo fence para calcular preço final.
---@param plate string
---@return number  multiplicador: 1.0 | 0.90 | 0.75 | 0.0 (recusa)
function VPChopHeatGetPriceMult(plate)
    local label = VPChopHeatGetLabel(plate)
    if label == 'frio'       then return 1.0
    elseif label == 'morno'  then return 0.90
    elseif label == 'quente' then return 0.75
    else return 0.0 end  -- queimando = fence recusa
end

--- Emite HEAT_CHANGED se o nível mudou desde a última verificação.
---@param plate string
local function notifyHeatChange(plate)
    local newLabel = VPChopHeatGetLabel(plate)
    if LastHeatLevel[plate] ~= newLabel then
        LastHeatLevel[plate] = newLabel
        TriggerEvent(VPChopEvt.HEAT_CHANGED, plate, newLabel)
    end
end

--- Retorna o heat de um veículo e notifica cliente com o nível atual.
--- Chamado por server/main.lua ao iniciar qualquer ação no veículo.
---@param src number
---@param netId integer
---@return string label  'frio'|'morno'|'quente'|'queimando'
function VPChopHeatCheck(src, netId)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return 'frio' end
    local plate = GetVehicleNumberPlateText(veh):gsub('%s+', '')
    notifyHeatChange(plate)
    local label = VPChopHeatGetLabel(plate)
    -- Notificar cliente apenas se morno/quente/queimando
    if label ~= 'frio' then
        TriggerClientEvent('vp_chopshop:client:heatWarning', src, label)
    end
    return label
end

-- ─── Callback: VIN Scratch ────────────────────────────────────────────────────

lib.callback.register('vp_chopshop:vinScratch', function(src, netId)
    if not GetPlayerName(src) then return { ok=false, err='invalid' } end

    -- Validar veículo e proximidade (trust-no-client)
    local veh = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        return { ok=false, err='vehicle' }
    end
    local maxDist = (Config.VehicleNearLiftRadius or 5.0) + 2.0
    if not ValidatePlayerNearVehicle(src, veh, maxDist) then
        return { ok=false, err='range' }
    end

    -- Placa resolvida no servidor (nunca confiamos no cliente)
    local plate = GetVehicleNumberPlateText(veh):gsub('%s+', '')

    -- Verificar tier ≥ 3
    local prog = VPChopGetProgression(src)
    if not prog or prog.tier < 3 then
        return { ok=false, err='tier' }
    end

    -- Verificar e consumir item
    if not exports.ox_inventory:RemoveItem(src, 'vin_kit', 1) then
        return { ok=false, err='no_item' }
    end

    -- Chance de falha em veículo quente
    local heat = VPChopHeatCalc(plate)
    if heat > 75 then
        local failChance = tonumber(Config.Progression and Config.Progression.VinFailChanceHot) or 0.40
        if math.random() < failChance then
            -- Item já consumido — informar falha
            return { ok=false, err='failed_hot' }
        end
    end

    -- Registrar scratch (upsert — idempotente)
    MySQL.query.await(
        'INSERT INTO vp_chop_vin_scratched (plate, scratched_by) VALUES (?,?) '..
        'ON DUPLICATE KEY UPDATE scratched_by=VALUES(scratched_by), scratched_at=NOW()',
        { plate, ServerChopPlayerKey(src) }
    )

    -- Notificar MDT e emitir XP via evento
    VPChopMDT.ReportActivity(plate, src, 'vin_scratched')
    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, 'vin_scratch', 0)

    -- Atualizar cache de nível
    LastHeatLevel[plate] = nil  -- forçar recálculo na próxima ação

    return { ok=true }
end)
```

- [ ] **4.2 Verificar** — Adicionar ao `server/main.lua` temporariamente:
```lua
CreateThread(function()
    Wait(3000)
    print('[heat test] VPChopHeatGetLabel exists: ' .. tostring(type(VPChopHeatGetLabel)))
end)
```
Reiniciar recurso. Console: `[heat test] VPChopHeatGetLabel exists: function`. Remover print.

---

### Task 5: Wiring ambush + chop com heat

**Files:**
- Modify: `server/ambush.lua` (assinatura `VPChopAmbushMaybe`)
- Modify: `server/chop.lua` (emitir evento + passar plate)

- [ ] **5.1 Atualizar assinatura em `server/ambush.lua`**

Localizar `function VPChopAmbushMaybe(src, netId)` e substituir por:

```lua
--- Dispara emboscada baseada no netId e placa do veículo.
--- plate usado para multiplicar chance via sistema de heat.
---@param src number
---@param netId integer
---@param plate string
function VPChopAmbushMaybe(src, netId, plate)
```

Logo após a linha `if not cfg or not cfg.Enable then return end`, adicionar:

```lua
    -- Multiplicador de heat: veículos quentes = mais emboscadas
    local heatMult = (plate and plate ~= '') and VPChopHeatGetMultiplier(plate) or 1.0
```

Localizar onde `cfg.Chance` é usado no cálculo de `chance`. Substituir:
```lua
    local chance = tonumber(cfg.Chance) or 0.07
    if chance < 0.001 or math.random() > chance then return end
```
por:
```lua
    local chance = (tonumber(cfg.Chance) or 0.07) * heatMult
    if chance < 0.001 or math.random() > chance then return end
```

- [ ] **5.2 Atualizar dois pontos em `server/main.lua`**

> **[FIX C-1]** `VPChopAmbushMaybe` é chamado em **dois lugares distintos** em `server/main.lua`:
> - **Localização A** — callback `vp_chopshop:chopPart` (onde `VPChopServerTryPart` é processado): emitir `PART_CHOPPED`
> - **Localização B** — callback `vp_chopshop:maybeAmbush` (linhas 321-323 na versão atual): passar `plate`

**Localização A — dentro do callback `vp_chopshop:chopPart`** (após sucesso de `VPChopServerTryPart`):

```lua
-- Resolver placa server-side (trust-no-client)
local vehForPlate = NetworkGetEntityFromNetworkId(netId)
local plate = (vehForPlate and vehForPlate ~= 0 and DoesEntityExist(vehForPlate))
    and GetVehicleNumberPlateText(vehForPlate):gsub('%s+', '')
    or ''

-- Emitir evento para progression e fence escutarem
TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, partKey, 1)
```

**Localização B — callback `vp_chopshop:maybeAmbush`** (atualmente `VPChopAmbushMaybe(source, netId)`):

```lua
lib.callback.register('vp_chopshop:maybeAmbush', function(source, netId)
    -- Resolver placa para heat multiplier
    local vehForPlate = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    local plate = (vehForPlate and vehForPlate ~= 0 and DoesEntityExist(vehForPlate))
        and GetVehicleNumberPlateText(vehForPlate):gsub('%s+', '')
        or ''
    VPChopAmbushMaybe(source, netId, plate)
    return true
end)
```

- [ ] **5.3 Emitir evento em `server/advanced_chop.lua`**

Para cada fase (chopDoor, chopEngine, chopCarcass), após sucesso, adicionar:

```lua
-- Fase 2 (door/bonnet/boot) → phase = 2
TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, partKey, 2)

-- Fase 3 (engine) → phase = 3
TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, 'adv_engine', 3)

-- Fase 4 (carcass) → phase = 4
TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, 'adv_carcass', 4)
```

- [ ] **5.4 Emitir CAR_DISCARDED em `server/main.lua`**

Localizar o callback `discardVehicle`. Após dar o cash ao jogador com sucesso, adicionar:

```lua
TriggerEvent(VPChopEvt.CAR_DISCARDED, src, netId, plate, payout)
```

> Resolver `plate` com `GetVehicleNumberPlateText(veh):gsub('%s+', '')` antes do discard.

- [ ] **5.5 Verificar** — No jogo, usar jackstand num veículo e desmontar uma peça. No console do servidor verificar: sem erros Lua. Se `Config.Debug = true`, adicionar print temporário no início do handler do evento `VPChopEvt.PART_CHOPPED` para confirmar que dispara.

---

## Fase 3 — Sistema de Progressão

### Task 6: `server/progression.lua`

**Files:**
- Create: `server/progression.lua`

- [ ] **6.1 Criar `server/progression.lua`**

```lua
-- server/progression.lua
-- Gerencia XP e tiers por jogador. Persiste em vp_chop_progression.
-- Expõe: VPChopGetProgression(src), VPChopAddXp(src, amount)
-- Escuta: VPChopEvt.PART_CHOPPED, VPChopEvt.CAR_DISCARDED, VPChopEvt.FENCE_DELIVERY

--- Cache em memória por source (carregado ao conectar, salvo ao ganhar XP)
local ProgressCache = {} ---@type table<number, {tier:integer, xp:integer, total_chops:integer}>

--- XP por ação (configuração local — não exposta ao cliente)
local XP_TABLE = {
    phase1     = 8,
    phase2     = 15,
    phase3     = 40,
    phase4     = 60,
    discard    = 25,
    tyre_sell  = 5,
    order      = 120,
    tyre_mission = 80,
    vin_scratch  = 30,
}

--- Carrega ou cria registro de progressão para um jogador.
---@param src number
---@return {tier:integer, xp:integer, total_chops:integer}
function VPChopGetProgression(src)
    if ProgressCache[src] then return ProgressCache[src] end
    local key = ServerChopPlayerKey(src)
    local row = MySQL.single.await(
        'SELECT tier, xp, total_chops FROM vp_chop_progression WHERE identifier = ?', {key}
    )
    if row then
        ProgressCache[src] = { tier=row.tier, xp=row.xp, total_chops=row.total_chops }
    else
        ProgressCache[src] = { tier=1, xp=0, total_chops=0 }
        MySQL.query.await(
            'INSERT IGNORE INTO vp_chop_progression (identifier, tier, xp, total_chops) VALUES (?,1,0,0)',
            {key}
        )
    end
    return ProgressCache[src]
end

--- Notifica cliente de ganho de XP (texto flutuante discreto).
---@param src number
---@param amount integer
local function notifyXp(src, amount)
    TriggerClientEvent('vp_chopshop:client:xpGained', src, amount)
end

--- Notifica cliente de avanço de tier.
---@param src number
---@param newTier integer
local function notifyTierUp(src, newTier)
    local labels = { [1]='Novato', [2]='Mecânico', [3]='Especialista', [4]='Mestre' }
    local unlocks = {
        [2] = '+10% velocidade · +5% materiais',
        [3] = '+20% velocidade · +10% materiais · VIN scratching · Ordens fence',
        [4] = '+30% velocidade · +15% materiais · Entrega de carro inteiro · +10% fence',
    }
    TriggerClientEvent('vp_chopshop:client:tierUp', src, newTier, labels[newTier] or '?', unlocks[newTier] or '')
end

--- Adiciona XP e faz tier-up se necessário.
---@param src number
---@param amount integer
---@param reason string  chave da XP_TABLE ou string livre para log
function VPChopAddXp(src, amount, reason)
    if not GetPlayerName(src) then return end
    local prog = VPChopGetProgression(src)
    if not prog then return end

    prog.xp = prog.xp + amount
    if reason == 'phase1' or reason == 'phase2' or reason == 'phase3' or reason == 'phase4' then
        prog.total_chops = prog.total_chops + 1
    end

    -- Verificar tier-up
    local tierXp = Config.Progression and Config.Progression.TierXp or { [1]=0, [2]=500, [3]=2000, [4]=5000 }
    local prevTier = prog.tier
    for t = 4, 2, -1 do
        if prog.xp >= (tierXp[t] or math.huge) and prog.tier < t then
            prog.tier = t
        end
    end

    -- Persistir
    local key = ServerChopPlayerKey(src)
    MySQL.query.await(
        'INSERT INTO vp_chop_progression (identifier, tier, xp, total_chops) VALUES (?,?,?,?) '..
        'ON DUPLICATE KEY UPDATE tier=VALUES(tier), xp=VALUES(xp), total_chops=VALUES(total_chops)',
        {key, prog.tier, prog.xp, prog.total_chops}
    )

    notifyXp(src, amount)
    if prog.tier > prevTier then
        notifyTierUp(src, prog.tier)
    end
end

-- ─── Listeners do event bus ───────────────────────────────────────────────────

AddEventHandler(VPChopEvt.PART_CHOPPED, function(src, netId, partKey, phase)
    local reason = 'phase' .. tostring(phase)
    local amount = XP_TABLE[reason] or XP_TABLE.phase1
    -- VIN scratch tem XP próprio
    if partKey == 'vin_scratch' then amount = XP_TABLE.vin_scratch end
    VPChopAddXp(src, amount, reason)
end)

AddEventHandler(VPChopEvt.CAR_DISCARDED, function(src)
    VPChopAddXp(src, XP_TABLE.discard, 'discard')
end)

AddEventHandler(VPChopEvt.FENCE_DELIVERY, function(src, items, totalValue, deliveryType)
    -- deliveryType: 'material' | 'tyre' | 'order' | 'tyre_mission' | 'car'
    local amount = 0
    if deliveryType == 'tyre'         then amount = XP_TABLE.tyre_sell
    elseif deliveryType == 'order'    then amount = XP_TABLE.order
    elseif deliveryType == 'tyre_mission' then amount = XP_TABLE.tyre_mission
    else amount = XP_TABLE.tyre_sell end
    if amount > 0 then VPChopAddXp(src, amount, deliveryType) end
end)

-- ─── Cleanup ao desconectar ───────────────────────────────────────────────────

AddEventHandler('playerDropped', function()
    ProgressCache[source] = nil
end)

-- ─── Callback: consulta de status (usado pelo fence para exibir ao jogador) ──

lib.callback.register('vp_chopshop:getProgression', function(src)
    local prog = VPChopGetProgression(src)
    if not prog then return nil end
    local tierXp = Config.Progression and Config.Progression.TierXp or { [1]=0, [2]=500, [3]=2000, [4]=5000 }
    local nextXp = tierXp[prog.tier + 1]
    return {
        tier       = prog.tier,
        xp         = prog.xp,
        nextXp     = nextXp,
        totalChops = prog.total_chops,
    }
end)
```

- [ ] **6.2 Verificar** — Desmontar peça no jogo. No console checar: sem erros. Verificar no MySQL: `SELECT * FROM vp_chop_progression;` — deve aparecer uma linha com xp > 0.

---

### Task 7: `client/progression.lua`

**Files:**
- Create: `client/progression.lua`

- [ ] **7.1 Criar `client/progression.lua`**

```lua
-- client/progression.lua
-- Recebe eventos de XP e tier-up do servidor e exibe feedback visual.
-- XP: texto flutuante discreto no canto. Tier-up: notificação success.

--- Exibe "+N XP" como texto flutuante no canto superior direito por 2s.
---@param amount integer
local function showXpFloat(amount)
    -- Usa lib.notify com duração curta e sem título (discreto)
    lib.notify({
        description = '+' .. amount .. ' XP',
        type        = 'inform',
        duration    = 2000,
        position    = 'top-right',
    })
end

RegisterNetEvent('vp_chopshop:client:xpGained', function(amount)
    showXpFloat(amount)
end)

RegisterNetEvent('vp_chopshop:client:tierUp', function(newTier, label, unlocks)
    lib.notify({
        title       = 'Tier ' .. newTier .. ' — ' .. label,
        description = unlocks,
        type        = 'success',
        duration    = 8000,
        position    = 'top-right',
    })
end)

RegisterNetEvent('vp_chopshop:client:heatWarning', function(level)
    local msgs = {
        morno     = { text = 'Este carro está morno. Cuidado.', type = 'inform' },
        quente    = { text = 'Este carro está quente. Fence paga menos.', type = 'warning' },
        queimando = { text = 'Carro queimando! Fence não vai tocar nisso.', type = 'error' },
    }
    local m = msgs[level]
    if m then
        lib.notify({ description = m.text, type = m.type, duration = 5000 })
    end
end)
```

- [ ] **7.2 Verificar** — Desmontar peça no jogo. Deve aparecer "+8 XP" no canto superior direito. Sem erros no F8.

---

## Fase 4 — Sistema de Fence

### Task 8: `server/fence.lua`

**Files:**
- Create: `server/fence.lua`

- [ ] **8.1 Criar `server/fence.lua`**

```lua
-- server/fence.lua
-- Fence NPC rotativo: trust, rotação, ordens, compra de itens, entrega de carros.
-- NPCs removidos: server/npc.lua, server/tyres.lua (funcionalidade migrada aqui).
-- Expõe: VPChopFenceGetTrust(src), VPChopFenceCurrentLocation()

-- ─── Estado do fence ──────────────────────────────────────────────────────────
local CurrentLocationIdx = 1  -- índice em Config.Fence.Locations
local FenceNpcNetId      = nil ---@type integer|nil

--- Cache de trust em memória por source
local TrustCache = {} ---@type table<number, {trust_level:integer, trust_xp:integer, last_seen:integer}>

-- ─── Helpers de trust ────────────────────────────────────────────────────────

local function trustMult(level)
    local mults = { [0]=0, [1]=1.0, [2]=1.15, [3]=1.30, [4]=1.50 }
    return mults[level] or 1.0
end

local function loadTrust(src)
    if TrustCache[src] then return TrustCache[src] end
    local key = ServerChopPlayerKey(src)
    local row = MySQL.single.await(
        'SELECT trust_level, trust_xp, UNIX_TIMESTAMP(last_seen) as last_seen FROM vp_chop_fence_trust WHERE identifier = ?',
        {key}
    )
    if row then
        -- Aplicar decay passivo ao carregar
        local daysSince = math.floor((os.time() - (row.last_seen or os.time())) / 86400)
        local decayDays = (Config.Fence and Config.Fence.TrustDecayDays) or 7
        if daysSince >= decayDays and row.trust_level > 0 then
            row.trust_level = math.max(0, row.trust_level - 1)
            MySQL.query.await(
                'UPDATE vp_chop_fence_trust SET trust_level=?, last_seen=NOW() WHERE identifier=?',
                {row.trust_level, key}
            )
        end
        TrustCache[src] = { trust_level=row.trust_level, trust_xp=row.trust_xp, last_seen=row.last_seen or os.time() }
    else
        TrustCache[src] = { trust_level=0, trust_xp=0, last_seen=os.time() }
    end
    return TrustCache[src]
end

local function saveTrust(src)
    local t = TrustCache[src]
    if not t then return end
    local key = ServerChopPlayerKey(src)
    MySQL.query.await(
        'INSERT INTO vp_chop_fence_trust (identifier, trust_level, trust_xp, last_seen) VALUES (?,?,?,NOW()) '..
        'ON DUPLICATE KEY UPDATE trust_level=VALUES(trust_level), trust_xp=VALUES(trust_xp), last_seen=NOW()',
        {key, t.trust_level, t.trust_xp}
    )
end

local function addTrustXp(src, amount)
    local t = loadTrust(src)
    t.trust_xp = t.trust_xp + amount
    -- Verificar avanço de nível
    local xpTable = (Config.Fence and Config.Fence.TrustXpPerLevel) or { [1]=100, [2]=300, [3]=600, [4]=1000 }
    if t.trust_level < 4 then
        local needed = xpTable[t.trust_level + 1]
        if needed and t.trust_xp >= needed then
            t.trust_level = t.trust_level + 1
            TriggerClientEvent('vp_chopshop:client:trustUp', src, t.trust_level)
        end
    end
    saveTrust(src)
end

--- Retorna nível de trust de um jogador (0-4).
---@param src number
---@return integer
function VPChopFenceGetTrust(src)
    return loadTrust(src).trust_level
end

-- ─── Localização atual do fence ──────────────────────────────────────────────

--- Retorna a localização atual do fence.
---@return table  { coords, scenario, label }
function VPChopFenceCurrentLocation()
    local locs = Config.Fence and Config.Fence.Locations
    if not locs or #locs == 0 then return nil end
    return locs[CurrentLocationIdx]
end

--- Rotaciona o fence para o próximo local e notifica jogadores online.
local function rotateFence()
    local locs = Config.Fence and Config.Fence.Locations
    if not locs or #locs < 2 then return end

    -- Escolher próximo sem repetir atual
    local next
    repeat
        next = math.random(1, #locs)
    until next ~= CurrentLocationIdx
    CurrentLocationIdx = next

    local loc = locs[CurrentLocationIdx]

    -- Despenar NPC atual e respawnar no novo local
    if FenceNpcNetId then
        TriggerEvent('vp_chopshop:server:despawnFenceNpc')
    end
    TriggerEvent('vp_chopshop:server:spawnFenceNpc', loc)

    -- Notificar jogadores por nível de trust
    for _, playerId in ipairs(GetPlayers()) do
        local pid = tonumber(playerId)
        if pid and GetPlayerName(pid) then
            local trust = VPChopFenceGetTrust(pid)
            if trust >= 1 and trust <= 1 then
                TriggerClientEvent('vp_chopshop:client:fenceRotated', pid, nil, nil)
            elseif trust >= 2 then
                TriggerClientEvent('vp_chopshop:client:fenceRotated', pid, loc.label, loc.coords)
            end
        end
    end
end

-- Timer de rotação
CreateThread(function()
    while not VPChopDBReady do Wait(500) end
    local rotMs = math.floor(((Config.Fence and Config.Fence.RotationMinutes) or 45) * 60 * 1000)
    while true do
        Wait(rotMs)
        rotateFence()
    end
end)

-- ─── Spawn/despawn do NPC ──────────────────────────────────────────────────────

AddEventHandler('vp_chopshop:server:spawnFenceNpc', function(loc)
    if not loc then return end
    -- [FIX C-3] Wait() só pode ser chamado dentro de CreateThread server-side.
    -- AddEventHandler NÃO é uma coroutine — envolve toda a lógica de spawn num thread.
    CreateThread(function()
        local model = joaat('g_m_m_mexboss_01')
        RequestModel(model)
        local t = GetGameTimer() + 8000
        while not HasModelLoaded(model) and GetGameTimer() < t do Wait(50) end
        if not HasModelLoaded(model) then return end

        local ped = CreatePed(4, model, loc.coords.x, loc.coords.y, loc.coords.z, loc.coords.w, true, true)
        SetModelAsNoLongerNeeded(model)
        if not ped or ped == 0 then return end

        SetEntityAsMissionEntity(ped, true, true)
        FreezeEntityPosition(ped, true)
        SetEntityInvincible(ped, true)
        SetBlockingOfNonTemporaryEvents(ped, true)
        if loc.scenario and loc.scenario ~= '' then
            TaskStartScenarioInPlace(ped, loc.scenario, 0, true)
        end

        FenceNpcNetId = NetworkGetNetworkIdFromEntity(ped)
        -- Notificar todos os clientes para registrar targets
        TriggerClientEvent('vp_chopshop:client:setupFenceNpc', -1, { nwid=FenceNpcNetId, locationIdx=CurrentLocationIdx })
    end)
end)

AddEventHandler('vp_chopshop:server:despawnFenceNpc', function()
    if not FenceNpcNetId then return end
    local ent = NetworkGetEntityFromNetworkId(FenceNpcNetId)
    if ent and ent ~= 0 and DoesEntityExist(ent) then DeleteEntity(ent) end
    TriggerClientEvent('vp_chopshop:client:removeFenceNpc', -1, FenceNpcNetId)
    FenceNpcNetId = nil
end)

-- Spawn inicial ao carregar
CreateThread(function()
    while not VPChopDBReady do Wait(500) end
    Wait(1000)
    local loc = VPChopFenceCurrentLocation()
    if loc then TriggerEvent('vp_chopshop:server:spawnFenceNpc', loc) end
end)

-- ─── Callbacks de interação ───────────────────────────────────────────────────

-- Apresentar-se (trust 0 → 1)
lib.callback.register('vp_chopshop:fence:introduce', function(src)
    if not GetPlayerName(src) then return { ok=false } end
    local trust = VPChopFenceGetTrust(src)
    if trust > 0 then return { ok=false, err='already_known' } end

    if not exports.ox_inventory:RemoveItem(src, 'fence_referral', 1) then
        return { ok=false, err='no_referral' }
    end

    local t = loadTrust(src)
    t.trust_level = 1
    t.trust_xp    = 0
    saveTrust(src)
    TrustCache[src] = t

    return { ok=true }
end)

-- Vender materiais do inventário
lib.callback.register('vp_chopshop:fence:sellItems', function(src, itemList)
    if not GetPlayerName(src) then return { ok=false } end
    local trust = VPChopFenceGetTrust(src)
    if trust < 1 then return { ok=false, err='no_trust' } end

    -- Validar proximidade ao fence
    local loc = VPChopFenceCurrentLocation()
    if not loc then return { ok=false, err='no_fence' } end
    if not ValidatePlayerNearPoint(src, vector3(loc.coords.x, loc.coords.y, loc.coords.z), 5.0) then
        return { ok=false, err='range' }
    end

    local prog      = VPChopGetProgression(src)
    local tierMult  = (Config.Progression and Config.Progression.FencePriceMult and Config.Progression.FencePriceMult[prog.tier]) or 1.0
    local trustM    = trustMult(trust)
    local basePrices = (Config.Fence and Config.Fence.BasePrices) or {}

    local totalValue = 0
    local soldItems  = {}

    -- itemList: { {name=string, amount=integer}, ... } — validado server-side
    for _, entry in ipairs(itemList or {}) do
        local item   = type(entry.name) == 'string' and entry.name or nil
        local amount = math.floor(tonumber(entry.amount) or 0)
        if item and amount > 0 and basePrices[item] then
            -- Verificar e remover item
            if exports.ox_inventory:RemoveItem(src, item, amount) then
                local price = math.floor(basePrices[item] * trustM * tierMult)
                local earned = price * amount
                totalValue = totalValue + earned
                soldItems[#soldItems+1] = { name=item, amount=amount, earned=earned }
            end
        end
    end

    if totalValue <= 0 then return { ok=false, err='nothing_sold' } end

    -- Pagar jogador
    BridgeAddCash(src, totalValue, 'fence_sale')

    -- XP de trust
    addTrustXp(src, (Config.Fence and Config.Fence.XpPerDelivery) or 20)

    -- Emitir evento para progressão
    TriggerEvent(VPChopEvt.FENCE_DELIVERY, src, soldItems, totalValue, 'material')

    return { ok=true, total=totalValue }
end)

-- Vender pneus (truck OU inventário)
lib.callback.register('vp_chopshop:fence:sellTyres', function(src, source_type, truckNetId)
    if not GetPlayerName(src) then return { ok=false } end
    local trust = VPChopFenceGetTrust(src)
    if trust < 1 then return { ok=false, err='no_trust' } end

    local loc = VPChopFenceCurrentLocation()
    if not ValidatePlayerNearPoint(src, vector3(loc.coords.x, loc.coords.y, loc.coords.z), 5.0) then
        return { ok=false, err='range' }
    end

    local prog     = VPChopGetProgression(src)
    local tierMult = (Config.Progression and Config.Progression.FencePriceMult and Config.Progression.FencePriceMult[prog.tier]) or 1.0
    local trustM   = trustMult(trust)
    local unitPrice = math.floor(((Config.Fence and Config.Fence.BasePrices and Config.Fence.BasePrices.chopshop_tyre) or 400) * trustM * tierMult)

    local count = 0

    if source_type == 'truck' and truckNetId then
        -- Truck: usar state bag chopTyreCount (validado via netId)
        local truck = NetworkGetEntityFromNetworkId(tonumber(truckNetId) or 0)
        if truck and truck ~= 0 and DoesEntityExist(truck) then
            count = math.floor(tonumber(Entity(truck).state.chopTyreCount) or 0)
            if count > 0 then
                Entity(truck).state:set('chopTyreCount', 0, true)
            end
        end
    else
        -- Inventário: chopshop_tyre items
        count = exports.ox_inventory:GetItemCount(src, 'chopshop_tyre') or 0
        if count > 0 then
            exports.ox_inventory:RemoveItem(src, 'chopshop_tyre', count)
        end
    end

    if count <= 0 then return { ok=false, err='no_tyres' } end

    local total = unitPrice * count
    BridgeAddCash(src, total, 'fence_tyres')
    addTrustXp(src, math.floor(((Config.Fence and Config.Fence.XpPerDelivery) or 20) * 0.5) * count)
    TriggerEvent(VPChopEvt.FENCE_DELIVERY, src, {}, total, 'tyre')

    return { ok=true, count=count, total=total }
end)

-- Entregar carro inteiro (Tier 4 + trust 4)
lib.callback.register('vp_chopshop:fence:deliverCar', function(src, netId)
    if not GetPlayerName(src) then return { ok=false } end
    local trust = VPChopFenceGetTrust(src)
    if trust < 4 then return { ok=false, err='no_trust' } end

    local prog = VPChopGetProgression(src)
    if prog.tier < 4 then return { ok=false, err='tier' } end

    -- Verificar cooldown
    local key = ServerChopPlayerKey(src)
    local row = MySQL.single.await('SELECT UNIX_TIMESTAMP(last_car_delivery) as lcd FROM vp_chop_progression WHERE identifier=?', {key})
    local cooldownSec = ((Config.Fence and Config.Fence.WholeCarCooldownMin) or 20) * 60
    if row and row.lcd and (os.time() - row.lcd) < cooldownSec then
        return { ok=false, err='cooldown', wait=cooldownSec - (os.time() - row.lcd) }
    end

    local veh = NetworkGetEntityFromNetworkId(tonumber(netId) or 0)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return { ok=false, err='vehicle' } end
    if not ValidatePlayerNearVehicle(src, veh, 6.0) then return { ok=false, err='range' } end

    local plate = GetVehicleNumberPlateText(veh):gsub('%s+', '')

    -- Verificar heat
    if VPChopHeatGetLabel(plate) == 'queimando' then
        return { ok=false, err='too_hot' }
    end

    local heatMult  = VPChopHeatGetPriceMult(plate)
    local tierMult  = (Config.Progression and Config.Progression.FencePriceMult and Config.Progression.FencePriceMult[prog.tier]) or 1.10
    local trustM    = trustMult(trust)
    local base      = (Config.Fence and Config.Fence.WholeCarBasePayout) or 8000
    local payout    = math.floor(base * trustM * tierMult * heatMult)

    -- Deletar veículo e pagar
    DeleteEntity(veh)
    BridgeAddCash(src, payout, 'fence_car')

    -- Atualizar cooldown
    MySQL.query.await('UPDATE vp_chop_progression SET last_car_delivery=NOW() WHERE identifier=?', {key})

    addTrustXp(src, (Config.Fence and Config.Fence.XpOrderBonus) or 80)
    TriggerEvent(VPChopEvt.FENCE_DELIVERY, src, {}, payout, 'car')

    return { ok=true, payout=payout }
end)

-- Retornar nível de trust do jogador (usado pelo cliente para montar targets)
lib.callback.register('vp_chopshop:fence:getTrust', function(src)
    if not GetPlayerName(src) then return 0 end
    return VPChopFenceGetTrust(src)
end)

-- Comprar bancada via fence (valida proximidade ao fence rotativo, não ao NPC legado)
-- Substitui vp_chopshop:npcBuy para o contexto do fence (server/main.lua ainda registra
-- vp_chopshop:npcBuy mas valida contra Config.NPC.Coords — coordenada estática incorreta).
lib.callback.register('vp_chopshop:fence:buyBench', function(src)
    if not GetPlayerName(src) then return { ok=false, err='invalid' } end
    local shop = Config.NPC and Config.NPC.Shop
    if not shop or not shop.Enable then return { ok=false, err='disabled' } end

    local loc = VPChopFenceCurrentLocation()
    if not loc then return { ok=false, err='no_fence' } end
    if not ValidatePlayerNearPoint(src, vector3(loc.coords.x, loc.coords.y, loc.coords.z), 5.0) then
        return { ok=false, err='distance' }
    end

    local price = math.floor(tonumber(shop.BenchPrice) or 0)
    if not BridgeRemoveCash(src, price, 'npc_buy_bench') then
        return { ok=false, err='money' }
    end

    local itemName = 'chopshop_bench'
    if not exports.ox_inventory:AddItem(src, itemName, 1) then
        BridgeAddCash(src, price, 'npc_buy_bench_refund')
        return { ok=false, err='inventory' }
    end

    return { ok=true }
end)

-- Pegar ordem ativa (trust ≥ 3)
lib.callback.register('vp_chopshop:fence:getOrder', function(src)
    if not GetPlayerName(src) then return nil end
    if VPChopFenceGetTrust(src) < 3 then return nil end

    local key = ServerChopPlayerKey(src)
    local row = MySQL.single.await(
        'SELECT id, order_data FROM vp_chop_fence_orders WHERE for_identifier=? AND fulfilled_at IS NULL ORDER BY created_at DESC LIMIT 1',
        {key}
    )
    if not row then
        -- Gerar nova ordem
        local templates = (Config.Fence and Config.Fence.OrderTemplates) or {}
        if #templates == 0 then return nil end
        local tmpl = templates[math.random(1, #templates)]
        local deadline = os.time() + math.floor(tmpl.hours * 3600)
        local orderData = json.encode({ items=tmpl.items, mult=tmpl.mult, deadline=deadline })
        local id = MySQL.insert.await(
            'INSERT INTO vp_chop_fence_orders (for_identifier, order_data) VALUES (?,?)',
            {key, orderData}
        )
        return { id=id, items=tmpl.items, mult=tmpl.mult, deadline=deadline }
    end

    local data = json.decode(row.order_data)
    -- Verificar expiração
    if data.deadline and os.time() > data.deadline then
        MySQL.query.await('UPDATE vp_chop_fence_orders SET fulfilled_at=NOW() WHERE id=?', {row.id})
        return nil  -- expirou — nova ordem na próxima chamada
    end
    return { id=row.id, items=data.items, mult=data.mult, deadline=data.deadline }
end)

-- Entregar ordem
lib.callback.register('vp_chopshop:fence:fulfillOrder', function(src, orderId)
    if not GetPlayerName(src) then return { ok=false } end
    if VPChopFenceGetTrust(src) < 3 then return { ok=false, err='no_trust' } end

    local key = ServerChopPlayerKey(src)
    local row = MySQL.single.await(
        'SELECT id, order_data FROM vp_chop_fence_orders WHERE id=? AND for_identifier=? AND fulfilled_at IS NULL',
        {orderId, key}
    )
    if not row then return { ok=false, err='no_order' } end

    local data = json.decode(row.order_data)
    if os.time() > (data.deadline or 0) then
        MySQL.query.await('UPDATE vp_chop_fence_orders SET fulfilled_at=NOW() WHERE id=?', {row.id})
        return { ok=false, err='expired' }
    end

    -- Verificar e remover todos os itens primeiro
    for item, amount in pairs(data.items) do
        if (exports.ox_inventory:GetItemCount(src, item) or 0) < amount then
            return { ok=false, err='missing_item', item=item, need=amount }
        end
    end
    for item, amount in pairs(data.items) do
        exports.ox_inventory:RemoveItem(src, item, amount)
    end

    -- Calcular recompensa
    local basePrices = (Config.Fence and Config.Fence.BasePrices) or {}
    local prog    = VPChopGetProgression(src)
    local tierM   = (Config.Progression and Config.Progression.FencePriceMult and Config.Progression.FencePriceMult[prog.tier]) or 1.0
    local trustM  = trustMult(VPChopFenceGetTrust(src))
    local baseVal = 0
    for item, amount in pairs(data.items) do
        baseVal = baseVal + ((basePrices[item] or 100) * amount)
    end
    local total = math.floor(baseVal * (data.mult or 1.0) * trustM * tierM)

    BridgeAddCash(src, total, 'fence_order')
    MySQL.query.await('UPDATE vp_chop_fence_orders SET fulfilled_at=NOW() WHERE id=?', {row.id})

    addTrustXp(src, (Config.Fence and Config.Fence.XpOrderBonus) or 80)
    TriggerEvent(VPChopEvt.FENCE_DELIVERY, src, data.items, total, 'order')

    return { ok=true, total=total }
end)

-- Drop de fence_referral: lógica implementada diretamente em ambushSpawnOne em server/ambush.lua
-- (Task 8.2 adiciona a thread de verificação de morte do ped lá)

-- ─── Cleanup ao desconectar ───────────────────────────────────────────────────
AddEventHandler('playerDropped', function()
    TrustCache[source] = nil
end)
```

- [ ] **8.2 Adicionar drop de `fence_referral` em `server/ambush.lua`**

No bloco onde o ped hostil é criado (função `ambushSpawnOne`), após `rememberPeds(src, {ped})`, adicionar:

```lua
    -- Chance de dropar fence_referral ao matar o ped de emboscada
    local dropChance = tonumber(cfg.ReferralDropChance) or 0.0
    if dropChance > 0 and math.random() <= dropChance then
        -- Guardar para dropar quando o ped morrer (via thread de verificação)
        CreateThread(function()
            local despawnMs = tonumber(cfg.DespawnMs) or 180000
            local elapsed   = 0
            while elapsed < despawnMs do
                Wait(2000)
                elapsed = elapsed + 2000
                if ped and ped ~= 0 and DoesEntityExist(ped) and IsEntityDead(ped) then
                    exports.ox_inventory:AddItem(src, 'fence_referral', 1)
                    lib.notify({ id='referral_drop_'..src, title='Algo caiu', description='Um papel dobrado no bolso do cara...', type='inform', duration=5000 })
                    -- Notifica via TriggerClientEvent para o jogador
                    TriggerClientEvent('ox_lib:notify', src, {
                        title='Dica', description='Encontrou algo no bolso do cara. Verifique o inventário.', type='inform'
                    })
                    return
                end
            end
        end)
    end
```

- [ ] **8.3 Verificar** — Reiniciar recurso. Matar um ped de ambush. Com `Config.Ambush.ReferralDropChance = 1.0` temporariamente, verificar se `fence_referral` aparece no inventário. Retornar para `0.15`.

---

### Task 9: `client/fence.lua`

**Files:**
- Create: `client/fence.lua`

- [ ] **9.1 Criar `client/fence.lua`**

```lua
-- client/fence.lua
-- Blip rotativo, targets ox_target no NPC fence, props de pneu no chão,
-- sistema de carry de pneu no ombro e carregamento em pickup truck.

local FenceNpcEnt    = nil ---@type integer|nil
local FenceBlip      = nil ---@type integer|nil
local CurrentLocIdx  = 1
local TyrePropList   = {} ---@type table<integer, {prop:integer, timer:integer}>  [propHandle] = dados
local CarryingTyre   = nil ---@type {prop:integer}|nil

-- ─── Blip ─────────────────────────────────────────────────────────────────────

local function removeFenceBlip()
    if FenceBlip and DoesBlipExist(FenceBlip) then RemoveBlip(FenceBlip) end
    FenceBlip = nil
end

local function setFenceBlip(coords, precise)
    removeFenceBlip()
    local bx, by = coords.x, coords.y
    if not precise then
        -- Offset aleatório ~150m para trust 1-2
        bx = bx + math.random(-150, 150)
        by = by + math.random(-150, 150)
    end
    FenceBlip = AddBlipForCoord(bx, by, coords.z)
    SetBlipSprite(FenceBlip, precise and 140 or 161)
    SetBlipColour(FenceBlip, precise and 1 or 4)
    SetBlipScale(FenceBlip, 0.8)
    SetBlipAsShortRange(FenceBlip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(precise and 'Fence' or '?')
    EndTextCommandSetBlipName(FenceBlip)
end

-- ─── Setup NPC ───────────────────────────────────────────────────────────────

RegisterNetEvent('vp_chopshop:client:setupFenceNpc', function(data)
    if not data or not data.nwid then return end
    CurrentLocIdx = data.locationIdx or 1

    CreateThread(function()
        local ent, tries = 0, 0
        while (not ent or ent == 0 or not DoesEntityExist(ent)) and tries < 40 do
            Wait(100)
            ent = NetworkGetEntityFromNetworkId(data.nwid)
            tries = tries + 1
        end
        if not ent or ent == 0 or not DoesEntityExist(ent) then return end

        FenceNpcEnt = ent
        FreezeEntityPosition(ent, true)
        SetEntityInvincible(ent, true)
        SetBlockingOfNonTemporaryEvents(ent, true)

        -- Buscar nível de trust (callback separado — getProgression NÃO retorna trust)
        local ok, trust = pcall(lib.callback.await, 'vp_chopshop:fence:getTrust', false)
        trust = (ok and type(trust) == 'number') and trust or 0

        -- Blip baseado em trust
        local locs = Config.Fence and Config.Fence.Locations
        if locs and locs[CurrentLocIdx] then
            local c = locs[CurrentLocIdx].coords
            if trust <= 0 then
                removeFenceBlip()
            elseif trust <= 2 then
                setFenceBlip(c, false)
            else
                setFenceBlip(c, true)
            end
        end

        -- Montar targets
        local options = {}

        if trust == 0 then
            options[#options+1] = {
                name='vp_fence_introduce', label='Apresentar-se',
                icon='fa-solid fa-handshake', distance=2.5,
                onSelect=function()
                    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:fence:introduce', false)
                    if cbOk and res and res.ok then
                        lib.notify({ description='O cara acenou. Você foi apresentado.', type='success' })
                    else
                        lib.notify({ description='Você não tem nada pra mostrar.', type='error' })
                    end
                end,
            }
        end

        if trust >= 1 then
            options[#options+1] = {
                name='vp_fence_sell_items', label='Vender materiais',
                icon='fa-solid fa-boxes-stacked', distance=2.5,
                onSelect=function() openSellMenu() end,
            }
            options[#options+1] = {
                name='vp_fence_sell_tyres', label='Vender pneus',
                icon='fa-solid fa-circle-dot', distance=2.5,
                onSelect=function() sellTyres() end,
            }
            options[#options+1] = {
                name='vp_fence_tyre_contract', label='Contrato de pneus',
                icon='fa-solid fa-file-contract', distance=2.5,
                onSelect=function() TyreMissionStart() end,
            }
        end

        if trust >= 2 then
            options[#options+1] = {
                name='vp_fence_hot_job', label='Trabalho quente',
                icon='fa-solid fa-skull-crossbones', distance=2.5,
                onSelect=function() tryNpcMission() end,
            }
            options[#options+1] = {
                name='vp_fence_buy_bench', label='Comprar bancada',
                icon='fa-solid fa-toolbox', distance=2.5,
                onSelect=function() tryNpcBuy('bench') end,
            }
            options[#options+1] = {
                name='vp_fence_status', label='Ver status',
                icon='fa-solid fa-chart-line', distance=2.5,
                onSelect=function() showStatus() end,
            }
        end

        if trust >= 3 then
            options[#options+1] = {
                name='vp_fence_order', label='Ver encomenda',
                icon='fa-solid fa-clipboard-list', distance=2.5,
                onSelect=function() showOrder() end,
            }
            options[#options+1] = {
                name='vp_fence_fulfill', label='Entregar encomenda',
                icon='fa-solid fa-box-open', distance=2.5,
                onSelect=function() fulfillOrder() end,
            }
        end

        if trust >= 4 then
            options[#options+1] = {
                name='vp_fence_deliver_car', label='Entregar veículo',
                icon='fa-solid fa-car-burst', distance=2.5,
                onSelect=function() deliverCar() end,
            }
        end

        exports.ox_target:addLocalEntity(FenceNpcEnt, options)
    end)
end)

RegisterNetEvent('vp_chopshop:client:removeFenceNpc', function(nwid)
    if FenceNpcEnt then
        exports.ox_target:removeLocalEntity(FenceNpcEnt)
        FenceNpcEnt = nil
    end
    removeFenceBlip()
end)

RegisterNetEvent('vp_chopshop:client:fenceRotated', function(label, coords)
    if label and coords then
        lib.notify({ description='Contato mudou para: ' .. label, type='inform', duration=6000 })
        setFenceBlip(coords, true)
    else
        lib.notify({ description='O contato mudou de local.', type='inform', duration=5000 })
    end
end)

RegisterNetEvent('vp_chopshop:client:trustUp', function(newLevel)
    local labels = { [1]='Conhecido', [2]='Confiável', [3]='Parceiro', [4]='Sócio' }
    lib.notify({
        title='Fence — ' .. (labels[newLevel] or 'Nível ' .. newLevel),
        description='Você ganhou a confiança do contato.',
        type='success', duration=7000,
    })
end)

-- ─── Funções migradas de client/npc.lua (tombstone) ─────────────────────────
-- [FIX M-2] tryNpcMission e tryNpcBuy eram locais em client/npc.lua.
-- Como client/npc.lua vira tombstone, devem ser definidas aqui como globals.

function tryNpcMission()
    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:npcAcceptMission', false)
    if not cbOk then res = nil end
    if res and res.ok then
        VPChopNotify(L('notify_mission_accepted'), 'inform', 9000)
    elseif res and res.err == 'distance' then
        VPChopNotify(L('notify_npc_too_far'), 'error')
    elseif res and res.err == 'cooldown' and res.wait then
        VPChopNotify(L('notify_mission_cooldown_fmt', res.wait), 'error')
    elseif res and res.err == 'active' then
        VPChopNotify(L('notify_mission_active'), 'error')
    elseif res and res.err == 'ambush_off' then
        VPChopNotify(L('notify_mission_ambush_off'), 'error')
    elseif res and res.err == 'disabled' then
        VPChopNotify(L('notify_mission_disabled'), 'error')
    else
        VPChopNotify(L('notify_generic_error'), 'error')
    end
end

-- [FIX M-2] Usa vp_chopshop:fence:buyBench em vez de vp_chopshop:npcBuy.
-- O callback legado npcBuy valida contra Config.NPC.Coords (coords fixas) —
-- incompatível com o fence rotativo. O novo callback valida contra a localização atual do fence.
function tryNpcBuy(kind)
    if kind ~= 'bench' then return end  -- apenas bench implementado no fence
    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:fence:buyBench', false)
    if not cbOk then res = nil end
    if res and res.ok then
        VPChopNotify(L('notify_buy_ok'), 'success')
    elseif res and res.err == 'money' then
        VPChopNotify(L('notify_buy_fail_money'), 'error')
    elseif res and res.err == 'distance' then
        VPChopNotify(L('notify_npc_too_far'), 'error')
    else
        VPChopNotify(
            (res and res.err) and L('notify_chop_failed_fmt', VPChopLocaleErr(res.err)) or L('notify_generic_error'),
            'error'
        )
    end
end

-- ─── Menus de interação ───────────────────────────────────────────────────────

function openSellMenu()
    local sellable = {}
    local prices   = Config.Fence and Config.Fence.BasePrices or {}
    for item, _ in pairs(prices) do
        local count = exports.ox_inventory:Search('count', item)
        if count and count > 0 then
            sellable[#sellable+1] = { name=item, amount=count, unitPrice=prices[item] }
        end
    end
    if #sellable == 0 then
        lib.notify({ description='Nada para vender.', type='error' }); return
    end
    -- Montar context menu com todos os itens vendáveis
    local opts = {}
    for _, s in ipairs(sellable) do
        opts[#opts+1] = {
            title    = s.name .. ' ×' .. s.amount,
            metadata = {{ label='Preço base', value='$'..s.unitPrice..' un.' }},
            onSelect = function()
                local ok, res = pcall(lib.callback.await, 'vp_chopshop:fence:sellItems', false, {{name=s.name, amount=s.amount}})
                if ok and res and res.ok then
                    lib.notify({ description='Vendido por $'..res.total, type='success' })
                else
                    lib.notify({ description='Falha na venda.', type='error' })
                end
            end,
        }
    end
    lib.registerContext({ id='vp_fence_sell', title='Vender Materiais', options=opts })
    lib.showContext('vp_fence_sell')
end

function sellTyres()
    -- Detectar pickup truck próxima com pneus carregados
    local ped = PlayerPedId()
    local pcoords = GetEntityCoords(ped)
    local truckNetId = nil
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(veh) then
            local dist = #(pcoords - GetEntityCoords(veh))
            if dist < 8.0 and Entity(veh).state.chopTyreCount and Entity(veh).state.chopTyreCount > 0 then
                truckNetId = NetworkGetNetworkIdFromEntity(veh)
                break
            end
        end
    end

    local srcType = truckNetId and 'truck' or 'inventory'
    local ok, res = pcall(lib.callback.await, 'vp_chopshop:fence:sellTyres', false, srcType, truckNetId)
    if ok and res and res.ok then
        lib.notify({ description=res.count..' pneu(s) vendido(s) por $'..res.total, type='success' })
    else
        lib.notify({ description=(res and res.err == 'no_tyres') and 'Nenhum pneu disponível.' or 'Falha.', type='error' })
    end
end

function showStatus()
    local ok, prog = pcall(lib.callback.await, 'vp_chopshop:getProgression', false)
    if not ok or not prog then lib.notify({ description='Erro ao carregar status.', type='error' }); return end
    local tierLabels = { [1]='Novato', [2]='Mecânico', [3]='Especialista', [4]='Mestre' }
    lib.registerContext({
        id='vp_fence_status', title='Seu Status',
        options={{
            title='Perfil',
            readOnly=true,
            metadata={
                { label='Tier',    value=tierLabels[prog.tier] or prog.tier },
                { label='XP',      value=prog.xp .. (prog.nextXp and ' / '..prog.nextXp or ' (máx)') },
                { label='Chapas',  value=prog.totalChops },
            }
        }}
    })
    lib.showContext('vp_fence_status')
end

function showOrder()
    local ok, order = pcall(lib.callback.await, 'vp_chopshop:fence:getOrder', false)
    if not ok or not order then
        lib.notify({ description='Nenhuma encomenda disponível.', type='inform' }); return
    end
    local remaining = math.max(0, order.deadline - os.time())
    local hours = math.floor(remaining / 3600)
    local mins  = math.floor((remaining % 3600) / 60)
    local itemStr = ''
    for item, amount in pairs(order.items) do
        itemStr = itemStr .. amount .. '× ' .. item .. '  '
    end
    lib.registerContext({
        id='vp_fence_order_view', title='Encomenda Ativa',
        options={{
            title='Detalhes',
            readOnly=true,
            metadata={
                { label='Itens',    value=itemStr },
                { label='Bônus',    value='×'..order.mult },
                { label='Prazo',    value=hours..'h '..mins..'min' },
            }
        }}
    })
    lib.showContext('vp_fence_order_view')
end

function fulfillOrder()
    local ok, order = pcall(lib.callback.await, 'vp_chopshop:fence:getOrder', false)
    if not ok or not order then
        lib.notify({ description='Nenhuma encomenda ativa.', type='error' }); return
    end
    local ok2, res = pcall(lib.callback.await, 'vp_chopshop:fence:fulfillOrder', false, order.id)
    if ok2 and res and res.ok then
        lib.notify({ description='Encomenda entregue! $'..res.total, type='success', duration=7000 })
    elseif res and res.err == 'missing_item' then
        lib.notify({ description='Faltam '..res.need..'× '..res.item, type='error' })
    elseif res and res.err == 'expired' then
        lib.notify({ description='Encomenda expirou.', type='error' })
    else
        lib.notify({ description='Falha na entrega.', type='error' })
    end
end

function deliverCar()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then
        lib.notify({ description='Entre no veículo que quer entregar.', type='error' }); return
    end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    local ok, res = pcall(lib.callback.await, 'vp_chopshop:fence:deliverCar', false, netId)
    if ok and res and res.ok then
        lib.notify({ description='Veículo entregue por $'..res.payout, type='success', duration=7000 })
    elseif res and res.err == 'too_hot' then
        lib.notify({ description='Veículo quente demais. Fence recusa.', type='error' })
    elseif res and res.err == 'cooldown' then
        local mins = math.ceil(res.wait / 60)
        lib.notify({ description='Aguarde '..mins..' min.', type='error' })
    else
        lib.notify({ description='Fence não quer isso agora.', type='error' })
    end
end

-- ─── Props de pneu no chão ────────────────────────────────────────────────────

--- Spawna prop de pneu no chão na posição indicada.
---@param position vector3
---@return integer  propHandle
function VPChopSpawnTyreProp(position)
    local model = `prop_cs_wheel_01`
    RequestModel(model)
    local t = GetGameTimer() + 4000
    while not HasModelLoaded(model) and GetGameTimer() < t do Wait(10) end
    if not HasModelLoaded(model) then return 0 end

    local prop = CreateObjectNoOffset(model, position.x, position.y, position.z, false, false, false)
    SetModelAsNoLongerNeeded(model)
    if not prop or prop == 0 then return 0 end

    PlaceObjectOnGroundProperly(prop)

    local despawnMs = (Config.Fence and Config.Fence.TyrePropDespawnMs) or 600000
    local spawnTime = GetGameTimer()

    -- Target no prop
    exports.ox_target:addLocalEntity(prop, {
        {
            name     = 'vp_tyre_pick_' .. tostring(prop),
            label    = 'Pegar pneu',
            icon     = 'fa-solid fa-hand',
            distance = 2.0,
            onSelect = function() VPChopPickUpTyre(prop) end,
        },
        {
            name     = 'vp_tyre_load_' .. tostring(prop),
            label    = 'Carregar no truck',
            icon     = 'fa-solid fa-truck',
            distance = 2.0,
            canInteract = function()
                local ppos = GetEntityCoords(PlayerPedId())
                for _, veh in ipairs(GetGamePool('CVehicle')) do
                    if DoesEntityExist(veh) and #(ppos - GetEntityCoords(veh)) < 5.0 then
                        local model = GetEntityModel(veh)
                        for _, m in ipairs(Config.TyreSelling and Config.TyreSelling.PickupTruckModels or {}) do
                            if model == joaat(m) then return true end
                        end
                    end
                end
                return false
            end,
            onSelect = function() VPChopLoadTyreInTruck(prop) end,
        },
    })

    TyrePropList[prop] = { prop=prop, timer=spawnTime }

    -- Auto-despawn
    CreateThread(function()
        Wait(despawnMs)
        VPChopRemoveTyreProp(prop)
    end)

    return prop
end

--- Remove prop de pneu do mundo.
---@param propHandle integer
function VPChopRemoveTyreProp(propHandle)
    if not TyrePropList[propHandle] then return end
    exports.ox_target:removeLocalEntity(propHandle)
    if DoesEntityExist(propHandle) then DeleteObject(propHandle) end
    TyrePropList[propHandle] = nil
end

--- Pega pneu do chão e carrega no ombro.
---@param propHandle integer
function VPChopPickUpTyre(propHandle)
    if CarryingTyre then
        lib.notify({ description='Já está carregando um pneu.', type='error' }); return
    end
    VPChopRemoveTyreProp(propHandle)

    local model = `prop_cs_wheel_01`
    RequestModel(model)
    local t = GetGameTimer() + 3000
    while not HasModelLoaded(model) and GetGameTimer() < t do Wait(10) end
    if not HasModelLoaded(model) then return end

    local ped  = PlayerPedId()
    local prop = CreateObjectNoOffset(model, 0, 0, 0, false, false, false)
    SetModelAsNoLongerNeeded(model)
    AttachEntityToEntity(prop, ped, GetPedBoneIndex(ped, 60309),
        0.15, 0.05, 0.0,  -- offset
        0.0, 90.0, 0.0,   -- rotation
        true, true, false, true, 1, true)

    CarryingTyre = { prop=prop }
    lib.notify({ description='Carregando pneu. [E] = carregar no truck · [X] = largar', type='inform', duration=4000 })

    -- Thread para E/X enquanto carrega
    CreateThread(function()
        while CarryingTyre do
            Wait(0)
            -- X = largar no chão
            if IsControlJustReleased(0, 73) then  -- X
                VPChopDropTyre()
                return
            end
            -- E = carregar no truck próximo
            if IsControlJustReleased(0, 38) then  -- E
                local ppos = GetEntityCoords(ped)
                for _, veh in ipairs(GetGamePool('CVehicle')) do
                    if DoesEntityExist(veh) and #(ppos - GetEntityCoords(veh)) < 4.0 then
                        local vm = GetEntityModel(veh)
                        for _, m in ipairs(Config.TyreSelling and Config.TyreSelling.PickupTruckModels or {}) do
                            if vm == joaat(m) then
                                VPChopLoadTyreInTruckFromCarry(veh)
                                return
                            end
                        end
                    end
                end
            end
        end
    end)
end

--- Larga pneu no chão.
function VPChopDropTyre()
    if not CarryingTyre then return end
    local prop = CarryingTyre.prop
    CarryingTyre = nil
    if DoesEntityExist(prop) then
        DetachEntity(prop, true, true)
        local pos = GetEntityCoords(PlayerPedId())
        VPChopSpawnTyreProp(pos)
        DeleteObject(prop)
    end
end

--- Carrega pneu no truck (a partir de prop no chão).
---@param propHandle integer
function VPChopLoadTyreInTruck(propHandle)
    local ped   = PlayerPedId()
    local ppos  = GetEntityCoords(ped)
    local truck = nil
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(veh) and #(ppos - GetEntityCoords(veh)) < 5.0 then
            local vm = GetEntityModel(veh)
            for _, m in ipairs(Config.TyreSelling and Config.TyreSelling.PickupTruckModels or {}) do
                if vm == joaat(m) then truck = veh; break end
            end
        end
        if truck then break end
    end
    if not truck then lib.notify({ description='Sem pickup perto.', type='error' }); return end

    local max = (Config.TyreSelling and Config.TyreSelling.MaxTyresInTruck) or 4
    local cur = math.floor(tonumber(Entity(truck).state.chopTyreCount) or 0)
    if cur >= max then lib.notify({ description='Truck cheio!', type='error' }); return end

    VPChopRemoveTyreProp(propHandle)
    Entity(truck).state:set('chopTyreCount', cur + 1, true)
    lib.notify({ description='Pneu carregado ('.. (cur+1) ..'/'..max..').', type='success', duration=2500 })
end

--- Carrega pneu no truck a partir do carry.
---@param truck integer
function VPChopLoadTyreInTruckFromCarry(truck)
    if not CarryingTyre then return end
    local max = (Config.TyreSelling and Config.TyreSelling.MaxTyresInTruck) or 4
    local cur = math.floor(tonumber(Entity(truck).state.chopTyreCount) or 0)
    if cur >= max then lib.notify({ description='Truck cheio!', type='error' }); return end

    local prop = CarryingTyre.prop
    CarryingTyre = nil
    if DoesEntityExist(prop) then DeleteObject(prop) end

    Entity(truck).state:set('chopTyreCount', cur + 1, true)
    lib.notify({ description='Pneu carregado ('.. (cur+1) ..'/'..max..').', type='success', duration=2500 })
end

-- ─── Cleanup ──────────────────────────────────────────────────────────────────

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    removeFenceBlip()
    if FenceNpcEnt then exports.ox_target:removeLocalEntity(FenceNpcEnt) end
    if CarryingTyre and DoesEntityExist(CarryingTyre.prop) then DeleteObject(CarryingTyre.prop) end
    for handle, _ in pairs(TyrePropList) do
        exports.ox_target:removeLocalEntity(handle)
        if DoesEntityExist(handle) then DeleteObject(handle) end
    end
    TyrePropList = {}
end)
```

- [ ] **9.2 Conectar spawn de prop de pneu ao sistema de jackstand**

Em `client/main.lua`, localizar onde pneus são removidos e itens concedidos. Após a remoção bem-sucedida de um pneu (callback `chopTyre`), em vez de apenas dar `chopshop_tyre` ao inventário, chamar:

```lua
-- Spawnar prop de pneu na posição da roda
local wheelPos = GetWorldPositionOfEntityBone(veh, GetEntityBoneIndexByName(veh, wheelBone))
VPChopSpawnTyreProp(wheelPos)
```

> Identificar o nome correto da variável do veículo e a posição da roda no código existente de `client/main.lua`.

- [ ] **9.3 Verificar** — No jogo: remover pneu com jackstand. Prop deve aparecer no chão. Interagir via ox_target: "Pegar pneu" → carrega no ombro. X = larga no chão. Entrar em pickup → E = carrega no truck. State bag `chopTyreCount` visível no console com `Entity(truck).state.chopTyreCount`.

---

## Fase 5 — Tombstones e fxmanifest

### Task 10: Tombstone de arquivos substituídos

**Files:**
- Modify: `server/npc.lua`
- Modify: `client/npc.lua`
- Modify: `server/tyres.lua`
- Modify: `client/tyres.lua`

- [ ] **10.1 Substituir `server/npc.lua` por tombstone**

> **Nota**: Os callbacks `vp_chopshop:npcBuy` e `vp_chopshop:npcAcceptMission` NÃO estão em
> `server/npc.lua` — eles estão em `server/main.lua` (linhas ~326-358). Tombstoning `server/npc.lua`
> apenas remove o spawn do NPC estático. Os callbacks legados permanecem ativos mas o contexto de
> `tryNpcBuy` foi migrado para `vp_chopshop:fence:buyBench` (validado contra fence rotativo).

```lua
-- server/npc.lua
-- [REMOVED] NPC foreman substituído pelo fence rotativo.
-- Ver server/fence.lua para toda a lógica de NPC criminal.
-- NOTA: vp_chopshop:npcBuy e vp_chopshop:npcAcceptMission ainda existem em server/main.lua
-- como legado — não são usados pelo novo sistema fence mas não causam problemas se presentes.
```

- [ ] **10.2 Substituir `client/npc.lua` por tombstone**

```lua
-- client/npc.lua
-- [REMOVED] NPC foreman substituído pelo fence rotativo.
-- Ver client/fence.lua para blip, targets e toda a UI do fence.
```

- [ ] **10.3 Substituir `server/tyres.lua` por tombstone**

```lua
-- server/tyres.lua
-- [REMOVED] Lógica de venda e missões de pneus migrada para server/fence.lua.
```

- [ ] **10.4 Substituir `client/tyres.lua` por tombstone**

```lua
-- client/tyres.lua
-- [REMOVED] Props de pneu e UI de missões migrados para client/fence.lua.
-- Funções: VPChopSpawnTyreProp, VPChopPickUpTyre, VPChopDropTyre — ver client/fence.lua.
```

---

### Task 11: `fxmanifest.lua` — registrar novos arquivos

**Files:**
- Modify: `fxmanifest.lua`

- [ ] **11.1 Atualizar `shared_scripts` — adicionar `events.lua`**

```lua
shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
    'shared/locale.lua',
    'shared/chop_parts.lua',
    'shared/events.lua',    -- ← novo: barramento de eventos
}
```

- [ ] **11.2 Atualizar `server_scripts` — adicionar novos, reordenar**

```lua
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/server_framework.lua',
    'bridge/server_inventory.lua',
    'bridge/mdt.lua',           -- ← novo: bridge MDT (após framework)
    'server/db.lua',
    'server/validate.lua',
    'server/cooldown.lua',
    'server/discord.lua',
    'server/heat.lua',          -- ← novo: antes de ambush e chop
    'server/chop.lua',
    'server/bench.lua',
    'server/npc.lua',           -- tombstone (mantido para evitar erro de arquivo ausente)
    'server/ambush.lua',
    'server/tyres.lua',         -- tombstone
    'server/advanced_chop.lua',
    'server/progression.lua',   -- ← novo: após advanced_chop (escuta eventos)
    'server/fence.lua',         -- ← novo: após progression (usa VPChopGetProgression)
    'server/main.lua',
}
```

- [ ] **11.3 Atualizar `client_scripts` — adicionar novos**

```lua
client_scripts {
    'bridge/client_notify.lua',
    'client/placement.lua',
    'client/lifts.lua',
    'client/bench.lua',
    'client/welder.lua',
    'client/npc.lua',           -- tombstone
    'client/tyres.lua',         -- tombstone
    'client/progression.lua',   -- ← novo
    'client/fence.lua',         -- ← novo (após progression)
    'client/main.lua',
}
```

- [ ] **11.4 Verificar** — Reiniciar recurso. Console sem erros de carregamento. Todos os arquivos carregados na ordem correta.

---

## Fase 6 — Itens no ox_inventory

### Task 12: Registrar novos itens

**Files:**
- Modify: `installation/ox_items_snippet.txt` (documentação)
- Modify: `ox_inventory/data/items.lua` (no servidor)

- [ ] **12.1 Adicionar itens em `ox_inventory/data/items.lua` do servidor**

```lua
['fence_referral'] = {
    label  = 'Cartão de Apresentação',
    weight = 10,
    stack  = true,
    close  = true,
    description = 'Um cartão amassado com um número riscado. Alguém importante te indicou.',
},
['vin_kit'] = {
    label  = 'Kit de Raspagem de VIN',
    weight = 300,
    stack  = true,
    close  = true,
    description = 'Ferramentas para apagar o número do chassi. Ilegal. Uso exclusivo de especialistas.',
},
```

> `chopshop_tyre` já existe (ver `installation/ox_items_snippet.txt` existente). Verificar se `fence_referral` e `vin_kit` ainda não estão cadastrados antes de adicionar.

- [ ] **12.2 Verificar** — No jogo: `/give [id] fence_referral 1` → item deve aparecer no inventário com label correto.

---

## Fase 7 — Verificação Final

### Task 13: Checklist de integração completa

- [ ] **13.1 Teste de heat básico**
  - Usar jackstand num veículo qualquer
  - Desmontar 4+ peças
  - Console servidor: verificar que `VPChopHeatCalc` não gera erros
  - Notificação de "carro morno/quente" deve aparecer

- [ ] **13.2 Teste de fence — fluxo completo**
  - Verificar que NPC spawnou (blip no mapa)
  - Com trust 0: target "Apresentar-se" visível, sem outros targets
  - Usar `fence_referral`: trust vai para 1
  - Reiniciar com trust 1: targets de venda aparecem
  - Vender metalscrap: cash creditado, XP ganho

- [ ] **13.3 Teste de progressão**
  - Verificar no MySQL: `SELECT * FROM vp_chop_progression;`
  - XP cresce com cada peça
  - Ao atingir 500 XP: notificação "Mecânico" aparece

- [ ] **13.4 Teste de pneus**
  - Remover pneu com jackstand → prop aparece no chão
  - "Pegar pneu" → carrega no ombro
  - X = larga no chão (novo prop spawna)
  - E perto de pickup = carrega no truck (`chopTyreCount = 1`)
  - Ir ao fence → "Vender pneus" → cash creditado

- [ ] **13.5 Teste de rotação do fence**
  - Temporariamente: `Config.Fence.RotationMinutes = 0.1` (6 segundos)
  - Aguardar: NPC deve mudar de local, blip atualizado
  - Restaurar valor original

- [ ] **13.6 Teste de VIN scratch (Tier 3)**
  - Avançar para Tier 3 (via MySQL: `UPDATE vp_chop_progression SET xp=2000, tier=3 WHERE identifier='...'`)
  - Dar `vin_kit` via `/give`
  - Usar jackstand → target "Raspar VIN" deve aparecer
  - Concluir → MySQL: `SELECT * FROM vp_chop_vin_scratched;`

- [ ] **13.7 Cleanup — remover prints de debug**
  - Remover todos os `print('[vp_chopshop]...')` adicionados durante desenvolvimento
  - Restaurar `Config.Debug = false`
  - Restaurar `Config.Fence.RotationMinutes` para valor correto
  - Restaurar `Config.Ambush.ReferralDropChance = 0.15`

---

## Dependências de implementação

```
Task 1 (SQL)
    ↓
Task 2 (events + MDT bridge)
    ↓
Task 3 (Config)
    ↓
Task 4 (heat.lua) ──────────────────────┐
    ↓                                   │
Task 5 (wire ambush + chop events)      │ requer VPChopHeatGetMultiplier
    ↓                                   │
Task 6 (server/progression.lua)         │
    ↓                                   │
Task 7 (client/progression.lua)         │
    ↓                                   │
Task 8 (server/fence.lua) ──────────────┘ requer VPChopGetProgression + VPChopHeatGetLabel
    ↓
Task 9 (client/fence.lua)
    ↓
Task 10 (tombstones)
    ↓
Task 11 (fxmanifest)
    ↓
Task 12 (itens ox_inventory)
    ↓
Task 13 (verificação final)
```
