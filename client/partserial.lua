-- client/partserial.lua
-- [SERIAL] Número de série da car_parts — lado CLIENT. Três blocos isolados:
--   1) BANCADA: opções "Riscar série" / "Forjar série" no menu da bancada (a verdade —
--      tier, proximidade, estado, insumos, cooldown — é toda do servidor). As opções só
--      aparecem quando o servidor confirma elegibilidade (callback benchAvailability).
--   2) POLÍCIA: ox_target GLOBAL em jogadores → "Inspecionar peças de carro" (gated por job
--      policial no client p/ UX; o servidor revalida tudo). Mostra o resultado por linha.
--   3) VENDEDOR LEGAL opcional: NPC fixo com ox_target "Comprar peças (legal)".
--
-- Carregado ANTES de client/main.lua (registra hook na bancada via VPChopSerialBenchOptions).
-- NUNCA exibe placa (regra absoluta — coerente com as marcas de pneu).

if not Config.PartSerial or not Config.PartSerial.Enable then return end

local PS = Config.PartSerial

-- ─────────────────────────────────────────────────────────────────────────────
-- [SERIAL] BLOCO 1 — opções da bancada (riscar / forjar)
-- ─────────────────────────────────────────────────────────────────────────────

--- Executa o RISCAR: barra de progresso + callback. Notifica por chave de locale.
local function doScratch()
    local ok = lib.progressBar({
        duration     = 5000,
        label        = L('serial_scratch_progress'),
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true },
        anim         = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 },
    })
    if not ok then return end
    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:serial:scratch', false)
    if not cbOk then res = nil end
    if res and res.ok then
        VPChopNotify(L('serial_scratch_success'), 'success')
    else
        local errKey = ({
            tier     = 'serial_scratch_tier',
            no_part  = 'serial_no_part',
            distance = 'serial_too_far',
            cooldown = 'serial_cooldown',
            player   = 'serial_generic_error',
        })[(res and res.err) or ''] or 'serial_generic_error'
        VPChopNotify(L(errKey), 'error')
    end
end

--- Executa o FORJAR: barra de progresso + callback. Notifica por chave de locale.
local function doForge()
    local ok = lib.progressBar({
        duration     = 9000,
        label        = L('serial_forge_progress'),
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true },
        anim         = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 },
    })
    if not ok then return end
    local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:serial:forge', false)
    if not cbOk then res = nil end
    if res and res.ok then
        VPChopNotify(L('serial_forge_success'), 'success')
    else
        local errKey = ({
            tier     = 'serial_forge_tier',
            inputs   = 'serial_forge_inputs',
            no_part  = 'serial_no_part',
            distance = 'serial_too_far',
            cooldown = 'serial_cooldown',
            remove   = 'serial_generic_error',
            player   = 'serial_generic_error',
        })[(res and res.err) or ''] or 'serial_generic_error'
        VPChopNotify(L(errKey), 'error')
    end
end

function VPChopSerialDoScratch()
    doScratch()
end

function VPChopSerialDoForge()
    doForge()
end

