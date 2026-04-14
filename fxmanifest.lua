fx_version 'cerulean'
game 'gta5'
-- [L1 FIX] lua54 'yes' removido — Lua 5.4 é o padrão desde junho/2025; a diretiva foi depreciada.

name 'vp_chopshop'
author 'HAZE STUDIOS - LORD 32 DEV'
description 'Chop shop with lift and bench — ox_lib, ox_target, ox_inventory, oxmysql. Locales: en, pt, es, fr, tr.'
version '1.5.0'

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
    'client/lifts.lua',
    -- [L3 FIX] client/tyres.lua e client/npc.lua removidos — tombstones vazios; carga desnecessária eliminada.
    'client/bench.lua',
    'client/welder.lua',
    'client/fence.lua',
    'client/progression.lua',
    'client/alarm.lua',
    'client/main.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/server_framework.lua',
    'bridge/server_inventory.lua',
    'bridge/mdt.lua',
    'server/db.lua',
    'server/validate.lua',
    'server/cooldown.lua',
    'server/discord.lua',
    'server/chop.lua',
    'server/bench.lua',
    'server/heat.lua',
    'server/ambush.lua',
    'server/fence.lua',
    'server/progression.lua',
    'server/advanced_chop.lua',
    'server/main.lua',
}

data_file 'DLC_ITYP_REQUEST' 'stream/nacelle.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/lr_supermod_garage_int.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/wheel_spacer.ytyp'  -- tipo para bolt.ydr (minigame de parafusos)

files {
    'installation/ox_items_snippet.txt',
    'stream/*.ydr',
    'stream/*.ytyp',
    'stream/*.ybn',
    'sounds/*.ogg',
}
