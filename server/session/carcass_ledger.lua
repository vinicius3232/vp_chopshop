-- server/session/carcass_ledger.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.16 P0.4] Ledger PERSISTENTE de carcaças já processadas (discard / deliverCar).
--
--  Problema (Fase 20 do RC): o "tombstone" do discard é a ChopSession em estado
--  COMPLETED — EM MEMÓRIA. O marcador `vpChopDeliveredMark` do deliverCar é um
--  statebag SERVER-LOCAL. Os dois sobrevivem a `ensure vp_chopshop` só enquanto a
--  entidade não some. Depois de um restart de RESOURCE, a ChopSession é perdida:
--  um jogador pode criar uma sessão nova na MESMA carcaça, re-chopar 4 peças e
--  descartá-la DE NOVO → 2º pagamento. Dupe real.
--
--  Este ledger grava (net_id, model) + vsid + op no DB no commit terminal. O
--  callback de discard consulta ANTES de pagar. TTL curto porque net_id é
--  reciclável (a resolução do TTL fica no DB).
--
--  Sem MySQL aqui — as funções de DB são INJETADAS (`_setDb`). Testável direto no
--  harness; `server/db.lua` faz o wiring real (as funções existem no load de
--  db.lua, que vem ANTES deste arquivo no fxmanifest).
--
--  NÃO substitui a barreira do deliverCar: o statebag `vpChopDeliveredMark`
--  continua sendo a autoridade de pagamento ali (ele sobrevive ao restart de
--  resource, o único em que a carcaça transiente sobrevive). O ledger, para o
--  deliverCar, serve só ao sweep de boot (re-dirigir o cleanup preso).
-- ═══════════════════════════════════════════════════════════════════════════════

VPChopCarcassLedger = {}

--- @class CarcassDbImpl
--- @field lookup      fun(netId:integer, model:integer):table|nil   -- {op,vsid,cleanup_pending,age} dentro do TTL, senão nil
--- @field mark        fun(netId:integer, model:integer, vsid:string|nil, op:string, paidTo:string|nil, cleanupPending:integer):any
--- @field clear       fun(netId:integer, model:integer|nil)         -- model nil = limpa todas as linhas do net_id
--- @field loadPending fun():table[]
local DB = nil

--- Injeta a camada de DB. `server/db.lua` chama isto no load; o spec injeta um fake.
--- @param impl CarcassDbImpl|nil
function VPChopCarcassLedger._setDb(impl) DB = impl end

--- Normaliza um hash de modelo para a forma canônica uint32. `GetEntityModel` /
--- `GetHashKey` no FiveM podem devolver o MESMO hash como int32 negativo OU uint32
--- positivo dependendo do caminho — `& 0xFFFFFFFF` colapsa os dois na mesma chave,
--- garantindo que `mark` e `lookup` batam. Exposto para o sweep de boot comparar.
--- @param m any
--- @return integer
function VPChopCarcassLedger.normModel(m)
    return (math.floor(tonumber(m) or 0)) & 0xFFFFFFFF
end
local nm = VPChopCarcassLedger.normModel

--- @return boolean ready  o ledger tem uma camada de DB utilizável?
function VPChopCarcassLedger.ready() return DB ~= nil and DB.lookup ~= nil end

--- Esta carcaça (net_id + model) já foi discard/deliver e ainda consta no ledger
--- (dentro do TTL)? O re-chop re-tagueia o `vpChopVsid` da entidade, então a
--- identidade confiável aqui é (net_id, model) + TTL — resolvido no DB.
--- @param netId integer
--- @param model integer|number
--- @return boolean processed, string|nil op   ('discard' | 'deliver')
function VPChopCarcassLedger.alreadyProcessed(netId, model)
    if not (DB and DB.lookup) then return false end
    local ok, row = pcall(DB.lookup, math.floor(tonumber(netId) or 0), nm(model))
    if not ok or type(row) ~= 'table' then return false end
    return true, row.op
end

--- Grava a carcaça no ledger (idempotente por PK net_id+model).
--- @param netId integer
--- @param model integer|number
--- @param vsid string|nil          audit/forense — nunca é a identidade da checagem
--- @param op 'discard'|'deliver'
--- @param paidTo string|nil
--- @param cleanupPending boolean    a entidade AINDA existe no mundo (delete falhou/pendente)?
--- @return boolean ok
function VPChopCarcassLedger.mark(netId, model, vsid, op, paidTo, cleanupPending)
    if not (DB and DB.mark) then return false end
    local ok = pcall(DB.mark, math.floor(tonumber(netId) or 0), nm(model),
        vsid, op, paidTo, cleanupPending and 1 or 0)
    return ok == true
end

--- Remove a carcaça do ledger (delete de mundo confirmado / entityRemoved).
--- @param netId integer
--- @param model integer|number|nil   nil = limpa todas as linhas do net_id
--- @return boolean ok
function VPChopCarcassLedger.clear(netId, model)
    if not (DB and DB.clear) then return false end
    local ok = pcall(DB.clear, math.floor(tonumber(netId) or 0),
        model ~= nil and nm(model) or nil)
    return ok == true
end

--- Linhas com cleanup_pending=1 dentro do TTL — para o sweep de boot.
--- @return table[]
function VPChopCarcassLedger.loadPending()
    if not (DB and DB.loadPending) then return {} end
    local ok, rows = pcall(DB.loadPending)
    if not ok or type(rows) ~= 'table' then return {} end
    return rows
end

-- ─── Wiring real (nop no harness: as funções VPChopDbCarcass* não existem lá) ──
if VPChopDbCarcassLookup then
    VPChopCarcassLedger._setDb({
        lookup      = VPChopDbCarcassLookup,
        mark        = VPChopDbCarcassMark,
        clear       = VPChopDbCarcassClear,
        loadPending = VPChopDbCarcassLoadPending,
    })
end
