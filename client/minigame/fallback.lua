-- client/minigame/fallback.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [UX-A] Minigame Fallback Foundation
--  Acionado quando um veículo não possui bones adequados ou quando ocorre falha
--  de geometria/câmera, garantindo que o gameplay nunca trave silenciosamente.
-- ═══════════════════════════════════════════════════════════════════════════════

_G.VPChopMinigameFallback = function(vehicle, partKey, reason)
    local modelHash = (vehicle and DoesEntityExist(vehicle)) and GetEntityModel(vehicle) or 0
    if Config.Debug then
        print(('[vp_chopshop][MINIGAME_FALLBACK] modelHash=%s | part=%s | reason=%s'):format(
            tostring(modelHash),
            tostring(partKey),
            tostring(reason or 'unknown')
        ))
    end

    local jmg   = Config.Jackstand and Config.Jackstand.Minigame
    local diffs = (jmg and jmg.SkillCheckDifficulties) or { 'easy', 'medium', 'medium' }
    local keys  = (jmg and jmg.SkillCheckKeys)         or { 'e', 'e', 'e' }
    local passed = lib.skillCheck(diffs, keys)
    if not passed then
        VPChopNotify(L('tyremission_minigame_fail'), 'error')
    end
    return passed == true
end

return _G.VPChopMinigameFallback
