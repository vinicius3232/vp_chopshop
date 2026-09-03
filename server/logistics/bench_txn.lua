-- server/logistics/bench_txn.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [FIX-1.1] TRANSAÇÃO DO PROCESSAMENTO DE PEÇA NA BANCADA — AUTHORITY ÚNICA.
--
--  Este módulo concentra a ORDEM da transação de `vp_chopshop:benchProcessPart`
--  a partir do ponto em que os gates de contexto (player/rate/bench/distância/
--  param/allowlist de modo) já passaram. É o MESMO código executado pelo runtime
--  e pelos testes (`client/minigame/minigame_spec.lua` → FIX1-TXN-*), sem espelho.
--
--  ORDEM INVIOLÁVEL (uma falha antes do commit NÃO pode perder o `hammer`):
--    1) PartEntitlement.Validate            → err = <validate reason>
--    2) política de modo por partKey         → err = 'invalid_mode_for_part'
--    3) gate do token de desmonte (VALIDAÇÃO, sem consumo)
--                                            → err = 'teardown_required'|'too_fast'|'expired'
--    4) build outputs (deps.buildOutputs)
--    5) capacidade de inventário             → err = 'inventory_full'
--    6) CONSUMO TERMINAL do `hammer` (revalida posse + remove)   → err = 'no_hammer'
--    7) PartEntitlement.Consume (commit at-most-once)
--         └─ falhou → REFUND do hammer; refund falhou → err='refund_failed' + onRefundFail
--
--  O token server-side garante CONTEXTO e DURAÇÃO MÍNIMA. A UX/NUI é client-side
--  e não é prova de execução do minigame — o anti-dupe real é o at-most-once do
--  PartEntitlement, não o token.
-- ═══════════════════════════════════════════════════════════════════════════════

VPChopBenchTxn = VPChopBenchTxn or {}

--- Executa a transação da bancada.
---@param params table {
---   source: number,
---   entitlementId: string,
---   mode: string,                 -- já validado contra ALLOWED_BENCH_MODES pelo caller
---   teardownToken: any,
---   buildOutputs: fun(partKey:string, ent:table, mode:string): table[]  -- itemsToGrant
--- }
---@param deps table {
---   now: fun(): number,                          -- GetGameTimer no runtime
---   PartEntitlement: table?,                     -- default: global PartEntitlement
---   teardownRequired: fun(partKey:string): boolean,  -- teardownRequired() do server
---   teardownState: fun(src:number): table|nil,   -- _benchTeardowns[src]
---   clearTeardown: fun(src:number),              -- _benchTeardowns[src] = nil
---   InvCount: fun(src:number, item:string): number,
---   InvRemove: fun(src:number, item:string, n:number): boolean,
---   InvAdd: fun(src:number, item:string, n:number): boolean,
---   InvCanCarry: fun(src:number, item:string, n:number, meta:any): boolean,
---   hammerItem: string,
---   onRefundFail: fun(src:number, entitlementId:string)?  -- marker CRITICAL/quarentena
--- }
---@return table result {
---   ok: boolean, err: string?,
---   ent: table?, partKey: string?, itemsToGrant: table[]?,
---   hammerConsumed: boolean, refundFailed: boolean
--- }
function VPChopBenchTxn.run(params, deps)
    local src = params.source
    local PE  = deps.PartEntitlement or PartEntitlement
    local result = { ok = false, hammerConsumed = false, refundFailed = false }

    if not (PE and PE.Validate and PE.Consume) then
        result.err = 'internal'
        return result
    end

    -- 1) Validação do entitlement (ANTES de qualquer efeito colateral)
    local okVal, ent = PE.Validate(params.entitlementId, src)
    if not okVal then
        if PE.LogSuspicious and (ent == 'owner_mismatch' or ent == 'already_consumed') then
            PE.LogSuspicious(src, ent, ('entitlement: %s'):format(tostring(params.entitlementId)))
        end
        result.err = ent
        return result
    end
    local partKey = ent.partKey
    result.ent, result.partKey = ent, partKey
    local needTeardown = deps.teardownRequired(partKey) == true

    -- 2) Política estrita de modo por partKey (catalisador só vira raw_materials)
    if partKey == 'catalytic_converter' and params.mode ~= 'raw_materials' then
        if PE.LogSuspicious then
            PE.LogSuspicious(src, 'disallowed_mode_for_catalytic', tostring(params.mode))
        end
        result.err = 'invalid_mode_for_part'
        return result
    end

    -- 3) Gate do token de desmonte — VALIDAÇÃO apenas, SEM consumo
    if needTeardown then
        local td = deps.teardownState(src)
        if type(params.teardownToken) ~= 'string' or not td
            or td.token ~= params.teardownToken or td.entId ~= params.entitlementId then
            if PE.LogSuspicious then
                PE.LogSuspicious(src, 'bench_teardown_missing_token', tostring(params.teardownToken))
            end
            result.err = 'teardown_required'
            return result
        end
        local now = deps.now()
        if now < (td.startedAt + td.minMs - 250) then
            if PE.LogSuspicious then
                PE.LogSuspicious(src, 'bench_teardown_too_fast',
                    ('elapsed=%d min=%d'):format(now - td.startedAt, td.minMs))
            end
            result.err = 'too_fast'
            return result
        end
        if now > td.expiresAt then
            deps.clearTeardown(src)      -- expired é terminal, fail-closed
            result.err = 'expired'
            return result
        end
    end

    -- 4) Build dos outputs (Config-driven no runtime; stub no spec)
    local itemsToGrant = params.buildOutputs(partKey, ent, params.mode) or {}
    result.itemsToGrant = itemsToGrant

    -- 5) Capacidade de inventário ANTES do consume irreversível
    for _, reward in ipairs(itemsToGrant) do
        if not deps.InvCanCarry(src, reward.item, reward.amount, reward.metadata) then
            result.err = 'inventory_full'
            return result
        end
    end

    -- 6) CONSUMO TERMINAL do hammer — revalida a posse e só então remove.
    --    Falha em QUALQUER passo acima NÃO chega aqui → hammer intacto.
    if needTeardown then
        if deps.InvCount(src, deps.hammerItem) < 1 or not deps.InvRemove(src, deps.hammerItem, 1) then
            result.err = 'no_hammer'
            return result
        end
        result.hammerConsumed = true
        deps.clearTeardown(src)  -- token consumido: replay do mesmo token → 'teardown_required'
    end

    -- 7) Commit at-most-once do entitlement
    local res = PE.Consume(params.entitlementId, src, 'bench_' .. tostring(params.mode))
    if not res.ok then
        -- Commit não ocorreu → devolve o hammer.
        if result.hammerConsumed then
            local okAdd = deps.InvAdd(src, deps.hammerItem, 1)
            if okAdd == false or okAdd == nil then
                -- Refund NÃO confirmado. NÃO mascarar como sucesso: marca para suporte.
                result.refundFailed = true
                if deps.onRefundFail then deps.onRefundFail(src, params.entitlementId) end
                result.err = 'refund_failed'
                return result
            end
        end
        result.err = res.err
        return result
    end

    result.ok = true
    result.consume = res
    return result
end

return VPChopBenchTxn
