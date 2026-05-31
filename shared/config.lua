Config = {}

--- UI language: en | pt | es | fr | tr (see shared/locale.lua)
Config.Locale = 'pt'

Config.Debug = false

--- Distâncias
Config.InteractDistance = 2.4
Config.MaxPlaceDistance = 5.0
Config.VehicleNearLiftRadius = 4.2  -- raio de proximidade jogador↔veículo/macaco (ValidatePlayerNearCoords)
--- Distância mínima entre bancadas (0 = desligado)
Config.MinBenchSpacing = 4.0

--- Modelos de objetos colocáveis
-- [L2 FIX] Config.LiftBaseModel removido — elevador (nacelle) foi removido do sistema.
Config.BenchModel = `prop_tool_bench02`

--- Itens ox_inventory (adicione em data/items.lua — ver installation/)
Config.Items = {
    -- [L2 FIX] placeLift removido — elevador removido do sistema.
    placeBench = 'chopshop_bench',
    placeWelder = 'chopshop_welder',
    -- [L2 FIX] fuel removido — combustível era exclusivo do elevador; sistema removido.
}

-- [L2 FIX] Removidas: Config.UseFuel, Config.FuelMax, Config.FuelPerPartMin/Max, Config.FuelRefillPerItem
-- — todas eram exclusivas do sistema de combustível do elevador, que foi removido.

--- Desmanche: exige chaves do veículo (ESX-only; configure `Config.VehicleKeys`)
Config.RequireVehicleKeys = true

--- Integração de chaves (ESX-first friendly).
--- Se você usa ESX, configure aqui o resource/export do seu sistema de chaves.
--- - Enable=false: usa apenas integrações best-effort (por exemplo `esx_vehiclelock`).
--- - Resource: nome do resource que expõe o export.
--- - Export: nome do export (função) que retorna boolean.
--- - Mode:
---    - 'entity' → chama export(vehicle)
---    - 'plate'  → chama export(plate) com a placa trimada
--- Observação: não existe “padrão ESX” universal para chaves; por isso é configurável.
Config.VehicleKeys = {
    Enable = false,
    --- Valores sugeridos (exemplos): 'esx_vehiclelock', 'qs-vehiclekeys', etc.
    Resource = 'esx_vehiclelock',
    --- Nome do export no resource acima (ex.: 'hasKey', 'HasKeys', etc.)
    Export = 'hasKey',
    --- 'entity' | 'plate'
    Mode = 'plate',
}

--- Segundos de espera após uma peça desmontada com sucesso (0 = desligado). Inspirado em cooldown de job chop.
Config.ChopCooldownSeconds = 0

--- Minijogo opcional antes da barra de progresso (ox_lib skillCheck). `false` = desligado.
--- `true` = dificuldades padrão. Tabela: { difficulties = { 'easy', 'medium' }, keys = { 'e', 'e' } } (keys por passo).
Config.ChopSkillCheck = false

--- Discord webhook opcional (deixe Webhook vazio para desligar)
Config.Discord = {
    Webhook = '',
    Username = 'vp_chopshop',
    AvatarUrl = '',
    Color = 3447003,
    LogChopPart = true,
    LogBenchCraft = true,
    -- [L1 FIX] LogPlaceLift removido — elevador removido do sistema.
    LogPlaceBench = false,
    LogPlaceWelder = false,  -- [L2 FIX] chave ausente; discord.lua verifica esta flag
}

-- [L2 FIX] Config.Partner removido — sistema de parceiro era lift-scoped; removido com o elevador.

--- NPC fixo (info, convite ao elevador mais próximo, loja opcional em dinheiro)
Config.NPC = {
    Enable = false,
    Model = 's_m_y_construct_02',
    Coords = vector4(2339.8943, 3146.3787, 48.2045, 86.2756),
    Scenario = 'WORLD_HUMAN_CLIPBOARD',
    --- Raio para achar elevador ao usar opção no NPC
    NearestLiftRadius = 28.0,
    Blip = {
        Enable = true,
        Sprite = 227,
        Color = 5,
        Scale = 0.75,
    },
    --- Loja: precisa ESX para dinheiro. `Enable = false` só mostra info / parceiro.
    Shop = {
        Enable = false,
        LiftPrice = 5000,
        BenchPrice = 3500,
        --- Cooldown em segundos entre compras no NPC (por jogador, 0 = desligado)
        CooldownSeconds = 10,
    },
    --- Missão no NPC: aceitar “trabalho quente” → na **próxima** desmontagem o servidor **resolve** o trabalho (precisa `Ambush.Enable`).
    Mission = {
        Enable = false,
        --- Segundos entre pedidos de missão ao foreman (por jogador).
        CooldownSeconds = 600,
        --- Tempo máximo para iniciar a desmontagem após aceitar; se expirar, perde o trabalho pendente.
        PendingExpireSeconds = 900,
        --- Na primeira desmontagem após aceitar: probabilidade 0..1 de **ocorrer** emboscada (`1` = sempre tentar; `0.5` = metade das vezes nada).
        AmbushChance = 0.65,
    },
}

