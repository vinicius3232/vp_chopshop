-- bridge/workshop_custom_example.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.17 BROKER-4] TEMPLATE DE ADAPTADOR DE OFICINA EXTERNA (EXEMPLO)
--
--  Este arquivo serve como documentação de referência e template para criar
--  um adapter cross-resource conectando um sistema de mecânicos/oficina
--  externo ao vp_chopshop.
--
--  REGRAS CRÍTICAS DE INTEGRAÇÃO:
--  1) O Provider DEVE ser idempotente por txnId.
--  2) PreparePurchase NUNCA deve debitar ou pagar dinheiro; apenas cotar e travar termos.
--  3) CommitPurchase pode ser invocado múltiplas vezes em cenários de retry/recovery;
--     o pagamento REAL deve ser executado exatamente 1 vez por txnId.
--  4) GetTransactionStatus deve refletir com precisão se a transação foi paga ('COMMITTED'),
--     cancelada/rejeitada ('ABORTED'), cotada ('PREPARED') ou se o estado é incerto ('UNKNOWN').
--  5) AbortPurchase deve retornar true apenas quando confirma categoricamente que nenhum
--     pagamento foi ou será realizado para aquele txnId.
--  6) NÃO carregar este arquivo automaticamente no fxmanifest do vp_chopshop.
-- ═══════════════════════════════════════════════════════════════════════════════

local CustomWorkshopAdapter = {
    ResourceName = 'my_custom_workshop', -- Nome do resource da sua oficina
}

--- Indica se o sistema da oficina está online e pronto para aceitar entregas.
---@return boolean
function CustomWorkshopAdapter.IsAvailable()
    -- Exemplo: verificar se o resource externo está rodando
    if GetResourceState(CustomWorkshopAdapter.ResourceName) ~= 'started' then
        return false
    end
    return true
end

--- Recebe uma intenção de entrega de peça e devolve a cotação/preço da oficina.
--- NÃO DEVE EFETUAR PAGAMENTO NESTA ETAPA.
---@param txnId string ID único da transação gerado pelo vp_chopshop (ex: 'ws:my_custom_workshop:...')
---@param context table Dados da peça ({ assetKind, partKey, commodity, provenance, metadata, trustLevel, etc. })
---@return { ok: boolean, price?: number, expiresAt?: number, err?: string }
function CustomWorkshopAdapter.PreparePurchase(txnId, context)
    -- Exemplo: consultar demanda interna da oficina ou society balance
    local offeredPrice = 3500 -- Preço ofertado pela oficina (deve ser > 0 e <= MaxPrice)
    local expiresAt = os.time() + 45 -- Validade da cotação em segundos (dentro de PrepareMaxTtlSec)

    -- Persistir localmente a intenção no estado 'PREPARED' vinculada ao txnId
    -- MyWorkshopDB.SavePreparedTxn(txnId, offeredPrice, expiresAt)

    return {
        ok        = true,
        price     = offeredPrice,
        expiresAt = expiresAt,
    }
end

--- Efetua a liquidação financeira definitiva da transação.
--- DEVE SER ESTRITAMENTE IDEMPOTENTE: se chamado 2x com o mesmo txnId, paga apenas 1x.
---@param txnId string
---@return { ok: boolean, paid?: boolean, err?: string }
function CustomWorkshopAdapter.CommitPurchase(txnId)
    -- Exemplo:
    -- local txn = MyWorkshopDB.GetTxn(txnId)
    -- if not txn then return { ok = false, err = 'txn_not_found' } end
    -- if txn.state == 'COMMITTED' then return { ok = true, paid = true } end -- Idempotência!
    --
    -- local paid = MySociety.DebitAndPay(txn.targetAccount, txn.price)
    -- if paid then
    --     MyWorkshopDB.SetState(txnId, 'COMMITTED')
    --     return { ok = true, paid = true }
    -- end
    -- return { ok = false, err = 'payment_failed' }

    return {
        ok   = true,
        paid = true,
    }
end

--- Consulta o estado autoritativo de uma transação no sistema da oficina.
--- Usado durante o boot recovery e background reconciliation do vp_chopshop.
---@param txnId string
---@return 'PREPARED'|'COMMITTED'|'ABORTED'|'UNKNOWN'
function CustomWorkshopAdapter.GetTransactionStatus(txnId)
    -- Exemplo:
    -- local txn = MyWorkshopDB.GetTxn(txnId)
    -- if not txn then return 'UNKNOWN' end
    -- return txn.state -- 'PREPARED', 'COMMITTED', 'ABORTED'

    return 'COMMITTED'
end

--- Cancela uma transação em andamento se o commit não tiver ocorrido.
---@param txnId string
---@return boolean confirmedCancelled Retorna true apenas se confirmou ZERO pagamento
function CustomWorkshopAdapter.AbortPurchase(txnId)
    -- Exemplo:
    -- local txn = MyWorkshopDB.GetTxn(txnId)
    -- if txn and txn.state == 'COMMITTED' then return false end -- Não pode cancelar se já pagou!
    -- MyWorkshopDB.SetState(txnId, 'ABORTED')
    return true
end

--- (Opcional) Retorna dados de demanda/sinal de mercado para a economia do Broker.
---@param query table
---@return table|nil
function CustomWorkshopAdapter.GetMarketSignal(query)
    return {
        activeDemand = {
            adv_engine = 1.30,
            catalytic_converter = 1.15,
        },
        urgency = 'high',
    }
end

-- ─── Registro no WorkshopBridge do vp_chopshop ────────────────────────────────
-- Se este script estiver rodando dentro do seu resource de oficina, registre-se assim:
--
-- exports.vp_chopshop:WorkshopRegisterProvider('my_custom_workshop', CustomWorkshopAdapter)
--
-- Ou no arquivo bridge/workshop.lua do vp_chopshop:
-- WorkshopBridge.RegisterProvider('my_custom_workshop', CustomWorkshopAdapter)

return CustomWorkshopAdapter