-- server/session/carcass_ledger_spec.lua
-- ═══════════════════════════════════════════════════════════════════════════════
--  [v1.16 P0.4] Self-test do ledger persistente de carcaças. Self-gated na convar
--  vp_chopshop_selftest 1. A camada de DB é um FAKE em memória com seams para
--  simular erro / TTL. O TTL real vive no SQL (VPChopDbCarcassLookup) e é coberto
--  no TEST_PLAN de servidor, não aqui.
-- ═══════════════════════════════════════════════════════════════════════════════

if (GetConvarInt and GetConvarInt('vp_chopshop_selftest', 0) or 0) ~= 1 then return end

local pass, fail, total = 0, 0, 0
local function check(name, cond)
    total = total + 1
    if cond then pass = pass + 1; print('[carcass_ledger/spec] PASS  ' .. name)
    else fail = fail + 1; print('[carcass_ledger/spec] FAIL  ' .. name) end
end

-- ─── Fake DB em memória ──────────────────────────────────────────────────────
local STORE            -- [key "net|model"] = { op, vsid, paid_to, cleanup_pending }
local LOOKUP_THROWS    -- simula erro de query no lookup
local MARK_THROWS
local CLEAR_THROWS
local LOADPENDING_THROWS
local EXPIRED          -- set de keys tratadas como fora do TTL (lookup devolve nil)

local function key(n, m) return tostring(math.floor(n)) .. '|' .. tostring(math.floor(m)) end

local function reset()
    STORE, EXPIRED = {}, {}
    LOOKUP_THROWS, MARK_THROWS, CLEAR_THROWS, LOADPENDING_THROWS = false, false, false, false
end