--- Emboscada ao **iniciar** desmanche (após skillcheck): missão no NPC e/ou aleatório. `Enable = false` desliga spawns.
Config.Ambush = {
    -- [GAMEPLAY] Ligado: emboscada é a ÚNICA fonte de fence_referral (destrava o fence).
    -- Com Enable=false, jogadores novos não conseguiam acessar o desmanche.
    Enable = true,
    --- Se `true`, aplica `Chance` + `CooldownSeconds` em cada desmanche (além de missões NPC).
    --- Se `false`, só resolução de **Config.NPC.Mission** na próxima desmontagem (com `Mission.AmbushChance` pode não haver hostil).
    RandomOnDismantle = true,
    --- Probabilidade 0..1 por tentativa quando `RandomOnDismantle` está ativo (valor alto = mais emboscadas).
    -- [GAMEPLAY] 0.05 = emboscada incomum (risco sem ser punitivo). Ajuste a gosto.
    Chance = 0.05,
    --- Pesos relativos do tipo de hostil: `pistol`, `dog`, `bat`. Omite ou tudo zero = equiprovável (1/3 cada).
    KindWeights = { pistol = 40, dog = 25, bat = 35 },
    --- Mínimo de segundos entre emboscadas por jogador.
    CooldownSeconds = 360,
    --- Apagar atacantes após (ms) se ainda existirem.
    DespawnMs = 180000,
    --- Distância atrás do jogador para spawn.
    SpawnBehindM = 7.0,
    --- Precisão 0-100 para atiradores.
    ShooterAccuracy = 38,
    HumanModels = { `g_m_y_mexgoon_03`, `g_m_y_famfor_01`, `g_m_y_ballasout_01` },
    DogModels = { `a_c_chop`, `a_c_rottweiler` },
    --- Chance (0.0-1.0) de dropar item fence_referral ao matar ped de emboscada.
    -- [GAMEPLAY] 0.5: como emboscada é incomum (Chance 0.05), o referral precisa ser
    -- provável QUANDO ela acontece, senão o fence fica inacessível na prática.
    ReferralDropChance = 0.5,
}

--- Recompensas por peça: [item] = { amount = n, chance = 0..1 }
Config.CarPartRewards = {
    -- Capô: chapa de alumínio + sucata de aço (~3.4 kg máx com novos pesos)
    bonnet = {
        aluminum   = { amount = 4, chance = 0.5 },
        metalscrap = { amount = 4, chance = 1.0 },
        steel      = { amount = 4, chance = 1.0 },
    },
    -- Porta-bagagens: estrutura similar ao capô, ligeiramente menor
    boot = {
        aluminum   = { amount = 3, chance = 0.5 },
        metalscrap = { amount = 4, chance = 1.0 },
        steel      = { amount = 4, chance = 1.0 },
    },
    -- Rodas: aro + borracha + sucata (~2.1 kg por roda)
    wheel_lf = {
        aluminum   = { amount = 3, chance = 1.0 },
        rubber     = { amount = 4, chance = 1.0 },
        metalscrap = { amount = 3, chance = 1.0 },
    },
    wheel_rf = {
        aluminum   = { amount = 3, chance = 1.0 },
        rubber     = { amount = 4, chance = 1.0 },
        metalscrap = { amount = 3, chance = 1.0 },
    },
    wheel_lr = {
        aluminum   = { amount = 3, chance = 1.0 },
        rubber     = { amount = 4, chance = 1.0 },
        metalscrap = { amount = 3, chance = 1.0 },
    },
    wheel_rr = {
        aluminum   = { amount = 3, chance = 1.0 },
        rubber     = { amount = 4, chance = 1.0 },
        metalscrap = { amount = 3, chance = 1.0 },
    },
    -- Portas: cobre (fiação) + plástico (painel) + vidro + estrutura de aço (~3.2 kg por porta)
    door_pside_r = {
        copper     = { amount = 2, chance = 1.0 },
        metalscrap = { amount = 3, chance = 1.0 },
        steel      = { amount = 3, chance = 1.0 },
        plastic    = { amount = 3, chance = 1.0 },
        glass      = { amount = 1, chance = 0.8 },
    },
    door_pside_f = {
        copper     = { amount = 2, chance = 1.0 },
        metalscrap = { amount = 3, chance = 1.0 },
        steel      = { amount = 3, chance = 1.0 },
        plastic    = { amount = 3, chance = 1.0 },
        glass      = { amount = 1, chance = 1.0 },
    },
    door_dside_r = {
        copper     = { amount = 2, chance = 1.0 },
        metalscrap = { amount = 3, chance = 1.0 },
        steel      = { amount = 3, chance = 1.0 },
        plastic    = { amount = 3, chance = 1.0 },
        glass      = { amount = 1, chance = 1.0 },
    },
    door_dside_f = {
        copper     = { amount = 2, chance = 1.0 },
        metalscrap = { amount = 3, chance = 1.0 },
        steel      = { amount = 3, chance = 1.0 },
        plastic    = { amount = 3, chance = 1.0 },
        glass      = { amount = 1, chance = 1.0 },
    },
}

