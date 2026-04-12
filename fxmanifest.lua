fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'vp_chopshop'
author 'VP / scaffold for Qbox'
description 'Chop shop with lift and bench — ox_lib, ox_target, ox_inventory, oxmysql. Locales: en, pt, es, fr, tr.'
version '1.3.6'

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
    'client/tyres.lua',
    'client/npc.lua',
    'client/bench.lua',
    'client/welder.lua',
    'client/fence.lua',
    'client/progression.lua',
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
    'server/npc.lua',
    'server/heat.lua',
    'server/ambush.lua',
    'server/fence.lua',
    'server/progression.lua',
    'server/tyres.lua',
    'server/advanced_chop.lua',
    'server/main.lua',
}

data_file 'DLC_ITYP_REQUEST' 'stream/nacelle.ytyp'
data_file 'DLC_ITYP_REQUEST' 'stream/lr_supermod_garage_int.ytyp'

files {
    'installation/ox_items_snippet.txt',
    'stream/*.ydr',
    'stream/*.ytyp',
    'stream/*.ybn',
    'sounds/*.ogg',
}
