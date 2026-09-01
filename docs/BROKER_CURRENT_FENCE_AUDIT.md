# BROKER CURRENT FENCE AUDIT — vp_chopshop v1.17

**Data:** 2026-09-01 (Revisão BROKER-0.1)  
**Autor:** Lead Gameplay Systems Architect & Security Engineer  
**Status:** ESTUDO / AUDITORIA CONCLUÍDA — RECOMENDAÇÃO DE MICRO-HARDENING P1 NA v1.16  
**Alvo:** `server/fence.lua`, `client/fence.lua`, `server/main.lua`, `shared/config.lua`, `server/db.lua`

---

## 1. Visão Geral do Sistema Atual de Fence

O sistema de Fence (`server/fence.lua` e `client/fence.lua`) funciona como o ponto central de liquidação econômica ilegal do `vp_chopshop` até a v1.16. Ele unificou antigos scripts fragmentados em um único NPC rotativo.

### Características Principais:
1. **Spawn & Rotação:**
   - 4 localizações configuradas em `Config.Fence.Locations` (`Sandy Shores`, `LSIA`, `La Mesa`, `Paleto Bay`).
   - Rotação automática a cada `Config.Fence.RotationMinutes` (45 min).
   - Ped server-side com modelo `g_m_m_mexboss_01`, congelado e invencível client-side via `vp_chopshop:client:setupFenceNpc`.
2. **Sistema de Trust & Progressão:**
   - Níveis de Trust de 0 a 4 armazenados na tabela `vp_chop_fence_trust`.
   - Nível 0 $\to$ 1 requer o item `fence_referral` (drop de emboscadas hostis).
   - Nível 1: Venda de materiais genéricos, venda de pneus, venda de catalisador.
   - Nível 2: Missão rápida (hot job), compra de bancada (`chopshop_bench`), status de reputação.
   - Nível 3: Encomendas/Ordens temporárias (`vp_chop_fence_orders`).
   - Nível 4: Entrega de carro inteiro (`deliverCar`).
   - Decay passivo: Perde 1 nível após 7 dias de inatividade (`TrustDecayDays = 7`).
3. **Blip Dinâmico:**
   - Trust 0: Sem blip.
   - Trust 1–2: Blip aproximado com jitter de $\pm 150\text{m}$.
   - Trust 3–4: Blip exato.

---

## 2. Auditoria Detalhada dos Fluxos de Venda e Transação

| Endpoint / Callback | O que faz | Segurança / Autoridade | Mutex / Rate Limit | Payout Check | Classificação | Decisão |
|---|---|---|---|---|---|---|
| `vp_chopshop:fence:introduce` | Desbloqueia Trust 1 consumindo `fence_referral` | Server-authoritative; pcall no DB com estorno de item se DB falhar | In-memory guard via `TrustCache` | N/A | Baixo | **KEEP** (Evoluir para diálogo do Broker) |
| `vp_chopshop:fence:sellItems` | Vende lista de materiais do inventário | Valida proximidade, trust $\ge 1$, cap de payload (50 itens), dry-run | Rate limit 3000ms (`_sellItemsRateLimit`) | ❌ **NÃO VERIFICADO** (`BridgeAddCash` sem check) | **CURRENT RELEASE P1** (Perda de itens sem pagamento) | **CORRIGIR NA v1.16** + Integrar ao BrokerMarket na v1.17 |
| `vp_chopshop:fence:sellTyres` (truck) | Vende pneus do storage da pickup | Snapshot `TruckStorage`, `TruckStorageBusy`, autoridade por entitlement | Mutex por player (`SellTyresBusy`) + lock por storage | ✅ Verificado + estorno/quarentena | Baixo | **KEEP** (Alimentar BrokerMarket com preço dinâmico) |
| `vp_chopshop:fence:sellTyres` (inv) | Vende item `chopshop_tyre` | Contagem e remoção server-side | Mutex por player | ✅ Verificado + estorno de item | Baixo | **KEEP** |
| `vp_chopshop:fence:sellCatalytic` | Vende `catalytic_converter` | `PartEntitlement.Consume` at-most-once server-side | Rate limit 400ms (`PartEntitlement.CheckRateLimit`) | ✅ Verificado (`BridgeAddCash` bool check, fail-closed) | Zero dupe | **KEEP** (Preço estático min/max $\to$ BrokerMarket) |
| `vp_chopshop:fence:buyBench` | Compra item `chopshop_bench` | Valida proximidade e saldo antes de entregar item | Server-side validation | ✅ Verificado (`BridgeRemoveCash` + estorno) | Baixo | **KEEP** |
| `vp_chopshop:fence:getOrder` | Consulta ou gera ordem temporária (Trust $\ge 3$) | Valida prazo, gera JSON de items e mult | Mutex `OrderGenBusy[key]` | N/A | Baixo | **MIGRATE** (Evoluir para `broker_contracts`) |
| `vp_chopshop:fence:fulfillOrder` | Entrega itens da ordem | Validação de itens, rollback se faltar item, atomic SQL mark | Server-side atomic query | ❌ **NÃO VERIFICADO** (`BridgeAddCash` sem check) | **CURRENT RELEASE P1** (Itens consumidos sem dinheiro se bridge falhar) | **CORRIGIR NA v1.16** + Migrar para BrokerContracts |
| `vp_chopshop:fence:deliverCar` | Entrega veículo inteiro (Trust 4) | Autoridade estrita: reserva DB cooldown $\to$ marcador write+readback $\to$ `BridgeAddCash` $\to$ tombstone $\to$ delete world | Mutex `DeliveryBusy` + `DeliverCarBusy` | ✅ Verificado + rollback de cooldown e marcador | Baixo | **KEEP** (Integrar ao Broker como Contrato High-Value) |

---

## 3. Achados Críticos da Release Atual: CURRENT RELEASE P1 (v1.16)

### ⚠️ Achado P1-01: `sellItems` Falha Silenciosa de Pagamento
- **Arquivo:Linha:** `server/fence.lua:474`
- **Problema:** O callback executa `exports.ox_inventory:RemoveItem` para todos os materiais da lista. Em seguida, chama `BridgeAddCash(src, realTotal, 'fence_sale')` **sem verificar o retorno booleano**.
- **Impacto:** Se o framework (`qbx_core` / `qb-core` / `esx`) falhar na concessão do dinheiro (queda de DB, jogador em transição de disconnect, saldo bloqueado), os itens já foram destruídos do inventário do jogador, nenhum estorno é realizado, o callback retorna `{ ok = true, total = realTotal }` e o jogador recebe XP indevido.
- **Recomendação v1.16:** Aplicar micro-hardening antes do release da v1.16: se `not BridgeAddCash`, tentar estorno atômico dos itens ou colocar transação em quarentena/log CRITICAL e retornar `{ ok = false, err = 'payment_failed' }`.

### ⚠️ Achado P1-02: `fulfillOrder` Falha Silenciosa de Pagamento
- **Arquivo:Linha:** `server/fence.lua:953`
- **Problema:** A ordem é marcada como `fulfilled_at = NOW()` no MySQL e os itens são removidos do inventário. A linha 953 invoca `BridgeAddCash(src, total, 'fence_order')` sem checar se o pagamento foi bem-sucedido.
- **Impacto:** Perda de itens e queima de contrato sem recebimento do valor acordado caso o pagamento falhe.
- **Recomendação v1.16:** Aplicar o mesmo padrão fail-closed de `SEC-1.3` (validar pagamento, abortar XP, logar CRITICAL).