--- Bench recipes (items only). Use labelKey matching shared/locale.lua, or legacy `label` string.
---@type { labelKey?: string, label?: string, duration: integer, inputs: table<string, integer>, outputs: table<string, integer> }[]
Config.BenchRecipes = {
    {
        labelKey = 'bench_compact_scrap',
        duration = 8000,
        inputs = { metalscrap = 25 },
        outputs = { steel = 3 },
    },
    {
        labelKey = 'bench_separate_copper',
        duration = 10000,
        inputs = { metalscrap = 15, plastic = 10 },
        outputs = { copper = 8 },
    },
    -- Integração qs-mechanic-creator: peças furtadas + sucata → kit de reparo para oficinas
    {
        labelKey = 'bench_repairkit',
        duration = 12000,
        inputs = { car_parts = 5, metalscrap = 10 },
        outputs = { repairkit = 1 },
    },
    -- Integração qs-mechanic-creator: borracha + plástico da carcaça → corda de recuperação
    {
        labelKey = 'bench_rope',
        duration = 8000,
        inputs = { rubber = 8, plastic = 5 },
        outputs = { rope = 1 },
    },
}

Config.ChopProgressMs = 12000
Config.RefuelProgressMs = 6000

--- Props visuais carregados pelo jogador ao desmontar uma peça.
--- model = nil desliga o prop visual (os materiais continuam a ser entregues na bancada).
--- Verifique se os modelos existem no seu servidor antes de usar.
Config.PartProps = {
    panel = { model = 'prop_chunk_metal01a', offset = { 0.12, 0.05,  0.0  }, rotation = { 0,  0,  0  } },
    wheel = { model = 'prop_cs_wheel_01',   offset = { 0.0,  0.1,  -0.12 }, rotation = { 90, 0,  0  } },
}
--- Mapeamento de partKey → categoria de prop ('panel' ou 'wheel').
Config.PartPropCategory = {
    bonnet       = 'panel', boot         = 'panel',
    door_dside_f = 'panel', door_pside_f = 'panel',
    door_dside_r = 'panel', door_pside_r = 'panel',
    wheel_lf     = 'wheel', wheel_rf     = 'wheel',
    wheel_lr     = 'wheel', wheel_rr     = 'wheel',
}

--- Descarte de veículo: após remover peças suficientes, o jogador pode descartar o carro por cash.
Config.Discard = {
    Enable = true,
    MinPartsToDiscard = 4,      -- mínimo de peças removidas para poder descartar
    DefaultPayout = 1500,       -- cash base ao descartar
    --- Bónus se houver polícias suficientes online.
    CopsBonus = {
        Enable = false,
        MinCops = 4,            -- mínimo de polícias online para ativar bónus
        Multiplier = 1.5,       -- multiplicador aplicado ao payout
        PoliceJobs = { 'police', 'sheriff', 'bcso' },
    },
    --- Payout específico por hash do modelo do veículo (substitui DefaultPayout).
    --- Exemplo: [GetHashKey('adder')] = 5000
    PayoutByModel = {},
}

--- Sons durante o desmanche (requer xsound iniciado).
Config.ChopSounds = {
    Enable = true,
    grinder   = { file = 'chopshop_grinder.ogg',           volume = 0.4 },
    pneumatic = { file = 'chopshop_pneumatic_hammer.ogg',   volume = 0.4 },
}

--- Animações por categoria de peça (configurável).
--- flag 1 = ANIM_FLAG_REPEAT (full-body loop). flag 49 (UPPERBODY+REPEAT) conflita com
--- animações full-body como fixing_a_player e deve ser evitado nesses casos.
Config.ChopAnimations = {
    --- Capô / porta-malas: corte com serra circular
    grinder   = { dict = 'anim@scripted@heist@ig16_glass_cut@male@', clip = 'cutting_loop', flag = 1 },
    --- Rodas / pneus: chave de impacto (full-body agachado)
    pneumatic = { dict = 'mini@repair', clip = 'fixing_a_player', flag = 1 },
    --- Portas (Fase 1 básica): corte com serra
    door      = { dict = 'anim@scripted@heist@ig16_glass_cut@male@', clip = 'cutting_loop', flag = 1 },
}

--- Integração de Dispatch (ex: ps-dispatch, cd_dispatch, qs-dispatch)
Config.Dispatch = {
    Enable = true,
    System = 'ps-dispatch', -- 'ps-dispatch' | 'cd_dispatch' | 'qs-dispatch'
}

