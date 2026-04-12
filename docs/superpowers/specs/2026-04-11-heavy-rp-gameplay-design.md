# vp_chopshop — Heavy RP Gameplay Design

**Data:** 2026-04-11
**Status:** Aprovado
**Pilares:** A (Risco/Heat) · C (Economia/Fence) · D (Progressão)

---

## 1. Visão Geral

Expansão do sistema de desmanche com três pilares interligados via barramento de eventos interno (event-driven). Nenhum módulo chama outro diretamente — todos publicam e escutam eventos padronizados.

### Princípios
- **Zero overhead**: heat calculado on-demand, não em loop
- **Trust-no-client**: preços, heat e progressão calculados 100% no servidor
- **Plugável**: MDT bridge permite integrar qualquer sistema policial existente ou futuro
- **NPC único**: todos os NPCs criminais consolidados no fence rotativo

---

## 2. Arquitetura

### Novos arquivos

```
vp_chopshop/
├── shared/
│   └── events.lua                  — constantes VPChopEvt (barramento interno)
├── bridge/
│   └── mdt.lua                     — bridge plugável para qualquer MDT
├── server/
│   ├── heat.lua                    — heat por veículo, callback VIN scratch
│   ├── fence.lua                   — NPC rotativo, trust, ordens, entregas
│   └── progression.lua             — XP, tiers, desbloqueios
├── client/
│   ├── fence.lua                   — blip rotativo, targets, props de pneu
│   └── progression.lua             — HUD de XP, notificações de tier
└── sql/
    └── vp_chopshop_rp.sql          — 4 novas tabelas
```

### Barramento de eventos (`shared/events.lua`)

```lua
VPChopEvt = {
    PART_CHOPPED   = 'vp_chopshop:evt:partChopped',   -- src, netId, partKey, phase
    CAR_DISCARDED  = 'vp_chopshop:evt:carDiscard',    -- src, netId, plate, cash
    FENCE_DELIVERY = 'vp_chopshop:evt:fenceDelivery', -- src, items, totalValue
    -- Consumido por bridge/mdt.lua: chama VPChopMDT.ReportActivity em transições de nível
    HEAT_CHANGED   = 'vp_chopshop:evt:heatChanged',   -- plate, newLevel
}
```

Cada módulo usa `TriggerEvent` para emitir e `AddEventHandler` para escutar. Acoplamento zero entre módulos.

`HEAT_CHANGED` é escutado por `bridge/mdt.lua`, que chama `VPChopMDT.ReportActivity` nas transições de nível (ex: Frio→Morno, Morno→Quente).

---

## 3. Bridge MDT (`bridge/mdt.lua`)

Interface com 3 funções padronizadas. Implementar para integrar qualquer MDT:

```lua
function VPChopMDT.IsVehicleStolen(plate)
    -- retorna true/false
    -- default sem MDT: false
end

function VPChopMDT.GetHeatModifier(plate)
    -- retorna 0.0..1.0 (multiplicador externo de heat)
    -- default sem MDT: 0.0
end

function VPChopMDT.ReportActivity(plate, src, action)
    -- action: 'chop_started' | 'part_removed' | 'vin_scratched' | 'heat_escalated'
    -- default sem MDT: no-op
end

-- Consumidor do HEAT_CHANGED:
AddEventHandler(VPChopEvt.HEAT_CHANGED, function(plate, newLevel)
    if newLevel == 'quente' or newLevel == 'queimando' then
        VPChopMDT.ReportActivity(plate, nil, 'heat_escalated')
    end
end)
```

Compatível com ps-mdt, shot-spotter ou MDT próprio. Sem MDT: sistema funciona de forma autossuficiente.

---

## 4. Sistema de Heat

### Cálculo (on-demand, sem loop)

```
heat = base_time + mdt_modifier + parts_modifier − vin_reduction
```

| Fonte | Contribuição |
|-------|-------------|
| Tempo desde spawn do veículo | +0..30 (gradual, máx 30 min) |
| `VPChopMDT.GetHeatModifier` | +0..50 (veículo reportado roubado) |
| Peças removidas sem VIN scratch | +5 por peça, máx +20 |
| VIN scratch aplicado | −60 |

### Efeitos

| Nível | Faixa | Ambush mult | Fence preço | Fence aceita |
|-------|-------|-------------|-------------|--------------|
| Frio | 0–25 | ×1.0 | base | Sim |
| Morno | 26–50 | ×1.15 | −10% | Sim |
| Quente | 51–75 | ×1.35 | −25% | Sim |
| Queimando | 76–100 | ×1.80 | — | Não |

