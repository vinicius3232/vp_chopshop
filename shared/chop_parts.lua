---@class ChopPartDef
---@field labelKey string locale key in shared/locale.lua
---@field kind 'door'|'tyre'
---@field index integer

--- Dismantlable parts: GTA natives (doors / tyres). Labels via `L(def.labelKey)`.
ChopParts = {
    bonnet = { labelKey = 'part_bonnet', kind = 'door', index = 4 },
    boot = { labelKey = 'part_boot', kind = 'door', index = 5 },
    door_dside_f = { labelKey = 'part_door_dside_f', kind = 'door', index = 0 },
    door_pside_f = { labelKey = 'part_door_pside_f', kind = 'door', index = 1 },
    door_dside_r = { labelKey = 'part_door_dside_r', kind = 'door', index = 2 },
    door_pside_r = { labelKey = 'part_door_pside_r', kind = 'door', index = 3 },
    wheel_lf = { labelKey = 'part_wheel_lf', kind = 'tyre', index = 0 },
    wheel_rf = { labelKey = 'part_wheel_rf', kind = 'tyre', index = 1 },
    wheel_lr = { labelKey = 'part_wheel_lr', kind = 'tyre', index = 4 },
    wheel_rr = { labelKey = 'part_wheel_rr', kind = 'tyre', index = 5 },
}

--- Lista estável para menus (ordem de exibição).
ChopPartOrder = {
    'bonnet', 'boot',
    'door_dside_f', 'door_pside_f', 'door_dside_r', 'door_pside_r',
    'wheel_lf', 'wheel_rf', 'wheel_lr', 'wheel_rr',
}