--- Sistema de alarme veicular ao desmontar.
--- O alarme dispara com chance proporcional à classe do veículo (carros mais caros = maior risco).
--- Se não desarmado dentro da janela, a polícia é notificada.
Config.Alarm = {
    Enable = true,

    --- Probabilidade de alarme (0.0–1.0) por classe de veículo GTA (0–22).
    --- Classes omitidas usam DefaultChance.
    --- Classe 0=Compacts, 1=Sedans, 2=SUVs, 3=Coupes, 4=Muscle, 5=Sports Classics,
    ---       6=Sports, 7=Super, 8=Motos, 9=Off-Road, 10=Industrial, 11=Utility,
    ---       12=Vans, 17=Service, 18=Emergency, 19=Military, 20=Commercial, 22=OpenWheel
    ChanceByClass = {
        [0]  = 0.15,  -- Compacts (econômicos)
        [1]  = 0.20,  -- Sedans
        [2]  = 0.35,  -- SUVs
        [3]  = 0.35,  -- Coupes
        [4]  = 0.40,  -- Muscle
        [5]  = 0.50,  -- Sports Classics
        [6]  = 0.55,  -- Sports
        [7]  = 0.80,  -- Super (alto valor!)
        [8]  = 0.10,  -- Motos
        [9]  = 0.30,  -- Off-Road
        [10] = 0.10,  -- Industrial
        [11] = 0.10,  -- Utility
        [12] = 0.20,  -- Vans
        [17] = 0.15,  -- Service
        [18] = 0.65,  -- Emergency
        [19] = 0.75,  -- Military
        [20] = 0.15,  -- Commercial
        [22] = 0.70,  -- OpenWheel (corrida)
    },
    DefaultChance       = 0.25, -- fallback para classes não listadas acima
    DisarmWindowSeconds = 30,   -- segundos para desarmar antes de chamar a polícia
    DisarmDistance      = 6.0,  -- distância máxima (m) do ox_target de desarme

    --- Item necessário para iniciar o desarme do alarme.
    --- Use o mesmo item de Config.AdvancedChop.ScrewdriverItem para consistência.
    DisarmItem = 'screwdriver',

    --- Minigame de desarme: lib.skillCheck. `false` = desligado (desarme instantâneo).
    DisarmSkillCheck = {
        difficulties = { 'easy', 'medium' },
        keys         = { 'e', 'e' },
    },
}

-- [FASE1 placas] Roubo de placa física.
-- Jogador usa chave de fenda num veículo ALVO (não o próprio), passa o skillcheck e
-- arranca a placa → recebe item `stolen_plate` com metadata e o carro fica sem placa visível.
Config.Plates = {
    --- Liga/desliga a feature inteira (client e server).
    Enable = true,

    --- Distância máxima (m) jogador↔veículo validada no SERVIDOR (verdade).
    MaxDistance = 3.0,

    --- Cooldown anti-farm por jogador, em segundos (revalidado no servidor).
    StealCooldownSeconds = 30,

    --- Se true, só permite arrancar placa de veículos "owned" (reservado p/ Fase 2/3;
    --- na Fase 1 mantemos false — sem integração de garagem/ownership ainda).
    OwnedOnly = false,

    --- Minigame antes de arrancar (mesmo formato de Config.Alarm.DisarmSkillCheck →
    --- lib.skillCheck(difficulties, keys)). `false` desliga o minigame.
    SkillCheck = {
        difficulties = { 'easy', 'medium', 'medium' },
        keys         = { 'e', 'e', 'e' },
    },

    --- Ferramenta exigida (verificada no client p/ UX e no servidor como verdade).
    ToolItem = 'screwdriver',

    --- [F4 testemunhas] (LEGADO) Dispatch booleano ao roubar placa. Mantido por compat,
    --- mas SUBSTITUÍDO pelo sistema de testemunhas (Config.Plates.Witness abaixo): a chamada
    --- de polícia agora é PROBABILÍSTICA por testemunhas próximas, não um booleano fixo.
    --- Se Witness.Enable = false, caímos de volta neste booleano (comportamento antigo).
    DispatchOnSteal = true,

    -- ───────────────────────────────────────────────────────────────────────
    -- [F4 testemunhas] Dispatch por testemunhas (imersão): roubar placa em lugar
    -- vazio quase nunca chama a polícia; em lugar movimentado, a chance sobe.
    -- A contagem de testemunhas é client-side (peds NPC + players próximos); o BÔNUS
    -- por risco é reportado ao servidor com CAP server-side (low-stakes, ver server/plates.lua).
    -- ───────────────────────────────────────────────────────────────────────
    Witness = {
        --- Liga o sistema de testemunhas. false → usa o DispatchOnSteal booleano legado.
        Enable = true,
        --- Raio (m) para contar testemunhas ao redor do veículo/jogador.
        Radius = 45.0,
        --- Peso de cada NPC vivo não-player na contagem de "score".
        NpcWeight = 1.0,
        --- Peso de cada PLAYER próximo (exceto o autor). Player pesa mais que NPC.
        PlayerWeight = 3.0,
        --- Chance PISO de dispatch com 0 testemunhas (0.0–1.0). Lugar deserto = quase nunca.
        BaseChance = 0.02,
        --- Chance TETO de dispatch (0.0–1.0), por mais testemunhas que haja.
        MaxChance = 0.85,
        --- Quanto cada ponto de score soma à chance (linear, até MaxChance).
        ChancePerScore = 0.08,
        --- Modificador noturno (multiplicador da chance final entre StartHour e EndHour).
        --- < 1.0 reduz a chance de madrugada (menos gente acordada para denunciar).
        NightModifier = 0.6,
        NightStartHour = 1,   -- 01h
        NightEndHour   = 5,   -- 05h
        --- BÔNUS por risco: roubo BEM-SUCEDIDO com testemunhas perto rende extra.
        --- XP bônus máximo (server aplica proporcional ao score, com CAP).
        BonusXp = 10,
        --- Cash bônus MÁXIMO (server aplica proporcional ao score, com CAP). 0 = sem cash.
        BonusCashMax = 150,
        --- Score mínimo (testemunhas) para QUALQUER bônus disparar (evita bônus em deserto).
        BonusMinScore = 2.0,
    },

    -- ───────────────────────────────────────────────────────────────────────
    -- [FASE2 placas] Forja + aplicação de placa falsa (disfarce de consulta MDT).
    -- ───────────────────────────────────────────────────────────────────────

    --- Tier mínimo de progressão para FORJAR placa falsa na bancada (gate via
    --- VPChopGetProgression). Fase 2 = tier 2.
    ForgeTier = 2,

    --- Insumos consumidos na forja, ALÉM da `stolen_plate` específica (que doa a
    --- placa-fonte). { item = quantidade }. Ajustável.
    ForgeInputs = {
        plastic  = 2,
        aluminum = 1,
    },

    --- XP concedido ao forjar com sucesso (reason 'fake_plate' na XP_TABLE).
    ForgeXp = 22,

    --- Cooldown anti-farm da FORJA, por jogador, em segundos (revalidado no servidor).
    ForgeCooldownSeconds = 15,

    --- Cooldown anti-spam da APLICAÇÃO de placa falsa, por jogador, em segundos.
    ApplyCooldownSeconds = 5,

    --- Distância máxima (m) jogador↔veículo ao APLICAR placa falsa (verdade server-side).
    ApplyMaxDistance = 4.0,

    --- Raio (m) do broadcast filtrado de placa visível (aplicar/remover/restaurar).
    --- Espelha o ~150u do roubo, mas cosmético → mantemos generoso.
    VisibleSyncRadius = 200.0,

    --- [F3 garagem] DEPRECADO / SEM EFEITO. Antes bloqueava aplicar placa falsa em carro
    --- owned. Agora a placa falsa é permitida em QUALQUER carro: a proteção contra a garagem
    --- salvar a falsa é feita pelo hook de garagem (export vp_chopshop:GetRealPlateForProps
    --- chamado no parkVehicle do qbx_garages, que reverte para a placa REAL antes de salvar).
    --- Mantido como `false` apenas por compatibilidade de config; o código não o consulta mais.
    BlockOnOwned = false,

    --- [F2 persist] Persistência total da placa falsa. true → o disfarce sobrevive a restart
    --- e é re-aplicado quando o veículo (owned) reaparece (entityCreated em server/plates.lua).
    --- O mapeamento só é removido pela POLÍCIA ou remoção manual — guardar o carro NÃO remove.
    Persist = true,

    --- Jobs policiais que podem REMOVER a placa falsa (furar o disfarce).
    PoliceJobs = { 'police', 'bcso', 'sheriff' },

    --- Cooldown anti-spam da REMOÇÃO policial, por jogador, em segundos.
    RemoveCooldownSeconds = 3,
}