--- [SERIAL] Devolve as opções de ox_target da bancada relativas à série. Chamada por
--- client/bench.lua (VPChopUpsertBench) ao montar os targets. canInteract consulta o
--- servidor (benchAvailability) para só mostrar quando há peça elegível + tier suficiente.
--- A verdade final segue nos callbacks de scratch/forge.
---@param benchId integer
---@return table[] options
function VPChopSerialBenchOptions(benchId)
    -- Cache leve por bench para o canInteract não bater no servidor a cada frame.
    -- ox_target chama canInteract sob demanda (não por frame), mas mesmo assim cacheamos.
    local avail = { scratch = false, forge = false }
    local lastCheck = 0
    local function refresh()
        local now = GetGameTimer()
        if now - lastCheck < 1500 then return end
        lastCheck = now
        -- [AUDIT M5] Fire-and-forget: nunca bloquear o canInteract do ox_target com .await.
        -- Atualiza o cache em background; o canInteract usa o último valor conhecido.
        CreateThread(function()
            local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:serial:benchAvailability', false)
            if cbOk and type(res) == 'table' then avail = res end
        end)
    end

    return {
        {
            name        = ('vp_chop_serial_scratch_%s'):format(benchId),
            label       = L('serial_scratch_label'),
            icon        = 'fa-solid fa-eraser',
            distance    = Config.InteractDistance,
            canInteract = function()
                if GetVehiclePedIsIn(cache.ped, false) ~= 0 then return false end
                refresh()
                return avail.scratch == true
            end,
            onSelect    = function() doScratch() end,
        },
        {
            name        = ('vp_chop_serial_forge_%s'):format(benchId),
            label       = L('serial_forge_label'),
            icon        = 'fa-solid fa-stamp',
            distance    = Config.InteractDistance,
            canInteract = function()
                if GetVehiclePedIsIn(cache.ped, false) ~= 0 then return false end
                refresh()
                return avail.forge == true
            end,
            onSelect    = function() doForge() end,
        },
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- [SERIAL] BLOCO 2 — POLÍCIA: inspeção (ox_target global em jogadores)
-- ─────────────────────────────────────────────────────────────────────────────

local policeSet = {}
for _, j in ipairs(PS.PoliceJobs or { 'police', 'bcso', 'sheriff' }) do policeSet[j] = true end

--- [SERIAL] true se o jogador local é polícia (UX; o servidor revalida o job no callback).
local function playerIsPolice()
    if GetResourceState('qbx_core') ~= 'started' then return false end
    local ok, pdata = pcall(function() return exports.qbx_core:GetPlayerData() end)
    local job = ok and pdata and pdata.job and pdata.job.name
    return job ~= nil and policeSet[job] == true
end

--- [SERIAL] Resolve o nome de exibição legível de um modelo a partir de hash ou string de display.
---@param rawModel string|number|nil
---@return string|nil
local function resolveModelDisplayName(rawModel)
    if not rawModel or rawModel == '' or rawModel == 'CARMODEL' then return nil end
    local num = tonumber(rawModel)
    if num and num ~= 0 then
        local disp = GetDisplayNameFromVehicleModel(num)
        if disp and disp ~= '' and disp ~= 'CARNOTFOUND' then
            local lbl = GetLabelText(disp)
            if lbl and lbl ~= '' and lbl ~= 'NULL' then return lbl end
            return disp
        end
    end
    if type(rawModel) == 'string' then
        local lbl = GetLabelText(rawModel)
        if lbl and lbl ~= '' and lbl ~= 'NULL' then return lbl end
        return rawModel
    end
    return nil
end

--- [SERIAL] Traduz uma linha de veredito do servidor em texto exibível. O servidor manda
--- o identificador técnico/display do modelo; o GetDisplayNameFromVehicleModel e GetLabelText
--- (client) o deixam amigável. NUNCA há placa em nenhuma linha.
---@param line { verdict: string, model: string|nil, count: number }
---@return string
local function formatInspectLine(line)
    local n = tonumber(line.count) or 1
    if line.verdict == 'stolen' then
        local pretty = resolveModelDisplayName(line.model)
        if pretty then
            return L('serial_inspect_stolen_model_fmt', n, pretty)
        end
        return L('serial_inspect_stolen_fmt', n)
    elseif line.verdict == 'scratched' then
        return L('serial_inspect_scratched_fmt', n)
    elseif line.verdict == 'forged' then
        return L('serial_inspect_forged_fmt', n)   -- só aparece com perícia (forensic_kit)
    else -- 'legal'
        return L('serial_inspect_legal_fmt', n)
    end
end

--- Abre o resultado da inspeção num context menu (ox_lib).
---@param res table
local function showInspectResult(res)
    if res.empty then
        VPChopNotify(L('serial_inspect_empty'), 'inform')
        return
    end
    local options = {}
    for _, line in ipairs(res.lines or {}) do
        local icon = 'fa-solid fa-circle-question'
        if     line.verdict == 'legal'     then icon = 'fa-solid fa-circle-check'
        elseif line.verdict == 'stolen'    then icon = 'fa-solid fa-triangle-exclamation'
        elseif line.verdict == 'scratched' then icon = 'fa-solid fa-ban'
        elseif line.verdict == 'forged'    then icon = 'fa-solid fa-user-secret' end
        options[#options + 1] = { title = formatInspectLine(line), icon = icon, readOnly = true }
    end
    lib.registerContext({
        id      = 'vp_chop_serial_inspect',
        title   = res.forensic and L('serial_inspect_title_forensic') or L('serial_inspect_title'),
        options = options,
    })
    lib.showContext('vp_chop_serial_inspect')
end

-- ox_target GLOBAL em jogadores. canInteract gate por job (UX); servidor revalida.
CreateThread(function()
    -- Espera ox_target estar pronto (mesmo padrão de client/main.lua).
    local tries = 0
    while GetResourceState('ox_target') ~= 'started' and tries < 120 do
        Wait(250); tries = tries + 1
    end
    if GetResourceState('ox_target') ~= 'started' then return end

    exports.ox_target:addGlobalPlayer({
        {
            name     = 'vp_chopshop:inspectParts',
            label    = L('serial_inspect_target'),
            icon     = 'fa-solid fa-magnifying-glass-chart',
            distance = PS.InspectDistance or 2.5,
            canInteract = function()
                return playerIsPolice()
            end,
            onSelect = function(data)
                -- data.entity = ped alvo → resolver serverId via GetPlayerServerId(NetworkGetPlayerIndexFromPed)
                local ped = data and data.entity
                if not ped or ped == 0 then VPChopNotify(L('serial_generic_error'), 'error'); return end
                local targetPlayer = NetworkGetPlayerIndexFromPed(ped)
                if not targetPlayer or targetPlayer == -1 then VPChopNotify(L('serial_inspect_not_player'), 'error'); return end
                local targetServerId = GetPlayerServerId(targetPlayer)
                if not targetServerId or targetServerId <= 0 then VPChopNotify(L('serial_inspect_not_player'), 'error'); return end

                local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:inspectParts', false, targetServerId)
                if not cbOk or not res then VPChopNotify(L('serial_generic_error'), 'error'); return end
                if not res.ok then
                    local errKey = ({
                        not_police = 'serial_inspect_not_police',
                        no_scanner = 'serial_inspect_no_scanner',
                        range      = 'serial_too_far',
                        target     = 'serial_inspect_not_player',
                        cooldown   = 'serial_cooldown',
                    })[res.err or ''] or 'serial_generic_error'
                    VPChopNotify(L(errKey), 'error')
                    return
                end
                showInspectResult(res)
            end,
        },
    })
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- [SERIAL] BLOCO 3 — VENDEDOR LEGAL opcional (NPC fixo)
-- ─────────────────────────────────────────────────────────────────────────────

do
    local lv = PS.LegalVendor
    if lv and lv.Enable and lv.Coords then
        local vendorPed, vendorBlip

        local function spawnVendor()
            local model = lv.Model or 's_m_y_construct_02'
            local hash = joaat(model)
            lib.requestModel(hash, 8000)
            vendorPed = CreatePed(4, hash, lv.Coords.x, lv.Coords.y, lv.Coords.z - 1.0, lv.Coords.w, false, false)
            SetModelAsNoLongerNeeded(hash)
            if not vendorPed or vendorPed == 0 then return end
            FreezeEntityPosition(vendorPed, true)
            SetEntityInvincible(vendorPed, true)
            SetBlockingOfNonTemporaryEvents(vendorPed, true)
            TaskStartScenarioInPlace(vendorPed, 'WORLD_HUMAN_CLIPBOARD', 0, true)

            exports.ox_target:addLocalEntity(vendorPed, {
                {
                    name     = 'vp_chop_legal_parts_buy',
                    label    = L('serial_vendor_buy_fmt', lv.Amount or 1, lv.Price or 0),
                    icon     = 'fa-solid fa-cart-shopping',
                    distance = 2.5,
                    onSelect = function()
                        local cbOk, res = pcall(lib.callback.await, 'vp_chopshop:serial:buyLegal', false)
                        if not cbOk then res = nil end
                        if res and res.ok then
                            VPChopNotify(L('serial_vendor_bought'), 'success')
                        else
                            local errKey = ({
                                money     = 'serial_vendor_no_money',
                                inventory = 'serial_vendor_full',
                            })[(res and res.err) or ''] or 'serial_generic_error'
                            VPChopNotify(L(errKey), 'error')
                        end
                    end,
                },
            })

            if lv.Blip and lv.Blip.Enable then
                vendorBlip = AddBlipForCoord(lv.Coords.x, lv.Coords.y, lv.Coords.z)
                SetBlipSprite(vendorBlip, lv.Blip.Sprite or 402)
                SetBlipColour(vendorBlip, lv.Blip.Color or 2)
                SetBlipScale(vendorBlip, lv.Blip.Scale or 0.7)
                SetBlipAsShortRange(vendorBlip, true)
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentString(lv.Blip.Label or 'Peças (legal)')
                EndTextCommandSetBlipName(vendorBlip)
            end
        end

        CreateThread(function()
            local tries = 0
            while GetResourceState('ox_target') ~= 'started' and tries < 120 do
                Wait(250); tries = tries + 1
            end
            if GetResourceState('ox_target') == 'started' then spawnVendor() end
        end)

        AddEventHandler('onResourceStop', function(resName)
            if resName ~= GetCurrentResourceName() then return end
            if vendorPed and DoesEntityExist(vendorPed) then
                exports.ox_target:removeLocalEntity(vendorPed)
                DeleteEntity(vendorPed)
            end
            if vendorBlip and DoesBlipExist(vendorBlip) then RemoveBlip(vendorBlip) end
        end)
    end
end
