# BROKER-6 — Canonical Release Invariants (v1.17 Frozen Contract)

> **Status:** CONGELADO / AUDITADO  
> **Versão:** v1.17.0-RC  
> **Data:** 2026-09-01  
> **Referência de Integração:** `pr-h/v1.15-delivercar-terminal-hardening`

---

## Os 12 Invariantes Canônicos que Não se Negociam

### 1. Server-Authoritative Economics (Trust-No-Client)
O client FiveM **nunca** decide preços, multiplicadores, taxas de demanda, recompensas, bônus, itens entregues, prazos ou conclusões de transação. O servidor computa e liquida 100% dos valores no momento exato do commit econômico.

### 2. Client Sends Intent, Not Payout Authority
Todas as mensagens/callbacks enviados pelo cliente contêm apenas intenção de ação e identificadores opacos (`{ sessionId, action }` ou `{ contractId, entitlementId }`). Qualquer parâmetro econômico enviado pelo cliente é estritamente ignorado.

### 3. PartEntitlement: Exactly One Terminal Destination
O ledger server-side de `PartEntitlement` opera estritamente com os estados autoritativos:
$$\text{ISSUED} \;\longrightarrow\; \begin{cases} \text{CONSUMED} & \text{(por venda no Broker)} \\ \text{CONSUMED} & \text{(por entrega em Contrato)} \\ \text{CONSUMED} & \text{(por processamento na Bancada)} \\ \text{RESERVED\_EXTERNAL} \;\to\; \text{CONSUMED} & \text{(por entrega em Workshop)} \\ \text{LOST} & \text{(por cleanup legítimo)} \end{cases}$$
*(Nota: `ATTACHED` e `GROUND` são representações e estados de carry visual client-side, e não estados do ledger autoritativo).*
Uma peça física em estado `ISSUED` pode transicionar para **exatamente UM** destino econômico terminal. Uma vez marcada como `CONSUMED`, ela é terminantemente inacessível para qualquer outra operação.

### 4. StablePartIdentity Survives Runtime-ID Collision
A identidade durável de uma peça (`stablePartIdentity`) é um identificador opaco server-generated, restart-stable para a integridade histórica da SAGA e independente do `entitlementId` efêmero em memória (`pe:<seq>`).
$$\text{Formato:} \quad \texttt{spi:<bootNonce>:<timestamp>:<sequence>:<nonce>}$$
Mesmo se o resource reiniciar e o contador em memória for resetado para `pe:1`, o `stablePartIdentity` impede qualquer colisão com transações históricas no journal persistente (`vp_chop_workshop_journal`).

### 5. Workshop COMMITTING Durable Before Remote Commit
No protocolo distribuído de SAGA com workshops externos, o estado `COMMITTING` **deve** ser persistido de forma durável no banco de dados (`vp_chop_workshop_journal`) **antes** de efetuar a chamada remota de liquidação (`CommitPurchase`). Se o resource cair imediatamente antes ou durante a chamada remota, o reconciliador de boot possui registro inequívoco para verificar o status junto ao provider.

### 6. UNKNOWN Status Never Releases Asset (Fail-Closed)
Durante a reconciliação de transações pendentes ou após reinicialização de servidor, se o provider externo retornar status `UNKNOWN` ou estiver temporariamente offline, o asset **nunca** é liberado de volta ao mercado. Ele permanece em estado de retenção/quarentena até prova conclusiva de aborto ou finalização.

### 7. Contract Completion Bonus: At-Most-Once Guarantee
O bônus financeiro de conclusão de contrato (`bonusCash`) é concedido **estritamente uma única vez**. A concorrência é isolada por mutex em runtime por `contractId` e por um `UPDATE` condicional atômico no banco de dados, onde `affectedRows == 1` determina o vencedor inequívoco da quota final e do bônus decorrente.

### 8. Payment Failure Cannot Replay Payout (Fail-Closed)
Falhas na entrega de dinheiro (ex.: falha no framework de economia) seguem o princípio de que **falha de pagamento não pode gerar duplicação ou replay de dinheiro**. Isso não implica em rollback universal em todos os domínios:
- **Broker (Peça Física):** A peça permanece `CONSUMED` com `terminalConsumed = true`, zero payout em dinheiro, zero retry econômico e zero registro de pressão de venda (`RecordSalesBatch`).
- **Broker (Contratos):** O `entitlement` permanece `CONSUMED` e a quota consumida, zero crédito em dinheiro, zero Trust XP/evento e retry rejeitado.
- **Legacy Encomendas (`fulfillOrder`) & Pneus:** Seguem semântica terminalizada onde nenhuma tentativa repetida gera crédito financeiro duplicado.

### 9. Market General Sales and Contract Sinks Remain Strictly Separate
- **Venda Geral no Broker:** Executa `BrokerMarket.RecordSalesBatch` / `RecordSale`, aplicando pressão sobre o `demand_index` da commodity correspondente.
- **Cumprimento de Contrato:** Atua como sorvedouro pontual independente e **não** chama `RecordSalesBatch` / `RecordSale`, preservando a curva de oferta e demanda do mercado dinâmico geral.

### 10. Provider 'none' Preserves Standalone Operation
A configuração padrão `Config.Broker.Workshop.Provider = 'none'` opera de forma totalmente desacoplada. `WorkshopBridge.IsReady()` pode ser `true` caso o journal e schema locais estejam saudáveis, enquanto `IsAvailable()` reporta `false` e rejeita chamadas externas com `workshop_unavailable` sem gerar exceptions, polling ou logs de erro.

### 11. Legacy Order Compatibility Preserved
O sistema de contratos dinâmicos da v1.17 **não** substitui nem rompe as encomendas especiais legadas (`vp_chop_fence_orders`). As funções `showOrder` e `fulfillOrder` continuam disponíveis e totalmente funcionais através do menu de contexto do Broker.

### 12. deliverCar Remains Independent Authority Domain
A funcionalidade de venda de veículos roubados intactos (`deliverCar`) opera como um domínio autoritativo próprio, protegido por seu próprio ledger persistente (`vp_chop_carcass`), cooldown por jogador e validação de `vsid` e `netId`.