--- Ferramentas de desmanche niveladas por item.
--- despatchChance: chance 0..1 de alertar a polícia (1.0 = sempre).
--- speedMult: multiplicador do tempo da barra de progresso (0.5 = metade do tempo).
Config.Tools = {
    ['saw_cheap'] = {
        MaxUses = 2,
        dispatchChance = 1.0,
        speedMult = 1.4,
        HandProp = {
            model    = 'prop_tool_consaw',
            offset   = { 0.05, 0.02, 0.0 },
            rotation = { 20, 0, -50 },
        },
    },
    ['saw_pro'] = {
        MaxUses = 6,
        dispatchChance = 0.25,
        speedMult = 1.0,
        HandProp = {
            model    = 'prop_tool_consaw',
            offset   = { 0.05, 0.02, 0.0 },
            rotation = { 20, 0, -50 },
        },
    },
    ['mechanic_drill'] = {
        MaxUses = 10,
        dispatchChance = 0.0,
        speedMult = 0.7,
        HandProp = {
            model    = 'prop_tool_screwflt01',
            offset   = { 0.10, 0.03, 0.0 },
            rotation = { 10, 0, -30 },
        },
    },
}

--- Máquina de solda: objeto colocável (item do inventário). Obrigatória perto da bancada para
--- craftear/entregar peças. Raio de detecção: WelderBenchRadius metros.
Config.WelderModel       = `lr_smodd_cm_weldmachine_001`
Config.WelderBenchRadius = 8.0
Config.MinWelderSpacing  = 4.0

-- [L2 FIX] Config.LiftAnimation removido — exclusivo do sistema de elevador removido.

-- ─────────────────────────────────────────────────────────────────────────────
-- SISTEMA DE PNEUS — venda direta ao NPC + missões de roubo
-- ─────────────────────────────────────────────────────────────────────────────

