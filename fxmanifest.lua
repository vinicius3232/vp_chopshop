fx_version 'cerulean'
game 'gta5'
-- [L1 FIX] lua54 'yes' removido — Lua 5.4 é o padrão desde junho/2025; a diretiva foi depreciada.

name 'vp_chopshop'
author 'HAZE STUDIOS - LORD 32 DEV'
description 'Chop shop with lift and bench — ox_lib, ox_target, ox_inventory, oxmysql. Locales: en, pt, es, fr, tr.'
version '1.15.0-rc1'

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
    -- [P1.1] Part/Tool Registry — fonte da definição de peça. Tool antes de Part.
    'shared/registry/tools.lua',
    'shared/registry/parts.lua',
    -- [P2.1] VPChopPartGtaClass — acessor legado sobre o registry. DEPOIS de registry/parts.lua.
    'shared/part_class.lua',
    'shared/action_gate.lua',   -- [v1.15 PR-G] predicate ActionSession vs legacy (client+server)
}

ui_page 'html/index.html'

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
    -- [UX-A / UX-C / UX-D / UX-E] Módulos do minigame de interação física (carregados antes de main.lua)
    'client/minigame/camera.lua',
    'client/minigame/projection.lua',
    'client/minigame/profiles/panels.lua',
    'client/minigame/profiles/engine.lua',
    'client/minigame/profiles/carcass.lua',
    'client/minigame/profiles.lua',
    'client/minigame/fallback.lua',
    'client/minigame/core.lua',
    'client/minigame/demo.lua',
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/server_framework.lua',
    'bridge/server_inventory.lua',
    'bridge/mdt.lua',
    -- [v1.15 PR-D] ponte de persistência/deleção de veículo (QBox: DisablePersistence
    -- + qbx_vehicles ownership lookup). Usa VPChopMDT.GetRealPlate em runtime → depois
    -- de mdt.lua. Expõe Bridge{ResolveVehiclePersistence,DeleteWorldVehicle} p/ o discard.
    'bridge/server_vehicle.lua',
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
    -- [v1.15 PR-D] fachada da operação terminal de descarte (contagem unificada
    -- base+advanced, BEGIN/ROLLBACK/COMPLETE). Antes de server/main.lua (discard).
    'server/session/discard_state.lua',
    'server/session/discard_state_spec.lua',  -- self-gated
    -- [v1.15 PR-H] utilitários testáveis do terminal hardening de fence:deliverCar
    -- (marcador server-local + retry de deleção). ANTES de server/fence.lua.
    'server/session/deliver_car_util.lua',
    'server/session/deliver_car_spec.lua',    -- [v1.15 PR-H] self-gated (fence:deliverCar hardening)
    -- [v1.16 P0.4] ledger persistente de carcaças (discard/deliver) + sweep de boot.
    -- carcass_ledger DEPOIS de server/db.lua (usa VPChopDbCarcass*); restart_recovery
    -- DEPOIS de carcass_ledger e bridge/server_vehicle.lua. ANTES de fence.lua/main.lua.
    'server/session/carcass_ledger.lua',
    'server/session/carcass_ledger_spec.lua', -- self-gated (vp_chopshop_selftest 1)
    'server/session/restart_recovery.lua',
    -- [v1.15 PR-E] logística física de pneu: entitlement por peça real + storage do
    -- truck com identidade própria. Depois da ChopSession (usa GetPartState/Origin);
    -- antes de server/fence.lua (loadToTruck/sellTyres) e server/main.lua (Issue no chop).
    'server/logistics/tyre_entitlement.lua',
    'server/logistics/truck_storage.lua',
    'server/logistics/tyre_entitlement_spec.lua',  -- self-gated
    -- [v1.16 SEC-1] logística física de peças de carro e catalisador: entitlement autoritativo
    'server/logistics/part_entitlement.lua',
    'server/logistics/part_entitlement_spec.lua',  -- self-gated (vp_chopshop_selftest 1)
    -- [v1.15 PR-F] ActionSession core (autorização temporal + commit). Depois da
    -- ChopSession; usa VPChopHasTool/VPChopChopPartCommit em runtime (main.lua carrega
    -- depois). O executor de domínio (base_tyre) carrega DEPOIS de main.lua.
    'server/session/action_session.lua',
    'server/session/action_session_spec.lua',  -- self-gated
    -- [v1.17 BROKER-1] Dynamic Broker Market Engine & Sim
    'server/broker/market.lua',
    'server/broker/market_sim_spec.lua',  -- self-gated (vp_chopshop_selftest 1)
    -- [v1.17 BROKER-3] Contracts & High-Demand Lists Domain
    'server/broker/contracts.lua',
    'server/broker/contracts_spec.lua',   -- self-gated (vp_chopshop_selftest 1)
    -- [SPIKE PR-I] self-test dos registries (shared/registry/*.lua). Self-gated.
    'shared/registry/registry_spec.lua',
    'server/cooldown.lua',
    'server/discord.lua',
    'server/chop.lua',
    'server/bench.lua',
    'server/heat.lua',
    'server/ambush.lua',
    'server/fence.lua',
    'server/broker/fence_integration_spec.lua',  -- [v1.17 BROKER-2] self-gated (vp_chopshop_selftest 1)
    'server/progression.lua',
    -- [INT-01A] ponte vp_chopshop → vp_gangs (contractVersion 1). Escuta VPChopEvt.PART_CHOPPED
    -- pós-commit. DEPOIS de chop_session.lua (usa ChopSession.GetByVehicle) e progression.lua.
    -- ÚNICO arquivo que conhece exports.vp_gangs. Fail-safe se vp_gangs stopped.
    'bridge/vp_gangs.lua',
    'bridge/vp_gangs_spec.lua',  -- self-gated (vp_chopshop_selftest 1)
    -- [SERIAL] número de série da car_parts. Depois de db.lua (helpers de série),
    -- progression.lua (VPChopGetProgression) e bridges (Inv*, Bridge*, IsValidSource);
    -- ANTES de advanced_chop.lua (que usa VPChopAddStolenCarParts) e main.lua.
    'server/partserial.lua',
    'server/partserial_spec.lua',  -- self-gated (vp_chopshop_selftest 1)
    -- [FASE1 placas] depois de heat.lua e progression.lua (usa VPChopMDT, Validate*, Inv*,
    -- VPChopEvt e o listener de PART_CHOPPED da progressão), antes de main.lua.
    'server/plates.lua',
    -- [TYRE] marcas de pneu: usa BridgeIsPolice, IsValidSource e VPChopMDT.ReportActivity;
    -- DEPOIS de bridge/mdt.lua e server/plates.lua.
    'server/tyremarks.lua',
    'server/advanced_chop.lua',
    'server/main.lua',
    -- [v1.15 PR-F] executor de domínio da ActionSession p/ BASE TYRE. DEPOIS de
    -- main.lua (usa VPChopChopPartCommit) e de action_session.lua (RegisterExecutor).
    'server/action/base_tyre.lua',
    -- [v1.15 PR-G] executores + contratos da ActionSession p/ o desmanche AVANÇADO.
    -- DEPOIS de server/advanced_chop.lua (usa VPChopAdv{Door,Engine,Carcass}Commit).
    'server/action/advanced_chop.lua',
}

-- [P0.2b] stream/ removido por completo. Continha só:
--   · bolt.ydr + wheel_spacer.ytyp — parafuso 3D do minigame, do pacote PAGO
--     `ls_bolt_minigame` (o minigame roda em modo marcador, DrawMarker, sem asset);
--   · nacelle.* + lr_supermod_* — props do ELEVADOR, removido do sistema há tempo
--     (só o macaco `imp_prop_axel_stand_01a`, base game, é usado — Config.Jackstand).
-- Nenhum é referenciado no código. Repo vai a público → sem IP de terceiros.

files {
    'installation/ox_items_snippet.txt',
    'sounds/*.ogg',
    'html/**',
}
