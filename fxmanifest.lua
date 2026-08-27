fx_version 'cerulean'
game 'gta5'
-- [L1 FIX] lua54 'yes' removido — Lua 5.4 é o padrão desde junho/2025; a diretiva foi depreciada.

name 'vp_chopshop'
author 'HAZE STUDIOS - LORD 32 DEV'
description 'Chop shop with lift and bench — ox_lib, ox_target, ox_inventory, oxmysql. Locales: en, pt, es, fr, tr.'
version '1.14.3'

dependencies {
    'ox_lib',
    'ox_inventory',
    'ox_target',
    'oxmysql',
}

shared_scripts {
    '@ox_lib/init.lua',
    'shared/events.lua',
    'shared/config.lua',
    'shared/locale.lua',
    'shared/chop_parts.lua',
}

client_scripts {
    'bridge/client_notify.lua',
    'client/placement.lua',
    'client/carry.lua',  -- [L2 FIX] renomeado de lifts.lua (elevador removido; contém carry system)
    -- [L3 FIX] client/tyres.lua e client/npc.lua removidos — tombstones vazios; carga desnecessária eliminada.
    -- [SERIAL] antes de bench.lua (bench usa VPChopSerialBenchOptions) e main.lua.
    'client/partserial.lua',
    'client/bench.lua',
    'client/welder.lua',
    'client/fence.lua',
    'client/progression.lua',
    'client/alarm.lua',
    'client/plates.lua',  -- [FASE1 placas] antes de main.lua (usa VPChopTriggerDispatch dele em runtime)
    'client/tyremarks.lua',  -- [TYRE] marcas de pneu (armar burnout + ox_target da polícia); antes de main.lua
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/server_framework.lua',
    'bridge/server_inventory.lua',
    'bridge/mdt.lua',
    -- [EVIDENCE] ponte forense: usa InvCount (server_inventory) e VPChopMDT (mdt);
    -- expõe VPChopLeaveEvidence para os arquivos de crime abaixo. DEPOIS das bridges,
    -- ANTES de db.lua/heat.lua/plates.lua/main.lua.
    'bridge/evidence.lua',
    'server/db.lua',
    'server/validate.lua',
    -- [v1.15 arch] ChopSession — fonte server-authoritative do estado de desmanche.
    -- Depois de validate.lua (usa Validate*) e das bridges (IsValidSource, InvCount,
    -- ServerPlayerIsReady); ANTES de chop.lua / advanced_chop.lua / main.lua (futuros
    -- consumidores) e do jackstand server-side.
    'server/session/chop_session.lua',
    'server/session/chop_session_spec.lua',  -- self-gated: só roda com convar vp_chopshop_selftest 1
    'server/session/jackstand.lua',
    -- [v1.15 P1-1] gate de autoridade do advanced chop (VPChopAdvRequireRaisedSession);
    -- antes de server/advanced_chop.lua.
    'server/session/adv_gate.lua',
    'server/session/adv_gate_spec.lua',      -- self-gated (vp_chopshop_selftest 1)
    -- [v1.15 PR-B] fachada do estado de peça do BASE CHOP sobre a ChopSession;
    -- antes de server/chop.lua (que delega a ela).
    'server/session/base_state.lua',
    'server/session/base_state_spec.lua',    -- self-gated (vp_chopshop_selftest 1)
    -- [v1.15 PR-C] fachada do estado de peça do ADVANCED CHOP; antes de
    -- server/advanced_chop.lua (AdvState/AdvMutex removidos).
    'server/session/advanced_state.lua',
    'server/session/advanced_state_spec.lua', -- self-gated
    'server/cooldown.lua',
    'server/discord.lua',
    'server/chop.lua',
    'server/bench.lua',
    'server/heat.lua',
    'server/ambush.lua',
    'server/fence.lua',
    'server/progression.lua',
    -- [SERIAL] número de série da car_parts. Depois de db.lua (helpers de série),
    -- progression.lua (VPChopGetProgression) e bridges (Inv*, Bridge*, IsValidSource);
    -- ANTES de advanced_chop.lua (que usa VPChopAddStolenCarParts) e main.lua.
    'server/partserial.lua',
    -- [FASE1 placas] depois de heat.lua e progression.lua (usa VPChopMDT, Validate*, Inv*,
    -- VPChopEvt e o listener de PART_CHOPPED da progressão), antes de main.lua.
    'server/plates.lua',
    -- [TYRE] marcas de pneu: usa BridgeIsPolice, IsValidSource e VPChopMDT.ReportActivity;
    -- DEPOIS de bridge/mdt.lua e server/plates.lua.
    'server/tyremarks.lua',
    'server/advanced_chop.lua',
    'server/main.lua',
}

data_file 'DLC_ITYP_REQUEST' 'stream/nacelle.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/lr_supermod_garage_int.ytyp'
-- [FIX] wheel_spacer.ytyp É o archetype do bolt.ydr (o parafuso do minigame). O arquivo está
-- em stream/, mas a linha de registro abaixo havia sido removida → o archetype 'bolt' nunca
-- registrava, RequestModel('bolt') falhava e o minigame caía no modo marcador. Registrado de
-- volta: agora o parafuso 3D carrega. (O modo marcador continua como fallback automático.)
data_file 'DLC_ITYP_REQUEST' 'stream/wheel_spacer.ytyp'

files {
    'installation/ox_items_snippet.txt',
    'stream/*.ydr',
    'stream/*.ytyp',
    'stream/*.ybn',
    'sounds/*.ogg',
}