--- Venda de pneus a um NPC comprador (pneus removidos no elevador ou roubados em missão).
--- O jogador guarda o pneu numa pickup truck → dirige até o NPC → recebe cash.
Config.TyreSelling = {
    Enable = true,

    --- Modelos de pickup trucks aceites para guardar pneus na caçamba.
    PickupTruckModels = {
        'bison', 'bison3', 'bobcatxl', 'sandking', 'sandking2',
        'rebel', 'rebel2', 'kamacho', 'youga2', 'crusader', 'rancherxl',
    },

    --- Máximo de pneus que cabem na caçamba.
    MaxTyresInTruck = 4,

    --- Preço por pneu ao vender.
    PricePerTyre = 400,

    --- NPC comprador. TROQUE as coordenadas para o seu servidor.
    NpcModel  = 'g_m_m_mexboss_01',
    NpcCoords = vector4(2343.53, 3143.0, 48.2, 169.1),  -- Sandy Shores (padrão)

    --- Caixa de entrega (onde o jogador larga os pneus antes de fechar negócio).
    CrateCoords = vector3(2345.7, 3141.2, 47.5),

    Blip = {
        Enable = true,
        Sprite = 431,
        Color  = 25,
        Scale  = 0.75,
        Label  = 'Comprador de Pneus',
    },
}

--- Missões de roubo de pneus: um NPC dá o contrato, o jogador vai ao veículo alvo,
--- rouba os 4 pneus com minigame de parafusos (lib.skillCheck) e entrega ao NPC vendedor.
Config.TyreMission = {
    Enable = false, -- [L1 FIX] TyreMissionStart() é stub não implementado; desabilitado para evitar "Erro." no menu fence.



    --- Cooldown entre contratos (segundos por jogador).
    MissionCooldown = 300,

    --- NPC que oferece os contratos. TROQUE as coordenadas para o seu servidor.
    NpcModel  = 'g_m_m_mexboss_01',
    NpcCoords = vector4(408.38, -1928.53, 24.88, 355.0),  -- LSIA area (padrão)

    NpcBlip = {
        Enable = true,
        Sprite = 480,
        Color  = 28,
        Scale  = 0.75,
        Label  = 'Missões de Pneus',
    },

    --- Modelos de veículos alvo spawnados.
    VehicleModels = {
        'sultanrs', 'cavalcade', 'issi8', 'buffalo5',
        'dominator2', 'buffalo4', 'asea', 'rhinehart',
    },

    --- Localizações onde o veículo alvo aparece (aleatório). AJUSTE ao seu mapa.
    TargetLocations = {
        { x =  888.0,  y = -1768.0, z = 29.0, h = 267.3 },
        { x = 1202.9,  y = -1383.0, z = 34.6, h = 359.0 },
        { x =  -55.3,  y = -1097.5, z = 26.4, h = 119.0 },
        { x =  355.2,  y = -1544.6, z = 29.3, h = 170.0 },
    },

    --- Cash bônus por completar missão (4 pneus roubados + vendidos).
    BonusReward = 800,

    --- Minigame por pneu: cada round = 1 parafuso solto (lib.skillCheck).
    MinigameRounds = 3,
    MinigameDifficulties = { 'easy', 'medium', 'medium' },
}

--- Macaco hidráulico portátil: levanta qualquer carro para roubar pneus sem precisar do elevador nacelle.
--- Fluxo: usa item → coloca 4 macacos → carro sobe → targets de pneus aparecem → rouba → baixa carro.
--- O item chopshop_jackstand precisa ser registado em ox_inventory (ver installation/ox_items_snippet.txt).
--- Sistema de desmanche avançado por fases (requer veículo levantado no macaco).
--- Fase 2: Portas / Capô / Porta-malas  → requer serra metálica → 1× car_parts por peça
--- Fase 3: Motor                         → capô removido + chave de fenda → 5× car_parts
--- Fase 4: Carcaça                       → motor removido + soldadora perto → recicláveis
Config.AdvancedChop = {
    Enable = true,

    --- Item necessário para desmontar portas/capô/porta-malas (Fase 2).
    SawItem = 'metal_saw',

    --- Item necessário para desmontar o motor (Fase 3).
    ScrewdriverItem = 'screwdriver',

    --- Raio máximo (m) para detetar soldadora perto do veículo (Fase 4).
    WelderRadius = 8.0,

    --- Duração das barras de progresso (ms).
    DoorProgressMs    = 6000,
    EngineProgressMs  = 8000,
    CarcassProgressMs = 10000,

    --- Recompensa por cada peça de porta/capô/porta-malas (Fase 2).
    DoorReward = { item = 'car_parts', amount = 1 },

    --- Recompensa por desmontar o motor (Fase 3).
    EngineReward = { item = 'car_parts', amount = 5 },

    --- Recompensas ao cortar a carcaça (Fase 4). chance: 0.0–1.0
    CarcassRewards = {
        { item = 'metalscrap', amount = 8, chance = 1.0 },
        { item = 'glass',      amount = 2, chance = 0.7 },
        { item = 'plastic',    amount = 5, chance = 0.8 },
        { item = 'rubber',     amount = 3, chance = 0.6 },
    },

    --- Animação e prop da mão para desmanche de portas/capô/porta-malas (Fase 2).
    SawAnim = {
        dict = 'anim@scripted@heist@ig16_glass_cut@male@',
        clip = 'cutting_loop',
        flag = 1,
        prop = {
            model    = 'prop_tool_consaw',
            offset   = { 0.05, 0.02, 0.0 },
            rotation = { 20, 0, -50 },
        },
    },

    --- Animação e prop da mão para remoção do motor (Fase 3).
    EngineAnim = {
        dict = 'mini@repair',
        clip = 'fixing_a_player',
        flag = 1,
        prop = {
            model    = 'prop_tool_screwflt01',
            offset   = { 0.10, 0.03, 0.0 },
            rotation = { 10, 0, -30 },
        },
    },

    --- Animação e prop da mão para corte da carcaça (Fase 4).
    --- flag 1 = ANIM_FLAG_REPEAT — mantém o loop enquanto a barra roda.
    CarcassAnim = {
        dict = 'anim@scripted@heist@ig16_glass_cut@male@',
        clip = 'cutting_loop',
        flag = 1,
        prop = {
            model    = 'v_ind_cs_powersaw',
            offset   = { 0.10, 0.05, 0.0 },
            rotation = { 15, 0, -55 },
        },
    },
}

