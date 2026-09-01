-- server/broker/npc_context_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-5] BROKER NPC PERSONA, CONTEXT UI & CONTRACT DISCOVERY SPEC
--  Testa o callback autoritativo vp_chopshop:broker:getNpcContext, capabilities,
--  persona, gates de trust, sanitização de dados e segurança de UX.
-- ═══════════════════════════════════════════════════════════════════════════════

if GetConvar('vp_chopshop_selftest', '0') ~= '1' then return end

local function run()
    local pass = 0
    local fail = 0
    local total = 0

    local function check(desc, cond)
        total = total + 1
        if cond then
            pass = pass + 1
            print(('[broker_npc/spec] PASS  %s'):format(desc))
        else
            fail = fail + 1
            print(('[broker_npc/spec] FAIL  %s'):format(desc))
        end
    end

    -- ─── Mocks & Helpers ────────────────────────────────────────────────────
    local orig_IsValidSource = _G.IsValidSource
    local orig_ServerPlayerIsReady = _G.ServerPlayerIsReady
    local orig_ServerChopPlayerKey = _G.ServerChopPlayerKey
    local orig_ValidatePlayerNearCoords = _G.ValidatePlayerNearCoords
    local orig_ValidatePlayerNearPoint = _G.ValidatePlayerNearPoint
    local orig_VPChopGetProgression = _G.VPChopGetProgression
    local orig_VPChopFenceCurrentLocation = _G.VPChopFenceCurrentLocation
    local orig_VPChopFenceGetTrust = _G.VPChopFenceGetTrust
    local orig_Locale = Config.Locale

    local getContextCb = _G.CapturedCallbacks and _G.CapturedCallbacks['vp_chopshop:broker:getNpcContext']
    check('NPC-REGISTER-01 Callback vp_chopshop:broker:getNpcContext registrado', type(getContextCb) == 'function')

    -- Stub environment state
    local testSrc = 1
    local testPlayerKey = 'qbx:test_player_1'
    local playerDistance = 2.0
    local isPlayerReady = true
    local mockTrustLevel = 0
    local mockTrustXp = 0
    local mockProgression = { tier = 1, xp = 150, nextXp = 500, totalChops = 5 }

    _G.IsValidSource = function(src) return type(src) == 'number' and src > 0 end
    _G.ServerPlayerIsReady = function(src) return isPlayerReady end
    _G.ServerChopPlayerKey = function(src) return testPlayerKey end
    _G.ValidatePlayerNearCoords = function(src, coords) return playerDistance <= 5.0 end
    _G.ValidatePlayerNearPoint = function(src, coords, maxDist) return playerDistance <= maxDist end
    _G.VPChopGetProgression = function(src) return mockProgression end

    -- Mock VPChopFenceCurrentLocation
    _G.VPChopFenceCurrentLocation = function()
        return {
            coords = vector3(100.0, -1000.0, 25.0),
            label = 'Docks Warehouse',
            scenario = 'WORLD_HUMAN_STAND_IMPATIENT',
        }
    end

    -- Mock VPChopFenceGetTrust
    _G.VPChopFenceGetTrust = function(src)
        return mockTrustLevel
    end

    -- ─── NPC-CTX-01: Invalid Source & Player Ready Gate ─────────────────────
    do
        local resInvalidSrc = getContextCb(-1)
        check('NPC-CTX-01 Invalid source retorna fail-closed (ok=false)', resInvalidSrc.ok == false and resInvalidSrc.err == 'invalid_source')

        isPlayerReady = false
        local resNotReady = getContextCb(testSrc)
        check('NPC-CTX-01 Player not ready retorna fail-closed (ok=false)', resNotReady.ok == false and resNotReady.err == 'player')
        isPlayerReady = true
    end

    -- ─── NPC-CTX-02: Fence Proximity & Location Gate ────────────────────────
    do
        playerDistance = 50.0 -- Jogador longe do Fence
        local resFar = getContextCb(testSrc)
        check('NPC-CTX-02 Jogador fora da distância do Fence retorna err=distance', resFar.ok == false and resFar.err == 'distance')
        playerDistance = 2.0

        local oldLocFunc = _G.VPChopFenceCurrentLocation
        _G.VPChopFenceCurrentLocation = function() return nil end
        local resNoFence = getContextCb(testSrc)
        check('NPC-CTX-02 Fence sem localização válida retorna err=no_fence', resNoFence.ok == false and resNoFence.err == 'no_fence')
        _G.VPChopFenceCurrentLocation = oldLocFunc
    end

    -- ─── NPC-CTX-03: Trust 0 Capabilities ───────────────────────────────────
    do
        mockTrustLevel = 0
        local resT0 = getContextCb(testSrc)
        check('NPC-CTX-03 Trust 0: ok=true e dados de broker presentes', resT0.ok == true and resT0.broker.alias ~= nil)
        check('NPC-CTX-03 Trust 0: introduce capability é true', resT0.capabilities.introduce == true)
        check('NPC-CTX-03 Trust 0: sellPart capability é false', resT0.capabilities.sellPart == false)
        check('NPC-CTX-03 Trust 0: hotJob capability é false', resT0.capabilities.hotJob == false)
        check('NPC-CTX-03 Trust 0: legacyOrder capability é false', resT0.capabilities.legacyOrder == false)
        check('NPC-CTX-03 Trust 0: deliverCar capability é false', resT0.capabilities.deliverCar == false)
        check('NPC-CTX-03 Trust 0: Sanitização estrita (zero playerKey / internals expostos)', resT0.playerKey == nil and resT0.citizenid == nil and resT0.db == nil)
    end

    -- ─── NPC-CTX-04: Trust 1 Capabilities ───────────────────────────────────
    do
        mockTrustLevel = 1
        local resT1 = getContextCb(testSrc)
        check('NPC-CTX-04 Trust 1: introduce capability é false', resT1.capabilities.introduce == false)
        check('NPC-CTX-04 Trust 1: sellPart capability é true', resT1.capabilities.sellPart == true)
        check('NPC-CTX-04 Trust 1: sellItems capability é true', resT1.capabilities.sellItems == true)
        check('NPC-CTX-04 Trust 1: sellTyres capability é true', resT1.capabilities.sellTyres == true)
        check('NPC-CTX-04 Trust 1: hotJob capability ainda é false', resT1.capabilities.hotJob == false)
        check('NPC-CTX-04 Trust 1: legacyOrder capability ainda é false', resT1.capabilities.legacyOrder == false)
    end

    -- ─── NPC-CTX-05: Trust 2 Capabilities & Shop Flag ───────────────────────
    do
        mockTrustLevel = 2
        Config.NPC = Config.NPC or {}
        Config.NPC.Shop = Config.NPC.Shop or {}
        Config.NPC.Shop.Enable = true

        local resT2 = getContextCb(testSrc)
        check('NPC-CTX-05 Trust 2: hotJob capability é true', resT2.capabilities.hotJob == true)
        check('NPC-CTX-05 Trust 2: status capability é true', resT2.capabilities.status == true)
        check('NPC-CTX-05 Trust 2: buyBench é true quando Shop.Enable=true', resT2.capabilities.buyBench == true)
        check('NPC-CTX-05 Trust 2: legacyOrder capability ainda é false', resT2.capabilities.legacyOrder == false)
        check('NPC-CTX-05 Trust 2: deliverCar capability ainda é false', resT2.capabilities.deliverCar == false)
    end

    -- ─── NPC-CTX-06: Trust 3 Capabilities ───────────────────────────────────
    do
        mockTrustLevel = 3
        local resT3 = getContextCb(testSrc)
        check('NPC-CTX-06 Trust 3: legacyOrder capability é true', resT3.capabilities.legacyOrder == true)
        check('NPC-CTX-06 Trust 3: contracts capability é true', resT3.capabilities.contracts == true)
        check('NPC-CTX-06 Trust 3: deliverCar capability ainda é false', resT3.capabilities.deliverCar == false)
    end

    -- ─── NPC-CTX-07: Trust 4 Capabilities ───────────────────────────────────
    do
        mockTrustLevel = 4
        local resT4 = getContextCb(testSrc)
        check('NPC-CTX-07 Trust 4: deliverCar capability é true', resT4.capabilities.deliverCar == true)
        check('NPC-CTX-07 Trust 4: todas as capacidades comerciais ativas', resT4.capabilities.sellPart and resT4.capabilities.hotJob and resT4.capabilities.legacyOrder and resT4.capabilities.deliverCar)
    end

    -- ─── NPC-CTX-08: Fresh Server Context on Repeat Opens ───────────────────
    do
        mockTrustLevel = 1
        local firstOpen = getContextCb(testSrc)
        check('NPC-CTX-08 Primeira abertura com Trust 1: legacyOrder=false', firstOpen.capabilities.legacyOrder == false)

        -- Simula avanço de trust no servidor
        mockTrustLevel = 3
        local secondOpen = getContextCb(testSrc)
        check('NPC-CTX-08 Segunda abertura lê Trust NOVO (3) do servidor: legacyOrder=true', secondOpen.capabilities.legacyOrder == true and secondOpen.trust.level == 3)
    end

    -- ─── NPC-FLAG-01: Shop.Enable Feature Flag ──────────────────────────────
    do
        mockTrustLevel = 3
        Config.NPC = Config.NPC or {}
        Config.NPC.Shop = Config.NPC.Shop or {}
        local oldShopEnable = Config.NPC.Shop.Enable
        Config.NPC.Shop.Enable = false
        local resShopOff = getContextCb(testSrc)
        check('NPC-FLAG-01 Config.NPC.Shop.Enable=false resulta em buyBench=false mesmo com Trust 3', resShopOff.capabilities.buyBench == false)
        Config.NPC.Shop.Enable = oldShopEnable
    end

    -- ─── NPC-FLAG-03: Broker / Contracts Feature Flags ──────────────────────
    do
        mockTrustLevel = 3
        local oldContractsEnable = Config.Broker.Contracts.Enable
        Config.Broker.Contracts.Enable = false
        local resContractsOff = getContextCb(testSrc)
        check('NPC-FLAG-03 Config.Broker.Contracts.Enable=false resulta em contracts=false', resContractsOff.capabilities.contracts == false)
        Config.Broker.Contracts.Enable = oldContractsEnable

        local oldBrokerEnable = Config.Broker.Enable
        Config.Broker.Enable = false
        local resBrokerOff = getContextCb(testSrc)
        check('NPC-FLAG-03 Config.Broker.Enable=false resulta em contracts=false e brokerEnabled=false', resBrokerOff.capabilities.contracts == false and resBrokerOff.brokerEnabled == false)
        Config.Broker.Enable = oldBrokerEnable
    end

    -- ─── NPC-READY-01..03: BrokerContracts Readiness Gate ───────────────────
    do
        mockTrustLevel = 4
        local origIsReady = BrokerContracts and BrokerContracts.IsReady

        -- NPC-READY-01: BrokerContracts.IsReady() == false -> capability false
        BrokerContracts.IsReady = function() return false end
        local resNotReady = getContextCb(testSrc)
        check('NPC-READY-01 BrokerContracts.IsReady=false resulta em contractsReady=false', resNotReady.contractsReady == false)
        check('NPC-READY-01 BrokerContracts.IsReady=false resulta em capabilities.contracts=false mesmo com Trust 4', resNotReady.capabilities.contracts == false)

        -- NPC-READY-02: BrokerContracts.IsReady() == true + Trust >= MinTrust -> capability true
        BrokerContracts.IsReady = function() return true end
        mockTrustLevel = 3
        local resReady = getContextCb(testSrc)
        check('NPC-READY-02 BrokerContracts.IsReady=true + Trust 3 resulta em contractsReady=true', resReady.contractsReady == true)
        check('NPC-READY-02 BrokerContracts.IsReady=true + Trust 3 resulta em capabilities.contracts=true', resReady.capabilities.contracts == true)

        -- NPC-READY-03: BrokerContracts.IsReady() == true + Trust < MinTrust -> capability false
        mockTrustLevel = 0
        local resLowTrust = getContextCb(testSrc)
        check('NPC-READY-03 BrokerContracts.IsReady=true mas Trust 0 resulta em capabilities.contracts=false', resLowTrust.capabilities.contracts == false)

        BrokerContracts.IsReady = origIsReady
        mockTrustLevel = 3
    end

    -- ─── NPC-CONTRACT-SHAPE-01 & NPC-CONTRACT-SPLIT-01: Partition Real Array ─
    do
        dofile('shared/locale.lua')
        _G.RegisterNetEvent = _G.RegisterNetEvent or function(...) end
        -- Carregar client/fence.lua para testar as funções puras de UI e particionamento
        dofile('client/fence.lua')

        check('NPC-CONTRACT-SHAPE-01 VPChopPartitionContracts existe como função pura', type(VPChopPartitionContracts) == 'function')

        -- Array flat retornado pelo getContracts / BrokerContracts.GetAvailable
        local mixedFlatContracts = {
            {
                id = 'c_global_1',
                isGlobal = true,
                contractType = 'part',
                targetKey = 'adv_engine',
                quantity = 3,
                remaining = 2,
                rewardMult = 1.30,
                bonusCash = 2000,
                expiresAt = 1700003600,
                state = 'AVAILABLE',
            },
            {
                id = 'c_pers_avail_1',
                isGlobal = false,
                contractType = 'part',
                targetKey = 'catalytic_converter',
                quantity = 2,
                remaining = 2,
                rewardMult = 1.25,
                bonusCash = 1500,
                expiresAt = 1700001800,
                state = 'AVAILABLE',
            },
            {
                id = 'c_pers_acc_1',
                isGlobal = false,
                contractType = 'part',
                targetKey = 'body_panel',
                quantity = 4,
                remaining = 1,
                rewardMult = 1.15,
                bonusCash = 800,
                expiresAt = 1700001200,
                state = 'ACCEPTED',
            },
        }

        local globals, personals = VPChopPartitionContracts(mixedFlatContracts)
        check('NPC-CONTRACT-SPLIT-01 Array flat particionado: exatamente 1 global encontrado', #globals == 1)
        check('NPC-CONTRACT-SPLIT-01 Array flat particionado: exatamente 2 pessoais encontrados', #personals == 2)
        check('NPC-CONTRACT-SPLIT-01 Global ID correto no slot global', globals[1].id == 'c_global_1')
        check('NPC-CONTRACT-SPLIT-01 Pessoal 1 tem state AVAILABLE', personals[1].state == 'AVAILABLE')
        check('NPC-CONTRACT-SPLIT-01 Pessoal 2 tem state ACCEPTED', personals[2].state == 'ACCEPTED')

        -- Prova anti-regressão: se alguém passar tabela com estrutura legada { global = {}, personal = {} }, globals fica vazio
        local legacyDict = { global = { { id = 'g1' } }, personal = { { id = 'p1' } } }
        local gEmpty, pEmpty = VPChopPartitionContracts(legacyDict)
        check('NPC-CONTRACT-SPLIT-01 Prova anti-bug: dicionário legado particiona 0 itens (não é array)', #gEmpty == 0 and #pEmpty == 0)
    end

    -- ─── NPC-COUNTDOWN-01: Server Time Countdown Calculation ────────────────
    do
        local serverNow = 1000
        local expiresAt = 1060
        local remSec = VPChopContractRemainingSeconds(expiresAt, serverNow)
        check('NPC-COUNTDOWN-01 expiresAt=1060 e serverNow=1000 resulta exatamente em 60 segundos', remSec == 60)

        local expiredRem = VPChopContractRemainingSeconds(900, serverNow)
        check('NPC-COUNTDOWN-01 Contrato expirado (900 < 1000) retorna math.max(0) = 0 segundos', expiredRem == 0)
    end

    -- ─── NPC-CONTRACT-ACTIONS & CARRY LIFECYCLE ──────────────────────────────
    do
        local droppedCarry = false
        local registeredContexts = {}
        local showedContext = nil

        _G.VPChopDropCarryPart = function() droppedCarry = true end
        _G.lib = _G.lib or {}
        _G.lib.notify = function(n) end
        _G.lib.registerContext = function(ctx) registeredContexts[ctx.id] = ctx end
        _G.lib.showContext = function(id) showedContext = id end

        -- Mock getContracts callback para openBrokerContractsMenu
        local getContractsMockData = {
            ok = true,
            serverNow = 1700000000,
            contracts = {
                {
                    id = 'c_global_1',
                    isGlobal = true,
                    contractType = 'part',
                    targetKey = 'adv_engine',
                    quantity = 2,
                    remaining = 1,
                    rewardMult = 1.35,
                    bonusCash = 2500,
                    expiresAt = 1700003600,
                    state = 'AVAILABLE',
                },
                {
                    id = 'c_pers_avail_1',
                    isGlobal = false,
                    contractType = 'part',
                    targetKey = 'catalytic_converter',
                    quantity = 3,
                    remaining = 3,
                    rewardMult = 1.25,
                    bonusCash = 1800,
                    expiresAt = 1700001800,
                    state = 'AVAILABLE',
                },
                {
                    id = 'c_pers_acc_1',
                    isGlobal = false,
                    contractType = 'part',
                    targetKey = 'body_panel',
                    quantity = 4,
                    remaining = 2,
                    rewardMult = 1.15,
                    bonusCash = 1000,
                    expiresAt = 1700001200,
                    state = 'ACCEPTED',
                }
            }
        }

        local acceptCalled = {}
        local fulfillCalled = {}
        local callbackHandlers = {
            ['vp_chopshop:broker:getContracts'] = function() return getContractsMockData end,
            ['vp_chopshop:broker:acceptContract'] = function(contractId)
                table.insert(acceptCalled, contractId)
                return { ok = true }
            end,
            ['vp_chopshop:broker:fulfillContract'] = function(contractId, entId)
                table.insert(fulfillCalled, { contractId = contractId, entitlementId = entId })
                return { ok = true, payout = 1500, bonus = 200 }
            end
        }

        _G.lib.callback.await = function(name, _, ...)
            if callbackHandlers[name] then
                return callbackHandlers[name](...)
            end
            return nil
        end

        -- Abrir menu de contratos
        openBrokerContractsMenu()
        local menu = registeredContexts['vp_broker_contracts']
        check('NPC-CONTRACT-VIEW-01 Menu vp_broker_contracts registrado com sucesso', menu ~= nil and type(menu.options) == 'table')

        -- Opções geradas: Header Global (1), Global Item (2), Header Personal (3), Personal Avail (4), Personal Acc (5), Voltar (6)
        local optGlobal = menu.options[2]
        local optPersonalAvail = menu.options[4]
        local optPersonalAcc = menu.options[5]

        -- NPC-CONTRACT-GLOBAL-01: Global não oferece Accept
        check('NPC-CONTRACT-GLOBAL-01 Global listing não contém [Disponível] nem Accept no título', not optGlobal.title:find('Aguardando') and not optGlobal.title:find('Aceitar'))

        -- NPC-CONTRACT-PERSONAL-01: Personal AVAILABLE oferece Aceitar
        check('NPC-CONTRACT-PERSONAL-01 Personal AVAILABLE exibe descrição de aceitar', optPersonalAvail.description == L('broker_contract_click_accept'))

        -- NPC-CONTRACT-PERSONAL-02: Personal ACCEPTED exibe descrição de entrega
        check('NPC-CONTRACT-PERSONAL-02 Personal ACCEPTED exibe descrição de entrega', optPersonalAcc.description == L('broker_contract_click_fulfill'))

        -- NPC-CONTRACT-PERSONAL-01 / REFRESH-01: Executar onSelect em AVAILABLE dispara acceptContract
        acceptCalled = {}
        optPersonalAvail.onSelect()
        check('NPC-CONTRACT-REFRESH-01 Aceite de contrato invoca callback vp_chopshop:broker:acceptContract com contractId', #acceptCalled == 1 and acceptCalled[1] == 'c_pers_avail_1')

        -- NPC-CONTRACT-ARGS-01 & NPC-CARRY-01: Fulfill com peça carregada envia SOMENTE (contractId, entitlementId) e limpa carry
        _G.VPChopCarryingPart = { entitlementId = 'pe:test_42', partKey = 'body_panel' }
        droppedCarry = false
        fulfillCalled = {}
        optPersonalAcc.onSelect()
        check('NPC-CONTRACT-ARGS-01 Fulfill transmite estritamente contractId e entitlementId', #fulfillCalled == 1 and fulfillCalled[1].contractId == 'c_pers_acc_1' and fulfillCalled[1].entitlementId == 'pe:test_42')
        check('NPC-CARRY-01 Fulfill com sucesso limpa carry prop imediatamente', droppedCarry == true)

        -- NPC-CARRY-02: Fulfill com terminalConsumed=true limpa carry prop mesmo com ok=false
        callbackHandlers['vp_chopshop:broker:fulfillContract'] = function()
            return { ok = false, err = 'payment_failed', terminalConsumed = true }
        end
        droppedCarry = false
        optPersonalAcc.onSelect()
        check('NPC-CARRY-02 Fulfill falho com terminalConsumed=true limpa carry prop (fail-closed)', droppedCarry == true)

        -- NPC-CARRY-03: Fulfill com erro não-terminal mantém a peça nos braços do jogador
        callbackHandlers['vp_chopshop:broker:fulfillContract'] = function()
            return { ok = false, err = 'contract_busy' }
        end
        droppedCarry = false
        optPersonalAcc.onSelect()
        check('NPC-CARRY-03 Fulfill com erro não-terminal retém a peça carregada (droppedCarry=false)', droppedCarry == false)
    end

    -- ─── NPC-LOCALE-01: Paridade Completa de Idiomas (69 Chaves) ─────────────
    do
        dofile('shared/locale.lua')
        local requiredKeys = {
            'broker_target_talk',
            'broker_greeting_trust_0',
            'broker_greeting_trust_1',
            'broker_greeting_trust_2',
            'broker_greeting_trust_3',
            'broker_greeting_trust_4',
            'broker_menu_main_title',
            'broker_menu_sell',
            'broker_menu_sell_desc',
            'broker_menu_contracts',
            'broker_menu_contracts_desc',
            'broker_menu_jobs',
            'broker_menu_jobs_desc',
            'broker_menu_services',
            'broker_menu_services_desc',
            'broker_menu_profile',
            'broker_menu_profile_desc',
            'broker_menu_legacy_order',
            'broker_menu_legacy_order_desc',
            'broker_menu_deliver_car',
            'broker_menu_deliver_car_desc',
            'broker_contracts_global_title',
            'broker_contracts_personal_title',
            'broker_contract_accept',
            'broker_contract_deliver_part',
            'broker_contract_accepted_badge',
            'broker_contract_no_contracts',
            'broker_contract_accepted_notify',
            'broker_contract_fulfilled_notify',
            'broker_menu_back',
            'broker_menu_sell_tyres_desc',
            'broker_contract_remaining_label',
            'broker_contract_reward_label',
            'broker_contract_time_label',
            'broker_contract_mult_label',
            'broker_contract_status_label',
            'broker_contract_available_badge',
            'broker_contract_in_progress',
            'broker_contract_waiting_accept',
            'broker_contract_desc_fmt',
            'broker_contract_mins_fmt',
            'broker_contract_click_fulfill',
            'broker_contract_click_accept',
            'broker_contract_prompt_carry_global',
            'broker_contract_prompt_carry_personal',
            'broker_profile_trust_label',
            'broker_profile_level_fmt',
            'broker_profile_max_label',
            'broker_profile_location_label',
            'broker_default_location',
            'broker_menu_order_view_desc',
            'broker_menu_order_fulfill_desc',
            'err_no_fence',
            'err_no_trust',
            'err_trust_gate',
            'err_market_not_ready',
            'err_market_integrity_locked',
            'err_contract_busy',
            'err_contract_not_accepted',
            'err_contract_expired',
            'err_wrong_part',
            'err_provenance_missing',
            'err_provenance_class_missing',
            'err_external_reserved',
            'err_workshop_integrity_locked',
            'err_payment_failed',
            'err_nothing_sold',
            'err_contracts_not_ready',
        }

        local languages = { 'pt', 'en', 'es', 'fr', 'tr' }
        local allLocalesPresent = true
        for _, lang in ipairs(languages) do
            Config.Locale = lang
            for _, k in ipairs(requiredKeys) do
                local val = L(k)
                if not val or val == k then
                    allLocalesPresent = false
                    print(('[broker_npc/spec] Missing locale key: %s in %s'):format(k, lang))
                end
            end
        end
        Config.Locale = 'pt'
        check('NPC-LOCALE-01 Todas as 69 chaves de tradução presentes em pt, en, es, fr, tr', allLocalesPresent == true)
    end

    -- ─── NPC-LOCALE-NO-HARDCODE-01: Zero Hardcoded Strings in Client Broker UI 
    do
        local file = io.open('client/fence.lua', 'r')
        local content = file and file:read('*a') or ''
        if file then file:close() end

        -- Extrair o bloco Broker UI
        local brokerBlock = content:match('%-%- ─── Broker Context UI.-%-%- ─── Menus de interação')
        check('NPC-LOCALE-NO-HARDCODE-01 Bloco Broker Context UI isolado em client/fence.lua', brokerBlock ~= nil and #brokerBlock > 200)

        local forbiddenPatterns = {
            "'Voltar'",
            '"Voltar"',
            "'Truck / Inventário'",
            '"Truck / Inventário"',
            "'Restante'",
            "'Recompensa'",
            "'Tempo'",
            "'Em Andamento'",
            "'Aguardando Aceite'",
            "'Multiplicador'",
            "'Clique para entregar peça carregada'",
            "'Clique para aceitar o contrato'",
            "'Carregue uma peça compatível nos braços para entregar.'",
            "'Carregue uma peça compatível para entregar nesta alta procura.'",
            "'Reputação / Trust'",
            "'Ver detalhes dos itens solicitados e prazo'",
            "'Entregar itens do inventário para concluir a encomenda'",
        }

        local foundHardcode = false
        for _, pat in ipairs(forbiddenPatterns) do
            if brokerBlock:find(pat, 1, true) then
                foundHardcode = true
                print(('[broker_npc/spec] Found forbidden hardcoded string in client/fence.lua: %s'):format(pat))
            end
        end
        check('NPC-LOCALE-NO-HARDCODE-01 Zero textos em português hardcoded encontrados no Broker UI', foundHardcode == false)
    end

    -- ─── NPC-NO-ECONOMY-DRIFT-01: Preservação das Canaries Econômicas ────────
    do
        check('NPC-NO-ECONOMY-DRIFT-01 Config.Broker.Commodities inalterado', Config.Broker and Config.Broker.Commodities and Config.Broker.Commodities.catalytic_converter.basePrice == 1600)
        check('NPC-NO-ECONOMY-DRIFT-01 Config.Broker.Market bounds inalterados', Config.Broker.Market.PriceFloor == 0.40 and Config.Broker.Market.PriceCeiling == 2.50)
        check('NPC-NO-ECONOMY-DRIFT-01 Config.Broker.Contracts pools inalterados', #Config.Broker.Contracts.Pools.part_type == 3)
    end

    -- Restaurar globals originais para não poluir specs subsequentes no harness
    _G.IsValidSource = orig_IsValidSource
    _G.ServerPlayerIsReady = orig_ServerPlayerIsReady
    _G.ServerChopPlayerKey = orig_ServerChopPlayerKey
    _G.ValidatePlayerNearCoords = orig_ValidatePlayerNearCoords
    _G.ValidatePlayerNearPoint = orig_ValidatePlayerNearPoint
    _G.VPChopGetProgression = orig_VPChopGetProgression
    _G.VPChopFenceCurrentLocation = orig_VPChopFenceCurrentLocation
    _G.VPChopFenceGetTrust = orig_VPChopFenceGetTrust
    Config.Locale = orig_Locale

    print(('[broker_npc/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
    if fail > 0 then error('npc_context_spec falhou') end
end

run()