### Integração com ambush (wiring explícito)

`VPChopAmbushMaybe` recebe parâmetro adicional `plate`:

```lua
-- server/ambush.lua
function VPChopAmbushMaybe(src, netId, plate)
    local cfg = Config.Ambush
    if not cfg or not cfg.Enable then return end
    local heatMult = VPChopHeatGetMultiplier(plate)   -- exposta por server/heat.lua
    local effectiveChance = (tonumber(cfg.Chance) or 0.07) * heatMult
    -- ... resto da lógica existente usando effectiveChance
end
```

`VPChopHeatGetMultiplier(plate)` é uma função global exposta por `server/heat.lua`:

```lua
-- server/heat.lua
function VPChopHeatGetMultiplier(plate)
    local heat = VPChopHeatCalc(plate)  -- função interna de cálculo
    if heat <= 25 then return 1.0
    elseif heat <= 50 then return 1.15
    elseif heat <= 75 then return 1.35
    else return 1.80 end
end
```

Call site em `server/chop.lua` (onde `VPChopAmbushMaybe` já é chamado) passa a placa:

```lua
local plate = GetVehicleNumberPlateText(NetworkGetEntityFromNetworkId(netId))
VPChopAmbushMaybe(src, netId, plate)
```

### VIN Scratch — callback server

O cliente executa a animação e, ao concluir, chama o callback. A placa é resolvida **server-side** via `netId` — nunca enviada pelo cliente:

```lua
-- server/heat.lua (callback registrado)
lib.callback.register('vp_chopshop:vinScratch', function(src, netId)
    -- 1. Validar source
    if not GetPlayerName(src) then return { ok=false, err='invalid' } end

    -- 2. Validar proximidade (trust-no-client)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        return { ok=false, err='vehicle' }
    end
    if not ValidatePlayerNearVehicle(src, veh, (Config.VehicleNearLiftRadius or 5.0) + 2.0) then
        return { ok=false, err='range' }
    end

    -- 3. Resolver placa server-side
    local plate = GetVehicleNumberPlateText(veh)

    -- 4. Verificar tier ≥ 3
    local progression = VPChopGetProgression(src)  -- exposta por server/progression.lua
    if progression.tier < 3 then return { ok=false, err='tier' } end

    -- 5. Consumir item
    if not exports.ox_inventory:RemoveItem(src, 'vin_kit', 1) then
        return { ok=false, err='no_item' }
    end

    -- 6. Chance de falha em veículo quente
    local heat = VPChopHeatCalc(plate)
    if heat > 75 and math.random() < (Config.Progression.VinFailChanceHot or 0.40) then
        return { ok=false, err='failed' }  -- item já consumido
    end

    -- 7. Registrar scratch
    MySQL.query.await('INSERT INTO vp_chop_vin_scratched (plate, scratched_by) VALUES (?,?) '..
        'ON DUPLICATE KEY UPDATE scratched_by=VALUES(scratched_by), scratched_at=NOW()', {plate, ServerChopPlayerKey(src)})

    -- 8. Notificar MDT e emitir XP
    VPChopMDT.ReportActivity(plate, src, 'vin_scratched')
    TriggerEvent(VPChopEvt.PART_CHOPPED, src, netId, 'vin_scratch', 0)  -- progression escuta para +XP

    return { ok=true }
end)
```

### Feedback ao jogador

- **Frio**: silencioso
- **Morno**: ícone termômetro amarelo no HUD
- **Quente**: notificação `warn` — *"Este carro está quente. Cuidado."*
- **Queimando**: notificação `error` — *"Fence não vai tocar nisso."*

### SQL