Config.Jackstand = {
    Enable = true,

    --- Item do inventário que acciona o macaco.
    Item = 'chopshop_jackstand',

    --- Item dado ao inventário ao roubar um pneu com o macaco.
    TyreItem = 'chopshop_tyre',

    --- Prop GTA V do macaco (nativo, sem stream extra necessário).
    PropModel = `imp_prop_axel_stand_01a`,

    --- Altura (unidades GTA) que o carro sobe ao ser levantado.
    LiftHeight = 0.18,

    --- Duração da barra "A colocar macacos..." (ms).
    LiftProgressMs = 8000,

    --- Duração da barra "A retirar macacos..." (ms).
    LowerProgressMs = 5000,

    --- Animação ao COLOCAR o macaco.
    --- amb@world_human_vehicle_mechanic@male@base/base = ped ajoelha de lado e trabalha
    --- ao nível do chão (idêntico ao wheel_theft). Mais realista que mini@repair.
    RaiseAnim = {
        dict = 'amb@world_human_vehicle_mechanic@male@base',
        clip = 'base',
        flag = 1,
        prop = {
            model    = 'prop_tool_wrench',
            offset   = { 0.12, 0.03, 0.0 },
            rotation = { 0, 0, -60 },
        },
    },

    --- Animação ao RETIRAR o macaco.
    LowerAnim = {
        dict = 'amb@world_human_vehicle_mechanic@male@base',
        clip = 'base',
        flag = 1,
        prop = {
            model    = 'prop_tool_wrench',
            offset   = { 0.12, 0.03, 0.0 },
            rotation = { 0, 0, -60 },
        },
    },

    --- Raio máximo do carro para acionar o macaco (metros).
    MaxCarDistance = 5.0,

    --- Minigame de remoção de pneu (requer boii_minigames).
    --- Type: 'skill_circle' | 'button_mash'
    --- Rounds: número de parafusos por pneu
    --- Se boii_minigames não estiver a correr, usa lib.skillCheck como fallback.
    Minigame = {
        --- 'skill_circle' | 'button_mash'
        Type       = 'skill_circle',
        --- Número de parafusos por pneu (rounds do minigame)
        Rounds     = 4,
        --- Tempo máximo (ms) aguardando resposta do minigame antes de resolver como falha
        Timeout    = 30000,
        --- Chance extra de falhar mesmo passando no minigame (0.0 = desligado, 0.15 = 15%)
        FailureChance = 0.0,
        --- Item obrigatório no inventário para usar o jackstand (nil/'' = sem requisito)
        RequiredTool = nil,
        -- skill_circle: tamanho da área alvo (maior = mais fácil)
        AreaSize   = 5,
        -- skill_circle: velocidade de rotação (menor = mais fácil)
        Speed      = 0.025,
        -- button_mash: dificuldade (1=fácil … 20=difícil)
        Difficulty = 12,
        -- fallback lib.skillCheck (quando boii_minigames não estiver ativo)
        SkillCheckDifficulties = { 'easy', 'medium', 'medium', 'hard' },
        SkillCheckKeys         = { 'e', 'e', 'e', 'e' },
    },
}

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

    --- Bônus noturno na venda e entrega de carros.
    NightBonus = {
        Enable = true,
        StartHour = 21,
        EndHour = 6,
        Multiplier = 1.3,
    },

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
        stolen_plate  = 250,  -- [FASE1 placas] placa física vendável no fence
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

