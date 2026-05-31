-- server/partserial.lua
-- [SERIAL] Número de série da car_parts — núcleo server-side.
-- Responsabilidades:
--   1) Gerar/cachear UMA série por VEÍCULO desmanchado (todas as car_parts daquele carro
--      compartilham serial + modelo de origem). Limpa no entityRemoved.
--   2) Helper InvAddCarPartsStolen: entrega car_parts com metadata { serial, state='stolen',
--      sourceModel } — chamado pelas recompensas do desmanche (advanced_chop / chop).
--   3) Bancada: RISCAR e FORJAR a série (callbacks gated por tier + proximidade de bancada).
--   4) Export IssueLegalParts: fonte LEGAL (série registrada no DB).
--   5) Callback de inspeção da polícia (scan normal + perícia via forensic_kit).
--
-- Carregado ANTES de server/advanced_chop.lua e server/chop.lua no fxmanifest (eles usam
-- VPChopSerialGen / VPChopAddStolenCarParts). Depende de: server/db.lua (helpers de série),
-- bridge/server_inventory.lua (Inv*), bridge/server_framework.lua (IsValidSource, Bridge*),
-- server/progression.lua (VPChopGetProgression), bridge/mdt.lua (VPChopMDT — opcional).
-- Confirmadas no código:
--   exports.ox_inventory:AddItem(inv, item, count, metadata) -> success, response
--   exports.ox_inventory:Search(inv, 'slots'|'count', items, metadata?) -> array|number|false
--   exports.ox_inventory:SetMetadata(inv, slotId, metadata)  (substitui metadata do slot)
--   GetDisplayNameFromVehicleModel(modelHash) (server-side OK neste build — ver tyremarks)

local PS = Config.PartSerial or {}

-- ─── Geração de série ─────────────────────────────────────────────────────────
-- Série curta alfanumérica (A-Z0-9). 10 chars → espaço enorme, colisão desprezível.
-- Não é segredo criptográfico: é um identificador forense legível.
local SERIAL_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
local SERIAL_LEN      = 10