local FAKE_DB = {
    lookup = function(n, m)
        if LOOKUP_THROWS then error('simulated lookup failure') end
        local k = key(n, m)
        if EXPIRED[k] then return nil end          -- fora do TTL → o DB não devolve
        local r = STORE[k]
        if not r then return nil end
        return { op = r.op, vsid = r.vsid, cleanup_pending = r.cleanup_pending, age = 1 }
    end,
    mark = function(n, m, vsid, op, paidTo, cp)
        if MARK_THROWS then error('simulated mark failure') end
        STORE[key(n, m)] = { op = op, vsid = vsid, paid_to = paidTo, cleanup_pending = cp }
    end,
    clear = function(n, m)
        if CLEAR_THROWS then error('simulated clear failure') end
        if m == nil then
            for k in pairs(STORE) do
                if k:match('^' .. tostring(math.floor(n)) .. '|') then STORE[k] = nil end
            end
        else
            STORE[key(n, m)] = nil
        end
    end,
    loadPending = function()
        if LOADPENDING_THROWS then error('simulated loadPending failure') end
        local out = {}
        for k, r in pairs(STORE) do
            if r.cleanup_pending == 1 then
                local net, mod = k:match('^(%d+)|(%d+)$')
                out[#out + 1] = { net_id = tonumber(net), model = tonumber(mod), vsid = r.vsid, op = r.op }
            end
        end
        return out
    end,
}

-- ─── CL0: normModel colapsa int32-negativo e uint32-positivo na mesma chave ───
check('CL0 normModel(uint32 positivo) estável',   VPChopCarcassLedger.normModel(2621027814) == 2621027814)
check('CL0 normModel(int32 negativo) == uint32',  VPChopCarcassLedger.normModel(-1673939482) == 2621027814)
check('CL0 normModel(hash pequeno) inalterado',   VPChopCarcassLedger.normModel(555) == 555)
check('CL0 normModel(nil) = 0',                    VPChopCarcassLedger.normModel(nil) == 0)

-- ─── CL1: sem DB injetado → degradação graciosa ──────────────────────────────
reset()
VPChopCarcassLedger._setDb(nil)
check('CL1 ready()=false sem DB',                VPChopCarcassLedger.ready() == false)
check('CL1 alreadyProcessed=false sem DB',       select(1, VPChopCarcassLedger.alreadyProcessed(10, 999)) == false)
check('CL1 mark=false sem DB',                   VPChopCarcassLedger.mark(10, 999, nil, 'discard', 'p1', true) == false)
check('CL1 clear=false sem DB',                  VPChopCarcassLedger.clear(10, 999) == false)
check('CL1 loadPending={} sem DB',               #VPChopCarcassLedger.loadPending() == 0)

-- ─── daqui em diante: DB fake injetado ───────────────────────────────────────
VPChopCarcassLedger._setDb(FAKE_DB)

-- CL2 — fresh
reset()
check('CL2 ready()=true com DB',                 VPChopCarcassLedger.ready() == true)
local p2 = VPChopCarcassLedger.alreadyProcessed(20, 555)
check('CL2 carcaça nova → não processada',       p2 == false)

-- CL3 — mark discard → detectado
reset()
check('CL3 mark(discard) ok',                    VPChopCarcassLedger.mark(20, 555, 'vsid:9', 'discard', 'p1', true) == true)
local p3, op3 = VPChopCarcassLedger.alreadyProcessed(20, 555)
check('CL3 alreadyProcessed=true',               p3 == true)
check('CL3 op=discard',                          op3 == 'discard')

-- CL3b — mark com hash int32-NEGATIVO, lookup com o MESMO hash uint32-POSITIVO → bate
reset()
VPChopCarcassLedger.mark(25, -1673939482, nil, 'discard', 'p1', true)
check('CL3b lookup(positivo) acha a linha marcada com negativo',
    (VPChopCarcassLedger.alreadyProcessed(25, 2621027814)) == true)

-- CL4 — mark deliver → detectado com op deliver
reset()
VPChopCarcassLedger.mark(21, 556, nil, 'deliver', 'p2', false)
local p4, op4 = VPChopCarcassLedger.alreadyProcessed(21, 556)
check('CL4 alreadyProcessed=true (deliver)',     p4 == true)
check('CL4 op=deliver',                          op4 == 'deliver')

-- CL5 — clear remove a barreira
reset()
VPChopCarcassLedger.mark(22, 557, nil, 'discard', 'p1', true)
check('CL5 antes do clear: processado',          (VPChopCarcassLedger.alreadyProcessed(22, 557)) == true)
check('CL5 clear ok',                            VPChopCarcassLedger.clear(22, 557) == true)
check('CL5 depois do clear: não processado',     (VPChopCarcassLedger.alreadyProcessed(22, 557)) == false)

-- CL6 — net_id igual, model diferente = linhas independentes (PK composta)
reset()
VPChopCarcassLedger.mark(30, 100, nil, 'discard', 'p1', true)
check('CL6 (30,100) processado',                 (VPChopCarcassLedger.alreadyProcessed(30, 100)) == true)
check('CL6 (30,200) NÃO processado',             (VPChopCarcassLedger.alreadyProcessed(30, 200)) == false)

-- CL7 — clear(net, nil) limpa todas as linhas do net_id (uso no entityRemoved)
reset()
VPChopCarcassLedger.mark(31, 100, nil, 'discard', 'p1', true)
VPChopCarcassLedger.mark(31, 200, nil, 'deliver', 'p1', true)
VPChopCarcassLedger.clear(31, nil)
check('CL7 clear(net,nil) limpou (31,100)',      (VPChopCarcassLedger.alreadyProcessed(31, 100)) == false)
check('CL7 clear(net,nil) limpou (31,200)',      (VPChopCarcassLedger.alreadyProcessed(31, 200)) == false)

-- CL8 — TTL: linha fora do TTL (DB devolve nil) → não é barreira
reset()
VPChopCarcassLedger.mark(40, 300, nil, 'discard', 'p1', true)
EXPIRED[key(40, 300)] = true
check('CL8 linha expirada → não processada',     (VPChopCarcassLedger.alreadyProcessed(40, 300)) == false)

-- CL9 — erro de query no lookup → fail-safe (não bloqueia, não crasha)
reset()
VPChopCarcassLedger.mark(41, 301, nil, 'discard', 'p1', true)
LOOKUP_THROWS = true
check('CL9 lookup que dá erro → alreadyProcessed=false', (VPChopCarcassLedger.alreadyProcessed(41, 301)) == false)

-- CL10 — erro em mark/clear/loadPending → retorno false/{} sem crash
reset()
MARK_THROWS = true
check('CL10 mark que dá erro → false',           VPChopCarcassLedger.mark(42, 302, nil, 'discard', 'p1', true) == false)
MARK_THROWS = false
VPChopCarcassLedger.mark(42, 302, nil, 'discard', 'p1', true)
CLEAR_THROWS = true
check('CL10 clear que dá erro → false',          VPChopCarcassLedger.clear(42, 302) == false)
LOADPENDING_THROWS = true
check('CL10 loadPending que dá erro → {}',        #VPChopCarcassLedger.loadPending() == 0)

-- CL11 — loadPending devolve só cleanup_pending=1
reset()
VPChopCarcassLedger.mark(50, 400, nil, 'discard', 'p1', true)   -- pendente
VPChopCarcassLedger.mark(51, 401, nil, 'discard', 'p1', false)  -- já deletada
local pend = VPChopCarcassLedger.loadPending()
check('CL11 loadPending traz só a pendente',      #pend == 1 and pend[1].net_id == 50)

-- CL12 — mark idempotente por PK (re-mark atualiza, não duplica)
reset()
VPChopCarcassLedger.mark(60, 500, 'vsid:1', 'discard', 'p1', true)
VPChopCarcassLedger.mark(60, 500, 'vsid:2', 'discard', 'p1', false)   -- delete confirmado depois
check('CL12 re-mark não vira 2 linhas pendentes', #VPChopCarcassLedger.loadPending() == 0)
check('CL12 ainda processado',                    (VPChopCarcassLedger.alreadyProcessed(60, 500)) == true)

print(('[carcass_ledger/spec] ─── RESUMO: %d/%d PASS, %d FAIL ───'):format(pass, total, fail))