--- ─────────────────────────────────────────────────────────────────────────────
--- [EVIDENCE] INTEGRAÇÃO FORENSE — resource `evidences` (Advanced FiveM evidence)
--- ─────────────────────────────────────────────────────────────────────────────
--- Toda ação de crime do chopshop pode deixar VESTÍGIO no local (digital + DNA),
--- vinculado biometricamente ao criminoso. A polícia coleta e identifica via o
--- próprio resource `evidences`. Esta feature é 100% server-side e CONSOME a API
--- do evidences (export `syncEvidence`). Se o resource não estiver `started`,
--- ela se auto-desativa sem quebrar nenhuma ação de crime.
Config.Evidence = {
    Enable = true,                 -- [EVIDENCE] liga/desliga; auto-desativa se 'evidences' não estiver started
    GlovesItem = 'gloves',         -- [EVIDENCE] item que, no inventário, BLOQUEIA digitais (checado server-side)
    GlovesBlocksDna = false,       -- [EVIDENCE] luvas bloqueiam digital; DNA ainda cai (true = luvas bloqueiam tudo)
    DnaType = 'blood',             -- [EVIDENCE] classe de DNA plantada: 'blood' | 'saliva'
    HeatScaling = true,            -- [EVIDENCE] mais heat na placa = mais chance de vestígio
    HeatFactor = 0.5,              -- [EVIDENCE] intensidade do scaling (chance_final = base * (1 + heat/100 * HeatFactor))
    -- [EVIDENCE] chance base 0..1 por ação (fingerprint e dna independentes).
    -- Digital com chance MAIOR (toca tudo); DNA com chance MENOR (corte/suor pontual).
    Actions = {
        chop_part   = { fingerprint = 0.50, dna = 0.12 },
        vin_scratch = { fingerprint = 0.70, dna = 0.15 },
        plate_steal = { fingerprint = 0.60, dna = 0.10 },
        plate_forge = { fingerprint = 0.40, dna = 0.05 },
        plate_apply = { fingerprint = 0.50, dna = 0.08 },
    },
}

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  [TYRE] Marcas de pneu — pista forense de FUGA (100% interna ao vp_chopshop) ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
--- [TYRE] Conceito: após um crime do chopshop, o criminoso fica "armado" por uma
--- janela curta. Se ele CANTAR PNEU / DAR BURNOUT ao fugir, deixa uma marca no
--- chão. A polícia examina e descobre APENAS o MODELO/CLASSE do veículo que fugiu
--- (ex.: "Marcas de pneu de um Sultan RS (Esportivo)"). NUNCA revela a placa —
--- pneu não fala placa. É pista FRACA (aponta o tipo de carro, não a pessoa).
--- Counterplay: fugir dirigindo calmo (sem cantar pneu) NÃO deixa marca.
--- Feature transiente — SEM tabela de DB; marcas vivem em memória com TTL.
Config.TyreMarks = {
    --- [TYRE] Liga/desliga a feature inteira (client + server).
    Enable = true,

    --- [TYRE] Janela (s) após o crime em que o criminoso fica "armado": só nessa
    --- janela um burnout deixa marca. Depois disso, desarma sozinho no client.
    ArmWindowSeconds = 45,

    --- [TYRE] Tempo de vida (s) da marca no servidor (evidência transiente). Após
    --- isso ela é removida da memória e some dos clientes da polícia.
    MarkTTLSeconds = 600,

    --- [TYRE] Máximo de marcas que UM crime (uma janela armada) pode gerar — evita
    --- que um burnout prolongado pinte o asfalto inteiro de pistas.
    MaxMarksPerCrime = 2,

    --- [TYRE] Distância (m) máxima para a polícia conseguir examinar a marca
    --- (revalidada server-side no callback).
    ExamineDistance = 3.0,

    --- [TYRE] Cooldown (ms) anti-spam entre detecções de burnout no client.
    BurnoutCooldownMs = 3000,

    --- [TYRE] Cooldown (ms) por jogador no evento server de criar marca (anti-flood).
    CreateCooldownMs = 1500,

    --- [TYRE] Jobs policiais que veem/examina as marcas. Reusa a lista de placas
    --- por padrão; pode-se definir uma lista própria aqui se quiser divergir.
    PoliceJobs = { 'police', 'bcso', 'sheriff' },

    --- [TYRE] Limiar de detecção de burnout. Burnout = roda girando MUITO mais
    --- rápido que o deslocamento real do carro (patinação). Comparamos
    --- |GetVehicleWheelSpeed| (vel. linear das rodas, m/s) com GetEntitySpeed
    --- (vel. real do chassi, m/s). Se as rodas giram além de (real * Ratio) E
    --- acima de MinWheelSpeed, é patinação/cantada de pneu.
    Burnout = {
        Ratio         = 1.8,   -- rodas precisam girar ≥ 1.8x a vel. real do carro
        MinWheelSpeed = 6.0,   -- e ≥ 6 m/s de giro de roda (ignora manobras lentas)
        MaxRealSpeed  = 12.0,  -- e carro a ≤ 12 m/s (burnout real é parado/lento; em alta vel. não conta)
    },

    --- [TYRE] Mapa classe GTA (0..22) → nome pt-BR exibido no exame.
    --- Fonte: GetVehicleClass (native CFX). Cobre todas as 0..22 do build atual.
    ClassNames = {
        [0]  = 'Compacto',
        [1]  = 'Sedan',
        [2]  = 'SUV',
        [3]  = 'Cupê',
        [4]  = 'Muscle',
        [5]  = 'Esportivo Clássico',
        [6]  = 'Esportivo',
        [7]  = 'Super',
        [8]  = 'Motocicleta',
        [9]  = 'Off-road',
        [10] = 'Industrial',
        [11] = 'Utilitário',
        [12] = 'Van',
        [13] = 'Bicicleta',
        [14] = 'Barco',
        [15] = 'Helicóptero',
        [16] = 'Avião',
        [17] = 'Serviço',
        [18] = 'Emergência',
        [19] = 'Militar',
        [20] = 'Comercial',
        [21] = 'Trem',
        [22] = 'Animal/Outro',
    },
}
