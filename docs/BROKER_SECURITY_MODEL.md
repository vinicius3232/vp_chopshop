# BROKER SECURITY MODEL & FAILURE MATRIX — vp_chopshop v1.17

**Data:** 2026-09-01 (Revisão BROKER-4.1)  
**Autor:** Principal Security Engineer  
**Status:** ESPECIFICAÇÃO DE SEGURANÇA & MATRIZ DE FALHAS (VALIDADO COM PERSISTENT JOURNAL, STRICT STABLE IDENTITY E HARNESS DE TESTES COMPLETO: 1457 PASS / 0 FAIL)

---

## 1. Princípios de Segurança do Broker & Mercado

1. **Trust-No-Client:** O client envia exclusivamente identificadores de intenção (`contractId`, `entitlementId`). O servidor resolve autoritativamente a entidade, posse, integridade, demanda, multiplicadores e pagamentos.
2. **At-Most-Once Terminal Disposition:** Cada peça física ou entitlement possui exatamente uma destinação econômica terminal (venda NPC, contrato, oficina ou bancada).
3. **Fail-Closed Economics:** Em qualquer falha de rede, timeout, queda de banco de dados ou indisponibilidade de adapter externo, o sistema prioriza a integridade econômica, abortando operações sem conceder valores não lastreados.
4. **Persistent Transaction Journaling:** Nenhuma transação externa com potencial impacto financeiro depende exclusivamente de memória RAM. O estado `COMMITTING` é persistido no banco antes do envio de qualquer requisição de pagamento a terceiros.
5. **Classificação de Certeza:**  
   > **DECLARAÇÃO DE CONFORMIDADE:**  
   > Os protocolos de segurança descritos neste documento foram **IMPLEMENTADOS E COMPROVADOS EM TESTES AUTOMATIZADOS** com 1457 asserts aprovados e zero regressões.

---

## 2. Matriz de Falhas Específica da Integração SAGA com Persistent Journal

| Cenário de Falha na SAGA | Estado no Journal DB (`vp_chop_workshop_journal`) | Estado no Provider Externo | Ação de Reconciliação do `vp_chopshop` | Estado Final do Entitlement | Dinheiro do Jogador | Risco de Duplicação / Double Payout |
|---|---|---|---|---|---|---|
| **Provider pagou mas a resposta foi perdida** (RPC timeout pós-commit) | `COMMITTING` | `COMMITTED` (Player recebeu) | Re-sonda `GetTransactionStatus(txnId)`. Confirma `COMMITTED`, atualiza journal para `FINALIZED`. | `CONSUMED` | Pago com sucesso | **ZERO** (Peça não devolvida) |
| **Commit com status indefinido** (Provider não responde após N retries) | `COMMITTING` | `UNKNOWN` | Entra em `RECONCILING` $\to$ `QUARANTINE`. **NUNCA** volta para `ISSUED` sem `ABORTED` comprovado. | `QUARANTINE` (Travado) | Indefinido até consulta | **ZERO** (Fail-Closed defensivo) |
| **Restart do `vp_chopshop` durante `COMMITTING`** | `COMMITTING` (gravado antes do commit) | `PREPARED` ou `COMMITTED` | Boot sweeper carrega journal do MySQL e consulta `GetTransactionStatus(txnId)` no provider. | `CONSUMED` (se pago) ou `ISSUED` (se abortado) | Consistente com o provedor | **ZERO** |
| **Restart do Provider externo durante a SAGA** | `RESERVED` ou `COMMITTING` | Reiniciando | `vp_chopshop` aguarda reconnect do provider e re-sonda status ou cancela via `AbortPurchase`. | `ISSUED` (se abortado antes do commit) | Não pago | **ZERO** |
| **Falha em `FinalizeConsume` pós-commit** (Erro interno ao persistir entitlement) | `COMMITTED` | `COMMITTED` (Player recebeu) | Journal retém `COMMITTED`/`RECONCILING`. Entitlement retido como `CONSUMED` em memória. Retenta persistência até limite e entra em `QUARANTINE` com log `CRITICAL`. | `CONSUMED` | Pago | **ZERO** (Sem ressurreição da peça) |
| **Requisição de Commit Duplicada** (Double-fire de rede) | `COMMITTING` / `FINALIZED` | `COMMITTED` | Provider idempotente devolve o mesmo `txnId` com status `paid = true`. `vp_chopshop` ignora 2º disparo. | `CONSUMED` | Pago exatamente 1 vez | **ZERO** |

---

## 3. Matriz de Falhas dos Fluxos Gerais do Broker