```sql
CREATE TABLE IF NOT EXISTS vp_chop_vin_scratched (
    plate        VARCHAR(12) PRIMARY KEY,
    scratched_by VARCHAR(50),
    scratched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

---

## 5. Sistema de Fence

### NPC único — consolidação

Todos os NPCs criminais do recurso são eliminados e substituídos pelo fence rotativo:

| NPC removido | Funcionalidade migrada para o fence |
|--------------|-------------------------------------|
| `Config.NPC` (foreman) | Info, loja de equipamentos, missão de ambush |
| `Config.TyreSelling` NPC | Compra de pneus (truck e inventário) |
| `Config.TyreMission` NPC | Contratos de roubo de pneus |

### Rotação de locais

4+ locais configuráveis em `Config.Fence.Locations[]`. Troca a cada `Config.Fence.RotationMinutes` (padrão: 45 min). Próximo local escolhido aleatoriamente sem repetir o atual.

**Locais padrão:**

| # | Local | Contexto RP |
|---|-------|-------------|
| 1 | Sandy Shores — galpão mecânico | Área rural |
| 2 | LSIA — estacionamento sul | Zona industrial |
| 3 | La Mesa — doca fluvial | Armazém às margens do rio |
| 4 | Paleto Bay — serraria | Periferia norte |

### Trust — 5 níveis

| Nível | Rótulo | Preço fence | Desbloqueios |
|-------|--------|-------------|--------------|
| 0 | Desconhecido | — | Sem acesso. Fence ignora. |
| 1 | Conhecido | base | Venda de materiais e pneus. Contratos de pneus. Notificado de rotação (sem local). |
| 2 | Confiável | +15% | Recebe área da rotação. Missão de ambush. Loja de equipamentos. |
| 3 | Parceiro | +30% | Ordens de encomenda. |
| 4 | Sócio | +50% | Ordens premium. Entrega de carro inteiro (Tier 4). |

### Progressão de trust (XP → nível)

`trust_xp` acumula com entregas e missões. Avanço de nível quando:

```lua
-- trust_xp >= Config.Fence.TrustXpPerLevel[trust_level + 1]
-- Exemplo: trust 1 → 2 quando trust_xp >= TrustXpPerLevel[2] (100 XP)
-- TrustXpPerLevel = { [0]=0, [1]=100, [2]=300, [3]=600, [4]=1000 }
-- (índice = nível de destino)
```

Decay passivo: se `os.time() - last_seen > TrustDecayDays * 86400`, trust_level -= 1 (verificado ao conectar).

### Notificação de rotação por trust

| Trust | Notificação ao trocar local |
|-------|-----------------------------|
| 0 | Nenhuma |
| 1 | *"O contato mudou de local."* (sem revelar onde) |
| 2–4 | Nome/área do novo local |

### Introdução (trust 0 → 1)

Item **`fence_referral`** consumível. Obtido via:
- Drop de peds de ambush (chance em `Config.Ambush.ReferralDropChance`, padrão: `0.15`)
- Configurável via loja de itens ilegais do servidor
- Troca entre jogadores (cria RP de indicação)

### Ganho e perda de trust XP

```
+xp por entrega concluída (Config.Fence.XpPerDelivery, padrão 20)
+bônus por ordem cumprida no prazo (Config.Fence.XpOrderBonus, padrão 80)
−decay: TrustDecayDays dias sem aparecer = −1 nível (ao conectar)
−penalidade: entregar com heat > 75 = −50 trust_xp
```

### Targets do fence (ox_target, dist. 2.5m)

```
[trust 0]  → "Apresentar-se"        consume fence_referral
[trust ≥1] → "Vender materiais"     itens do inventário
[trust ≥1] → "Vender pneus"         truck OU inventário (auto-detecta)
[trust ≥1] → "Contrato de pneus"    missão de roubo de pneus
[trust ≥2] → "Trabalho quente"      missão de ambush
[trust ≥2] → "Comprar equipamento"  bancada / soldadora por cash
[trust ≥2] → "Ver status"           tier, XP, próximo tier, trust atual
[trust ≥3] → "Ver encomenda"        ordem ativa com prazo restante
[trust ≥3] → "Entregar encomenda"   entrega itens da ordem ativa
[trust 4]  → "Entregar veículo"     carro inteiro (requer Tier 4)
```

### Ordens de encomenda (trust ≥ 3, por jogador)

- 1 ordem ativa **por jogador** por vez (coluna `for_identifier` na tabela)
- Gerada aleatoriamente de `Config.Fence.OrderTemplates`
- Prazo em horas reais (`os.time()`)
- Recompensa: valor base × multiplicador de ordem × trust_mult
- Expirada sem penalidade; nova ordem após cooldown

### Preço final (servidor)

```
preço = BasePrices[item] × trust_mult × tier_fence_mult × heat_penalty × order_bonus
```

Onde `tier_fence_mult = Config.Progression.FencePriceMult[player_tier]`.
Nenhum valor vem do cliente.

### Blip no mapa (client)

| Trust | Blip |
|-------|------|
| 0 | Sem blip |
| 1–2 | Blip "?" com coordenada aleatoriamente deslocada (~150m). Offset calculado a cada rotação: `offsetX = math.random(-150, 150)`, `offsetY = math.random(-150, 150)` aplicados às coords reais |
| 3–4 | Blip preciso no local atual |

### SQL

```sql
CREATE TABLE IF NOT EXISTS vp_chop_fence_trust (
    identifier  VARCHAR(50) PRIMARY KEY,
    trust_level TINYINT     DEFAULT 0,
    trust_xp    INT         DEFAULT 0,
    last_seen   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS vp_chop_fence_orders (
    id             INT AUTO_INCREMENT PRIMARY KEY,
    for_identifier VARCHAR(50) NOT NULL,   -- dono da ordem (por jogador)
    order_data     LONGTEXT,               -- JSON: items, reward_mult, deadline (os.time)
    created_at     TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    fulfilled_at   TIMESTAMP NULL
);
```

---

## 6. Mecânica de Pneus (Props Físicos)

### Ciclo de vida

```
Removido da roda
      ↓
Prop no chão (próximo à roda removida)
      ↓              ↓
 Pegar pneu      Deixar no chão
 (ombro)         (terminar trabalho primeiro)
      ↓              ↓
  Carregar na pickup truck (target no pneu ou tecla E perto da truck)
      ↓
  Dirigir até o fence
      ↓
  "Vender pneus do truck"
```

### Estados do pneu

| Estado | Implementação |
|--------|--------------|
| **No chão** | Prop `prop_cs_wheel_01` na posição da roda. ox_target: "Pegar" e "Carregar no truck" |
| **No ombro** | Prop attachado ao player (sistema `VPChopCarryingPart`). E perto de truck = carrega. X = solta no chão |
| **Na truck** | Prop deletado. State bag `chopTyreCount` na pickup incrementa |
| **Vendido** | State bag zerada. Cash creditado |

### Dois caminhos de venda aceitos pelo fence

| Caminho | Quando |
|---------|--------|
| **Truck → fence** | Pickup com `chopTyreCount > 0` no raio do fence |
| **Inventário → fence** | `chopshop_tyre` no inventário (missões de roubo ou sem truck) |

### Persistência

Props são client-side. Timeout: `Config.Fence.TyrePropDespawnMs` (padrão: 600.000ms). Desconexão = props desaparecem.

---

## 7. Sistema de Progressão

### Tiers

| Tier | Rótulo | XP total | Desbloqueios |
|------|--------|----------|--------------|
| 1 | Novato | 0 | Acesso básico |
| 2 | Mecânico | 500 | +10% velocidade, +5% materiais |
| 3 | Especialista | 2.000 | +20% velocidade, +10% materiais, VIN scratching, ordens fence |
| 4 | Mestre | 5.000 | +30% velocidade, +15% materiais, entrega carro inteiro, +10% preço fence |

### Fontes de XP

| Ação | XP |
|------|----|
| Peça Fase 1 | +8 |
| Peça Fase 2 | +15 |
| Motor (Fase 3) | +40 |
| Carcaça (Fase 4) | +60 |
| Veículo descartado | +25 |
| Pneu vendido ao fence | +5 |
| Ordem cumprida | +120 |
| Missão de pneus completa | +80 |
| VIN scratch bem-sucedido | +30 |

`server/progression.lua` escuta `VPChopEvt.PART_CHOPPED` e `VPChopEvt.FENCE_DELIVERY` para creditar XP automaticamente.

### VIN Scratching (Tier 3)

- Item `vin_kit` consumível
- Progress bar ~3 min com animação de abrir capô (client-side)
- Ao concluir: `lib.callback.await('vp_chopshop:vinScratch', false, netId)` — ver §4
- Reduz heat em −60 (server calcula)
- Falha se heat > 75: `Config.Progression.VinFailChanceHot` (padrão: 40%) — item consumido mesmo assim

### Entrega de carro inteiro (Tier 4)

- Jogador dirige veículo até raio do fence
- Target no veículo: *"Entregar veículo"*
- Cooldown por jogador: `Config.Fence.WholeCarCooldownMin` (padrão: 20 min), armazenado em `vp_chop_progression.last_car_delivery`
- Recusa se heat > 75
- Payout: `Config.Fence.WholeCarBasePayout` × trust_mult × heat_penalty
- Veículo deletado pelo servidor após entrega

### Feedback ao jogador

| Evento | Feedback |
|--------|----------|
| XP ganho | Texto flutuante discreto (não interrompe fluxo) |
| Avanço de tier | Notificação `success` + lista de desbloqueios |
| Ver status | Target "Ver status" no fence |

### SQL

```sql
CREATE TABLE IF NOT EXISTS vp_chop_progression (
    identifier       VARCHAR(50) PRIMARY KEY,
    tier             TINYINT     DEFAULT 1,
    xp               INT         DEFAULT 0,
    total_chops      INT         DEFAULT 0,
    last_car_delivery TIMESTAMP  NULL,        -- cooldown de entrega carro inteiro
    updated_at       TIMESTAMP   DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
```

---

## 8. SQL Consolidado (`sql/vp_chopshop_rp.sql`)

```sql
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
    fulfilled_at   TIMESTAMP NULL
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

---

## 9. Config — Novos blocos (`shared/config.lua`)

```lua
Config.Fence = {
    RotationMinutes     = 45,
    TyrePropDespawnMs   = 600000,
    WholeCarCooldownMin = 20,
    WholeCarBasePayout  = 8000,
    TrustDecayDays      = 7,
    XpPerDelivery       = 20,
    XpOrderBonus        = 80,
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
    -- TrustXpPerLevel[N] = XP necessário para ATINGIR o nível N (nível 0 não tem threshold)
    -- Guard: se trust_level == 0, checar TrustXpPerLevel[1] para avançar para 1
    TrustXpPerLevel = { [1]=100, [2]=300, [3]=600, [4]=1000 },
    OrderTemplates = {
        { items = { metalscrap=20, copper=8, rubber=5 }, mult=1.4, hours=6 },
        { items = { car_parts=5, steel=15 },             mult=1.5, hours=8 },
        { items = { aluminum=20, glass=3 },              mult=1.35, hours=4 },
    },
    Locations = {
        { coords=vector4(2339.8,  3146.3, 48.2, 86.2),   scenario='WORLD_HUMAN_CLIPBOARD',    label='Sandy Shores' },
        { coords=vector4(-1072.3, -2673.8, 13.8, 330.0), scenario='WORLD_HUMAN_STAND_MOBILE', label='LSIA' },
        { coords=vector4(844.0,   -1016.8, 27.5, 180.0), scenario='WORLD_HUMAN_CLIPBOARD',    label='La Mesa' },
        { coords=vector4(-280.0,   6231.5, 31.5, 270.0), scenario='WORLD_HUMAN_STAND_MOBILE', label='Paleto Bay' },
    },
}

Config.Progression = {
    VinFailChanceHot = 0.40,
    TierXp           = { 0, 500, 2000, 5000 },  -- XP total por tier (índice = tier)
    SpeedMult        = { 1.0, 1.10, 1.20, 1.30 },
    MaterialMult     = { 1.0, 1.05, 1.10, 1.15 },
    FencePriceMult   = { 1.0, 1.0,  1.0,  1.10 },  -- aplicado em: preço × FencePriceMult[tier]
}

-- Adição ao Config.Ambush existente:
-- ReferralDropChance = 0.15   -- chance de fence_referral dropar de peds de emboscada
```

---

## 10. Arquivos removidos / modificados

| Arquivo | Ação |
|---------|------|
| `Config.NPC` | Substituído por `Config.Fence` |
| `Config.TyreSelling` | Funcionalidade migrada para `client/fence.lua` + `server/fence.lua` |
| `Config.TyreMission` | Migrado para targets do fence |
| `Config.Ambush` | Adicionado `ReferralDropChance`. Assinatura `VPChopAmbushMaybe` recebe `plate` |
| `server/npc.lua` | Substituído por `server/fence.lua` |
| `client/npc.lua` | Substituído por `client/fence.lua` |
| `client/tyres.lua` | Props de pneu migrados para `client/fence.lua` |
| `server/tyres.lua` | Lógica migrada para `server/fence.lua` |
| `server/ambush.lua` | Assinatura `VPChopAmbushMaybe(src, netId, plate)` — adiciona parâmetro `plate` |
| `server/chop.lua` | Call site de `VPChopAmbushMaybe` passa placa resolvida server-side |
| `client/jackstand.lua` | Mantido como está (arquivo orphan, não está no fxmanifest — sem conflito) |

---

## 11. Fluxo completo de uma sessão RP

```
1. Jogador recebe fence_referral (drop de ambush ou troca com outro jogador)
2. Encontra o fence via blip impreciso (~150m offset)
3. Apresenta-se → trust 0 → 1
4. Usa jackstand num veículo frio → Fase 1 → pneus ficam no chão como props
5. Completa Fases 2, 3, 4 com ferramentas (saw, screwdriver, welder)
6. Carrega pneus no ombro → deixa ao lado → quando termina, carrega na pickup
7. Dirige até o fence → vende materiais + pneus do truck
8. XP acumula → sobe para Mecânico (Tier 2)
9. Com trust 2, recebe área da próxima rotação do fence
10. Com trust 3 + Tier 3 → VIN scratching + ordens de encomenda disponíveis
11. Com trust 4 + Tier 4 → entrega carros inteiros, blip preciso, preço máximo
```