--- [SERIAL] Gera uma série aleatória (A-Z0-9, SERIAL_LEN chars).
---@return string
function VPChopSerialGen()
    local t = {}
    for i = 1, SERIAL_LEN do
        local n = math.random(1, #SERIAL_ALPHABET)
        t[i] = SERIAL_ALPHABET:sub(n, n)
    end
    return table.concat(t)
end

-- ─── Cache de série POR VEÍCULO (netId) ───────────────────────────────────────
-- Todas as car_parts de um mesmo carro desmanchado compartilham serial + sourceModel.
-- VehSerial[netId] = { serial = string, sourceModel = string }. Limpo no entityRemoved.
local VehSerial = {} ---@type table<number, { serial: string, sourceModel: string }>

AddEventHandler('entityRemoved', function(entity)
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if netId and netId ~= 0 then
        VehSerial[netId] = nil
    end
end)

--- [SERIAL] Resolve (ou cria e cacheia) a série deste veículo. O modelo de origem é
--- resolvido server-side pelo display name (NUNCA placa — regra absoluta, coerente com
--- as marcas de pneu). Reusa a mesma série para todas as peças do mesmo netId.
---@param netId number
---@return { serial: string, sourceModel: string }
local function getVehicleSerial(netId)
    local cached = VehSerial[netId]
    if cached then return cached end

    local sourceModel = 'CARMODEL'
    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        local modelHash = GetEntityModel(veh)
        if modelHash and modelHash ~= 0 then
            sourceModel = GetDisplayNameFromVehicleModel(modelHash) or 'CARMODEL'
        end
    end

    local data = { serial = VPChopSerialGen(), sourceModel = sourceModel }
    VehSerial[netId] = data
    return data
end

-- ─── Entrega de car_parts ROUBADA (com metadata) ──────────────────────────────
--- [SERIAL] Adiciona `count` car_parts ao inventário do jogador com metadata de peça
--- ROUBADA: { serial, state='stolen', sourceModel }. Usada pelas recompensas do desmanche.
--- Mesmo netId → mesma série/modelo (1 stack por carro). Se a série estiver desligada,
--- cai no InvAdd legado (sem metadata). Retorna o mesmo boolean de InvAdd (true = ok).
---@param src number
---@param netId number
---@param count number
---@return boolean ok
function VPChopAddStolenCarParts(src, netId, count)
    count = tonumber(count) or 0
    if count < 1 then return false end

    -- Série desligada: comportamento legado (sem metadata) — não quebra a economia.
    if not (Config.PartSerial and Config.PartSerial.Enable) then
        return InvAdd(src, 'car_parts', count)
    end

    netId = tonumber(netId)
    if not netId or netId <= 0 then
        -- Sem netId válido não há como amarrar modelo/série coerente → série solta roubada.
        local meta = { serial = VPChopSerialGen(), state = 'stolen', sourceModel = 'CARMODEL' }
        local ok = exports.ox_inventory:AddItem(src, 'car_parts', count, meta)
        return ok ~= nil and ok ~= false
    end

    local data = getVehicleSerial(netId)
    local meta = { serial = data.serial, state = 'stolen', sourceModel = data.sourceModel }
    -- car_parts é stack=true: com metadata IDÊNTICA empilha (1 stack por carro). Confirmado
    -- em ox_inventory AddItem (table.matches no slotMetadata).
    local ok = exports.ox_inventory:AddItem(src, 'car_parts', count, meta)
    return ok ~= nil and ok ~= false
end

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  [SERIAL] BANCADA — riscar e forjar a série                                 ║
-- ╚══════════════════════════════════════════════════════════════════════════╝

local ScratchCooldown = {} ---@type table<number, number>  src → expiry GetGameTimer
local ForgeCooldown   = {} ---@type table<number, number>

AddEventHandler('playerDropped', function()
    local src = source  -- [FIX L-1] capturar antes de qualquer yield
    ScratchCooldown[src] = nil
    ForgeCooldown[src]   = nil
end)

local function scratchCdMs() return (tonumber(Config.PartSerial and Config.PartSerial.ScratchCooldownSeconds) or 3) * 1000 end
local function forgeCdMs()   return (tonumber(Config.PartSerial and Config.PartSerial.ForgeCooldownSeconds)   or 8) * 1000 end

--- [SERIAL] true se o jogador está junto a QUALQUER bancada (mesma verdade do craft/forja
--- de placa). Não confiamos em índice vindo do client. Espelha isPlayerNearAnyBench de plates.lua.
---@param src number
---@return boolean
local function isPlayerNearAnyBench(src)
    if not ServerBenches then return false end
    for _, bench in ipairs(ServerBenches) do
        if bench and bench.coords and ValidatePlayerNearCoords(src, bench.coords) then
            return true
        end
    end
    return false
end

--- [SERIAL] Encontra na mochila do jogador a PRIMEIRA car_parts cujo estado bate com um
--- dos estados aceitos. Retorna slot + metadata atual. Trust-no-client: a metadata é lida
--- do servidor (Search 'slots'), não do client.
---@param src number
---@param acceptStates table<string, boolean>  ex.: { stolen = true }
---@return number|nil slot, table|nil metadata
local function findCarPartBySlotState(src, acceptStates)
    local slots = exports.ox_inventory:Search(src, 'slots', 'car_parts')
    if type(slots) ~= 'table' then return nil, nil end
    for i = 1, #slots do
        local s = slots[i]
        local meta = s and s.metadata
        local state = meta and meta.state
        -- Peça sem metadata (legado) é tratada como 'stolen' para fins de riscar/forjar:
        -- é "suja" por padrão (veio do desmanche antes da série existir).
        if meta == nil or next(meta) == nil then state = 'stolen' end
        if state and acceptStates[state] then
            return s.slot, meta
        end
    end
    return nil, nil
end

-- ─── Callback: RISCAR a série (apaga a série visível) ─────────────────────────
-- 'stolen' (ou peça legada sem metadata) → 'scratched'. A série é zerada; o scan normal
-- da polícia mostra "Série riscada (adulterada)". Counterplay: peça riscada vale igual
-- como insumo, mas é OBVIAMENTE suja na inspeção (não engana ninguém).
lib.callback.register('vp_chopshop:serial:scratch', function(src)
    if not (Config.PartSerial and Config.PartSerial.Enable) then return { ok = false, err = 'disabled' } end
    if not IsValidSource(src) then return { ok = false, err = 'invalid' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end

    local now = GetGameTimer()
    if ScratchCooldown[src] and now < ScratchCooldown[src] then return { ok = false, err = 'cooldown' } end

    -- Proximidade de bancada (verdade server-side)
    if not isPlayerNearAnyBench(src) then return { ok = false, err = 'distance' } end

    -- Gate de tier
    local needTier = tonumber(Config.PartSerial.ScratchTier) or 2
    local prog = VPChopGetProgression(src)
    if not prog or prog.tier < needTier then return { ok = false, err = 'tier' } end

    -- Achar uma car_parts roubada (ou legada) e zerar a série → 'scratched'.
    local slot, meta = findCarPartBySlotState(src, { stolen = true })
    if not slot then return { ok = false, err = 'no_part' } end

    -- Preservar o modelo de origem (continua sendo "de um X") mas apagar a série.
    local newMeta = {
        serial      = nil,  -- série apagada (riscada)
        state       = 'scratched',
        sourceModel = (meta and meta.sourceModel) or nil,
    }
    exports.ox_inventory:SetMetadata(src, slot, newMeta)

    ScratchCooldown[src] = now + scratchCdMs()
    VPChopDiscordLog('[SERIAL] Série riscada na bancada',
        ('src: %s | slot: %s'):format(tostring(src), tostring(slot)))
    return { ok = true }
end)

-- ─── Callback: FORJAR uma série falsa ─────────────────────────────────────────
-- 'stolen'/'scratched' → 'forged'. Série falsa NOVA (NÃO registrada em legit_serials).
-- O scan normal trata 'forged' como "Registrada" (engana). A perícia cruza no DB: não
-- consta → "SÉRIE FORJADA (falsa)". Consome ForgeInputs (atômico, com rollback).
lib.callback.register('vp_chopshop:serial:forge', function(src)
    if not (Config.PartSerial and Config.PartSerial.Enable) then return { ok = false, err = 'disabled' } end
    if not IsValidSource(src) then return { ok = false, err = 'invalid' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end

    local now = GetGameTimer()
    if ForgeCooldown[src] and now < ForgeCooldown[src] then return { ok = false, err = 'cooldown' } end

    if not isPlayerNearAnyBench(src) then return { ok = false, err = 'distance' } end

    local needTier = tonumber(Config.PartSerial.ForgeTier) or 4
    local prog = VPChopGetProgression(src)
    if not prog or prog.tier < needTier then return { ok = false, err = 'tier' } end

    -- Pode forjar a partir de uma peça roubada OU já riscada.
    local slot, meta = findCarPartBySlotState(src, { stolen = true, scratched = true })
    if not slot then return { ok = false, err = 'no_part' } end

    -- Conferir insumos ANTES de remover/alterar nada.
    local inputs = Config.PartSerial.ForgeInputs or {}
    for itemName, need in pairs(inputs) do
        if InvCount(src, itemName) < (tonumber(need) or 0) then return { ok = false, err = 'inputs' } end
    end

    -- Consumir insumos com rollback atômico (padrão server/bench.lua).
    local removed = {}
    for itemName, need in pairs(inputs) do
        local n = tonumber(need) or 0
        if n > 0 then
            if not InvRemove(src, itemName, n) then
                for rName, rAmt in pairs(removed) do InvAdd(src, rName, rAmt) end
                return { ok = false, err = 'remove' }
            end
            removed[itemName] = n
        end
    end

    -- Série falsa NOVA — NÃO registrar em legit_serials (é justamente o que a perícia pega).
    -- sourceModel é APAGADO: uma peça "legalizada" forjada não carrega mais o modelo de
    -- origem (senão entregaria a procedência no próprio item). Estado real fica 'forged';
    -- o scan normal o mascara como 'legal'.
    local fakeSerial = VPChopSerialGen()
    exports.ox_inventory:SetMetadata(src, slot, {
        serial      = fakeSerial,
        state       = 'forged',
        sourceModel = nil,
    })

    ForgeCooldown[src] = now + forgeCdMs()
    VPChopDiscordLog('[SERIAL] Série FORJADA na bancada',
        ('src: %s | slot: %s | serial falsa: %s'):format(tostring(src), tostring(slot), fakeSerial))
    return { ok = true }
end)

-- ─── Callback (UX): o jogador tem car_parts elegível para riscar/forjar? ───────
-- Ajuda o client a só mostrar as opções da bancada quando fizer sentido. A VERDADE
-- (tier, proximidade, estado, insumos) é toda revalidada nos callbacks acima.
lib.callback.register('vp_chopshop:serial:benchAvailability', function(src)
    if not (Config.PartSerial and Config.PartSerial.Enable) then
        return { scratch = false, forge = false }
    end
    if not IsValidSource(src) then return { scratch = false, forge = false } end
    local prog = VPChopGetProgression(src)
    local tier = (prog and prog.tier) or 1
    local scratchSlot = findCarPartBySlotState(src, { stolen = true })
    local forgeSlot   = findCarPartBySlotState(src, { stolen = true, scratched = true })
    return {
        scratch = scratchSlot ~= nil and tier >= (tonumber(Config.PartSerial.ScratchTier) or 2),
        forge   = forgeSlot   ~= nil and tier >= (tonumber(Config.PartSerial.ForgeTier)   or 4),
    }
end)

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  [SERIAL] FONTE LEGAL — export IssueLegalParts                              ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
-- Gera série, registra como LEGÍTIMA no DB e entrega car_parts state='legal'. Mecânicas
-- de oficina podem chamar este export para distribuir peças com procedência limpa.
--   exports['vp_chopshop']:IssueLegalParts(src, amount, source?) -> ok, serial
---@param src number
---@param amount number
---@param source string|nil  rótulo de origem para auditoria (default 'legal_supply')
---@return boolean ok, string|nil serial
-- [AUDIT-FIX C4] Lógica extraída para uma FUNÇÃO LOCAL compartilhada. Antes, o callback
-- buyLegal chamava `exports['vp_chopshop']:IssueLegalParts(...)` (self-export) — frágil
-- (depende do export estar resolvido no mesmo resource). Agora TANTO o export QUANTO o
-- buyLegal chamam esta função local diretamente.
---@param src number
---@param amount number
---@param source string|nil
---@return boolean ok, string|nil serial
local function issueLegalPartsImpl(src, amount, source)
    if not IsValidSource(src) then return false end
    if not ServerPlayerIsReady(src) then return false end
    amount = math.floor(tonumber(amount) or 0)
    if amount < 1 then return false end
    -- [AUDIT-FIX M3] Cap defensivo de quantidade (evita inventory-flood via export externo).
    amount = math.min(amount, 100)

    -- [AUDIT-FIX M3] Log de auditoria de toda emissão de peças legais.
    VPChopDiscordLog('[SERIAL] IssueLegalParts',
        ('src: %s | amount: %s | source: %s'):format(tostring(src), tostring(amount), tostring(source or 'legal_supply')))

    -- Série desligada: degrada para car_parts simples (ainda entrega, sem metadata).
    if not (Config.PartSerial and Config.PartSerial.Enable) then
        return InvAdd(src, 'car_parts', amount), nil
    end

    local serial = VPChopSerialGen()
    -- Registrar ANTES de entregar: a perícia precisa achar a série como legítima.
    VPChopDbRegisterLegitSerial(serial, source or 'legal_supply')

    local ok = exports.ox_inventory:AddItem(src, 'car_parts', amount, {
        serial      = serial,
        state       = 'legal',
        sourceModel = nil,
    })
    if not (ok ~= nil and ok ~= false) then return false end
    return true, serial
end

-- Export público delega para a função local (mesma assinatura/comportamento de antes).
exports('IssueLegalParts', function(src, amount, source)
    return issueLegalPartsImpl(src, amount, source)
end)

-- ─── Callback: compra no VENDEDOR LEGAL (NPC fixo) ───────────────────────────
-- Cobra cash (BridgeRemoveCash) e entrega car_parts 'legal' via IssueLegalParts.
-- Proximidade validada contra as coords FIXAS do vendedor na config (server é a verdade).
local _legalBuyCd = {} ---@type table<number, number>
AddEventHandler('playerDropped', function() local src = source; _legalBuyCd[src] = nil end)

lib.callback.register('vp_chopshop:serial:buyLegal', function(src)
    local lv = Config.PartSerial and Config.PartSerial.LegalVendor
    if not (Config.PartSerial and Config.PartSerial.Enable) or not lv or not lv.Enable then
        return { ok = false, err = 'disabled' }
    end
    if not IsValidSource(src) then return { ok = false, err = 'invalid' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end

    -- Rate limit anti-farm (2s)
    local now = GetGameTimer()
    if _legalBuyCd[src] and now < _legalBuyCd[src] then return { ok = false, err = 'cooldown' } end

    -- Proximidade do vendedor (coords fixas da config — trust-no-client)
    local c = lv.Coords
    if c and not ValidatePlayerNearPoint(src, vector3(c.x, c.y, c.z), 4.0) then
        return { ok = false, err = 'range' }
    end

    local price  = math.floor(tonumber(lv.Price) or 0)
    local amount = math.floor(tonumber(lv.Amount) or 1)
    if amount < 1 then return { ok = false, err = 'disabled' } end

    -- Conferir cash ANTES (BridgeRemoveCash já valida, mas evitamos o débito sem entrega).
    if price > 0 and BridgeGetCash(src) < price then return { ok = false, err = 'money' } end

    -- Cobrar; se falhar, abortar sem entregar.
    if price > 0 and not BridgeRemoveCash(src, price, 'vp_chopshop:legal_parts') then
        return { ok = false, err = 'money' }
    end

    -- [AUDIT-FIX C4] Entregar via FUNÇÃO LOCAL (não self-export). Se inventário cheio, reembolsar.
    local issued = issueLegalPartsImpl(src, amount, 'legal_vendor')
    if not issued then
        if price > 0 then BridgeAddCash(src, price, 'vp_chopshop:legal_parts_refund') end
        return { ok = false, err = 'inventory' }
    end

    _legalBuyCd[src] = now + 5000  -- [AUDIT-FIX M4] cooldown 2s → 5s (anti-farm)
    return { ok = true }
end)

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  [SERIAL] INSPEÇÃO DA POLÍCIA — scan normal + perícia                        ║
-- ╚══════════════════════════════════════════════════════════════════════════╝

local InspectCooldown = {} ---@type table<number, number>  src → expiry GetGameTimer
AddEventHandler('playerDropped', function()
    local src = source
    InspectCooldown[src] = nil
end)
local function inspectCdMs() return (tonumber(Config.PartSerial and Config.PartSerial.InspectCooldownSeconds) or 2) * 1000 end

--- [SERIAL] Classifica um stack de car_parts para o scan NORMAL.
--- Retorna a chave de locale do resultado + (opcional) o modelo de origem.
--- NUNCA expõe placa. 'forged' é mascarado como "Registrada" (engana o scan normal).
---@param meta table|nil
---@return string stateKey  'legal'|'stolen'|'scratched'|'forged_hidden'  (forged → aparece legal)
local function classifyNormal(meta)
    local state = meta and meta.state
    if meta == nil or next(meta or {}) == nil then return 'stolen' end  -- legado sem metadata = roubada
    if state == 'legal'     then return 'legal' end
    if state == 'stolen'    then return 'stolen' end
    if state == 'scratched' then return 'scratched' end
    if state == 'forged'    then return 'forged_hidden' end  -- mascarada como legal no scan normal
    return 'stolen'  -- estado desconhecido → tratar como suja
end

-- Callback de inspeção. O client (target global em jogadores) manda o serverId do alvo.
-- Server valida: polícia, proximidade, alvo válido. Lê as car_parts do alvo e agrupa por
-- estado. Se o policial tem forensic_kit, faz a PERÍCIA: para os stacks que aparecem
-- "Registrada" (legal de verdade OU forjada), cruza a série em legit_serials — não consta
-- → forjada. NUNCA expõe placa; o log no MDT também não leva placa.
lib.callback.register('vp_chopshop:inspectParts', function(src, targetServerId)
    if not (Config.PartSerial and Config.PartSerial.Enable) then return { ok = false, err = 'disabled' } end
    if not IsValidSource(src) then return { ok = false, err = 'invalid' } end
    if not ServerPlayerIsReady(src) then return { ok = false, err = 'player' } end

    -- Gate de JOB policial (verdade server-side; o target no client é só UX)
    local policeJobs = Config.PartSerial.PoliceJobs or { 'police', 'bcso', 'sheriff' }
    if not BridgeIsPolice(src, policeJobs) then return { ok = false, err = 'not_police' } end

    -- Item scanner obrigatório (verdade server-side)
    local scannerItem = Config.PartSerial.ScannerItem or 'parts_scanner'
    if InvCount(src, scannerItem) < 1 then return { ok = false, err = 'no_scanner' } end

    -- Rate limit
    local now = GetGameTimer()
    if InspectCooldown[src] and now < InspectCooldown[src] then return { ok = false, err = 'cooldown' } end

    -- Resolver alvo
    targetServerId = tonumber(targetServerId)
    if not targetServerId or not IsValidSource(targetServerId) then return { ok = false, err = 'target' } end
    if targetServerId == src then return { ok = false, err = 'target' } end

    -- Proximidade server-side (ped a ped)
    local maxDist = tonumber(Config.PartSerial.InspectDistance) or 2.5
    local copPed    = GetPlayerPed(src)
    local targetPed = GetPlayerPed(targetServerId)
    if not copPed or copPed == 0 or not targetPed or targetPed == 0 then return { ok = false, err = 'target' } end
    if #(GetEntityCoords(copPed) - GetEntityCoords(targetPed)) > maxDist then return { ok = false, err = 'range' } end

    InspectCooldown[src] = now + inspectCdMs()

    -- Ler car_parts do ALVO (server é a verdade — Search no inventário do alvo).
    local slots = exports.ox_inventory:Search(targetServerId, 'slots', 'car_parts')
    if type(slots) ~= 'table' or #slots == 0 then
        return { ok = true, empty = true, lines = {} }
    end

    -- Perícia disponível? (policial carrega forensic_kit)
    local forensicItem = Config.PartSerial.ForensicItem or 'forensic_kit'
    local hasForensic = InvCount(src, forensicItem) >= 1

    -- Agrupar por "linha de resultado". Cada linha = um veredito + contagem + (modelo, se houver).
    -- key de agrupamento inclui o resultado final E o modelo (para "ROUBADA de um X").
    local grouped = {}  -- key → { verdict=string, model=string|nil, count=number }
    local function push(verdict, model, count)
        local k = verdict .. '|' .. (model or '')
        local g = grouped[k]
        if not g then g = { verdict = verdict, model = model, count = 0 }; grouped[k] = g end
        g.count = g.count + (count or 0)
    end

    -- [AUDIT-FIX H3] Antes: 1 query (VPChopDbIsLegitSerial) POR slot legal/forged → N queries
    -- por inspeção. Agora, com perícia, coletamos TODAS as séries candidatas e fazemos UMA
    -- query em lote (VPChopDbWhichSerialsLegit → set serial→true). Veredito idêntico ao antigo.
    local legitSet = {}
    if hasForensic then
        local toCheck = {}
        for i = 1, #slots do
            local meta = slots[i] and slots[i].metadata
            local norm = classifyNormal(meta)
            if norm == 'legal' or norm == 'forged_hidden' then
                local serial = meta and meta.serial
                if type(serial) == 'string' and serial ~= '' then
                    toCheck[#toCheck + 1] = serial
                end
            end
        end
        legitSet = VPChopDbWhichSerialsLegit(toCheck)
    end

    for i = 1, #slots do
        local s = slots[i]
        local meta = s and s.metadata
        local count = (s and tonumber(s.count)) or 1
        local norm = classifyNormal(meta)

        if norm == 'legal' or norm == 'forged_hidden' then
            -- Ambos APARECEM "Registrada" no scan normal. A perícia separa:
            if hasForensic then
                local serial = meta and meta.serial
                local isLegit = type(serial) == 'string' and serial ~= '' and legitSet[serial] == true
                if isLegit then
                    push('legal', nil, count)         -- consta no registro → legítima
                else
                    push('forged', nil, count)        -- NÃO consta → série forjada (flagrada)
                end
            else
                push('legal', nil, count)             -- sem perícia: forjada engana → "Registrada"
            end
        elseif norm == 'stolen' then
            push('stolen', meta and meta.sourceModel or nil, count)  -- "ROUBADA de um {modelo}"
        elseif norm == 'scratched' then
            push('scratched', meta and meta.sourceModel or nil, count)
        end
    end

    -- Montar lista de saída (estável). Cada linha leva a chave de locale do veredito + dados.
    -- A tradução final (e o display name do modelo) é resolvida no CLIENT (GetLabelText).
    local lines = {}
    for _, g in pairs(grouped) do
        lines[#lines + 1] = {
            verdict = g.verdict,       -- 'legal'|'stolen'|'scratched'|'forged'
            model   = g.model,          -- display name (ex.: 'SULTANRS') ou nil — NUNCA placa
            count   = g.count,
        }
    end
    table.sort(lines, function(a, b) return (a.verdict .. (a.model or '')) < (b.verdict .. (b.model or '')) end)

    -- Log no MDT SEM placa (regra absoluta). Reporta só atividade de inspeção.
    pcall(function()
        if VPChopMDT and VPChopMDT.ReportActivity then
            VPChopMDT.ReportActivity('', src, 'parts_inspected')
        end
    end)

    return { ok = true, empty = false, forensic = hasForensic, lines = lines }
end)
