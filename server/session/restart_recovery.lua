-- server/session/restart_recovery.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.16 P0.4] Sweep de boot do ledger de carcaças (vp_chop_carcass).
--
--  Depois de `ensure vp_chopshop`, o retry timer do cleanup de mundo (discard e
--  deliverCar) morre com a memória. Carcaças que ficaram no mundo por falha de
--  delete (`cleanupPending`) viram lixo permanente. Este sweep, no dbReady:
--    · para cada linha pendente cuja entidade AINDA existe (net_id + model batem):
--        re-dispara BridgeDeleteWorldVehicle (retomada da operação já paga);
--    · para linhas cuja entidade sumiu (restart de SERVIDOR, ou já removida):
--        limpa a linha órfã.
--
--  NÃO é uma reconciliação ativa de estado (a regra do RESTART_RECOVERY_STUDY:
--  não persistir/reconciliar "porque sim"). É só terminar o que ficou pendente.
-- ═══════════════════════════════════════════════════════════════════════════════

AddEventHandler('vp_chopshop:server:dbReady', function()
    local cfg = Config.RestartRecovery or {}
    if cfg.Enable == false then return end
    if not (VPChopCarcassLedger and VPChopCarcassLedger.ready()) then return end

    CreateThread(function()
        Wait(math.floor(tonumber(cfg.BootSweepDelayMs) or 5000))

        local rows = VPChopCarcassLedger.loadPending()
        if #rows == 0 then return end

        local nm = VPChopCarcassLedger.normModel
        local deleted, stuck, orphan, unmatched = 0, 0, 0, 0
        for _, row in ipairs(rows) do
            local netId = math.floor(tonumber(row.net_id) or 0)
            local model = nm(row.model)
            local v = netId ~= 0 and NetworkGetEntityFromNetworkId(netId) or 0
            local alive = v ~= 0 and DoesEntityExist(v) and nm(GetEntityModel(v)) == model

            if not alive then
                -- entidade não existe: restart de SERVIDOR (entidade transiente sumiu),
                -- ou já foi removida por outra via → linha órfã.
                VPChopCarcassLedger.clear(netId, model)
                orphan = orphan + 1
            else
                -- A entidade em (net_id, model) existe. Mas net_id + model NÃO é chave
                -- única entre boots — pode ser um veículo NOVO que herdou o net_id.
                -- Só re-deleta se o `vsid` da linha bate com o statebag vpChopVsid vivo
                -- (que sobrevive a restart de RESOURCE, mas some no de servidor / não
                -- existe num carro que nunca foi chopado). Sem match ⇒ NÃO tocar.
                local okv, liveVsid = pcall(function() return Entity(v).state.vpChopVsid end)
                local match = row.vsid ~= nil and row.vsid ~= '' and okv and liveVsid == row.vsid

                if not match then
                    unmatched = unmatched + 1   -- deixa a linha; o TTL a expira sozinha
                elseif cfg.BootSweepDelete == false then
                    stuck = stuck + 1
                elseif BridgeDeleteWorldVehicle then
                    local d = BridgeDeleteWorldVehicle(v, {})
                    if not d.existsAfter then
                        VPChopCarcassLedger.clear(netId, model)
                        deleted = deleted + 1
                    else
                        stuck = stuck + 1
                        print(('[vp_chopshop][restart-recovery] carcaça netId %s (%s) ainda presa (method=%s) — ledger mantido')
                            :format(netId, tostring(row.op), tostring(d.method)))
                    end
                end
            end
        end

        print(('[vp_chopshop][restart-recovery] sweep: %d pendentes · %d deletadas · %d presas · %d órfãs · %d sem match de vsid (ignoradas)')
            :format(#rows, deleted, stuck, orphan, unmatched))
    end)
end)