| Fluxo / Operação | Cenário de Falha | Estado do Entitlement | Estado do Dinheiro / Pagamento | Pode Retentar? | Ação Administrativa? | Classificação de Risco |
|---|---|---|---|---|---|---|
| **Venda NPC (Broker)** | `PartEntitlement.Validate` falha (dono incorreto ou já consumido) | Inalterado | Nenhum dinheiro pago | Não | Log de segurança (aviso) | **ZERO** |
| **Venda NPC (Broker)** | `BridgeAddCash` falha após `Consume` | `CONSUMED` | Nenhum dinheiro pago | Não (Fail-Closed) | Log `CRITICAL` com `playerKey` e valor para auditoria | **ZERO** (Zero double payout) |
| **Contrato Broker** | Contrato expirou no servidor durante a entrega | Inalterado (`ISSUED`) | Nenhum dinheiro pago | Sim (no mercado normal) | Nenhuma | **ZERO** |
| **Contrato Broker** | Peça entregue não corresponde ao modelo/classe pedido | Inalterado (`ISSUED`) | Nenhum dinheiro pago | Sim (peça segue com o player) | Nenhuma | **ZERO** |
| **Disputa Simultânea** | 2 jogadores tentam vender ou processar a mesma peça ao mesmo tempo | 1º ganha (`CONSUMED`), 2º rejeitado | Apenas o 1º recebe payout | Não para o 2º | Nenhuma | **ZERO** |

---

## 4. Separação de Achados: CURRENT RELEASE P1 (v1.16) vs v1.17

Durante a auditoria arquitetural, foram isolados 2 achados que pertencem à release v1.16 atual e **não** devem aguardar o desenvolvimento da v1.17:

### ⚠️ CURRENT RELEASE P1 — Achados Críticos da v1.16:
1. **`server/fence.lua:474` (`vp_chopshop:fence:sellItems`):**
   - Chamada `BridgeAddCash(src, realTotal, 'fence_sale')` sem checagem de retorno booleano.
   - *Impacto:* Risco de perda de inventário sem crédito de saldo em caso de falha do framework.
2. **`server/fence.lua:953` (`vp_chopshop:fence:fulfillOrder`):**
   - Chamada `BridgeAddCash(src, total, 'fence_order')` sem checagem de retorno booleano.
   - *Impacto:* Risco de cumprimento de ordem com perda de itens e zero crédito de saldo.

> **RECOMENDAÇÃO TÉCNICA:**  
> Aplicar micro-hardening corretivo (estorno/fail-closed e verificação booleana estrita) diretamente na base da v1.16 antes do merge final para produção.

---

## 5. Especificação dos Testes Automatizados (Canary & Boundary)

### 5.1. Testes de Autoridade do Broker (`BROKER-SEC-01` .. `13`)
- `BROKER-SEC-01`: Client envia `entitlementId` forjado $\to$ Rejeição com `invalid_entitlement`.
- `BROKER-SEC-02`: Jogador B tenta vender peça pertencente ao Jogador A $\to$ Rejeição com `owner_mismatch`.
- `BROKER-SEC-03`: Tentativa de vender peça em estado `CONSUMED` $\to$ Rejeição com `already_consumed`.
- `BROKER-SEC-04`: Entrega de peça que não atende aos requisitos do contrato $\to$ Rejeição com `wrong_part`.
- `BROKER-SEC-05`: Entrega de contrato com deadline vencido $\to$ Rejeição com `contract_expired`.
- `BROKER-SEC-06`: Disparo duplo concorrente de liquidação $\to$ Apenas 1 transação é aceita; 2ª rejeitada.
- `BROKER-SEC-07`: Client tenta forjar modelo de veículo via payload $\to$ Servidor extrai do OneSync (`GetEntityModel`).
- `BROKER-SEC-08`: Client tenta forjar classe de veículo $\to$ Servidor extrai `GetVehicleClass`.
- `BROKER-SEC-09`: Client injeta preço adulterado $\to$ Servidor calcula via `BrokerMarket.ResolvePrice`.
- `BROKER-SEC-10`: Client injeta multiplicador de reputação falso $\to$ Servidor consulta banco de dados.
- `BROKER-SEC-11`: Provider externo envia retry com mesmo `txnId` $\to$ Retorno idêntico com zero novo payout.
- `BROKER-SEC-12`: Provider externo sofre queda após prepare $\to$ Transação é abortada com segurança.
- `BROKER-SEC-13`: Race condition entre venda no Broker e desmanche na bancada $\to$ Mutex serializa e impede duplicação.

### 5.2. Testes de Integração de Oficina & Journal (`WORKSHOP-01` .. `07`)
- `WORKSHOP-01`: Inicialização sem provider registrado $\to$ Sistema funciona 100% autônomo.
- `WORKSHOP-02`: `WorkshopBridge.GetMarketSignal` retorna dados formatados de provider ativo.
- `WORKSHOP-03`: Rejeição na fase `PreparePurchase` mantém entitlement `ISSUED`.
- `WORKSHOP-04`: Fluxo completo de SAGA com persistência em `vp_chop_workshop_journal` avança `PREPARED` $\to$ `RESERVED` $\to$ `COMMITTING` $\to$ `COMMITTED` $\to$ `FINALIZED`.
- `WORKSHOP-05`: Replay de requisição `CommitPurchase` é rigorosamente idempotente.
- `WORKSHOP-06`: Simulação de reboot durante `COMMITTING` recupera status no boot sweeper sem ressuscitar o entitlement.
- `WORKSHOP-07`: Handoff de `stolen_plate` preserva integralmente metadados e valida identidade do invocador server-side.
