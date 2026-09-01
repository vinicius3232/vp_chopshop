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
Uma peça física representada por `PartEntitlement` possui ciclo de vida exclusivo:
$$\text{ATTACHED} \to \text{GROUND} \to \text{ATTACHED} \to \text{CONSUMED}$$
Uma peça **nunca** pode ser simultaneamente vendida ao Broker, entregue para cumprimento de contrato, processada na bancada de desmanche ou alocada para reserva externa de Workshop. Uma vez marcada como `CONSUMED`, ela é terminantemente inacessível.

### 4. StablePartIdentity Survives Runtime-ID Collision
A identidade durável de uma peça (`stablePartIdentity`) é composta por:
$$\text{stablePartId} = \text{vin} \parallel \text{partKey} \parallel \text{salt}$$
Ela independe do `entitlementId` efêmero em memória (`pe:<counter>`). Mesmo se o resource reiniciar e o contador em memória for resetado para `pe:1`, o identificador estável impede qualquer colisão com transações históricas no journal do banco de dados.

### 5. Workshop COMMITTING Durable Before Remote Commit
No protocolo distribuído de SAGA com workshops externos, o estado `COMMITTING` **deve** ser persistido de forma durável no banco de dados (`vp_chop_workshop_journal`) **antes** de efetuar a chamada remota de liquidação (`CommitPurchase`). Se o resource cair imediatamente antes ou durante a chamada remota, o reconciliador de boot possui registro inequívoco para verificar o status junto ao provider.

### 6. UNKNOWN Status Never Releases Asset (Fail-Closed)
Durante a reconciliação de transações pendentes ou após reinicialização de servidor, se o provider externo retornar status `UNKNOWN` ou estiver temporariamente offline, o asset **nunca** é liberado de volta ao mercado. Ele permanece em estado de quarentena/retenção até prova conclusiva de aborto ou finalização.

### 7. Contract Completion Bonus: At-Most-Once Guarantee
O bônus financeiro de conclusão de contrato (`bonusCash`) é concedido **estritamente uma única vez**, no momento atômico em que a última unidade de cota necessária transiciona a contagem `remaining` para `0`. Concorrência entre múltiplos jogadores ou cliques rápidos são isolados por locks transacionais no banco de dados.

### 8. Payment Failure Cannot Replay Payout
Falhas no framework de inventário ou na API de economia bancária (QBox/qb-core/ESX) abortam a transação de forma atômica e fail-closed. Nenhuma tentativa subsequente de replay é capaz de gerar crédito financeiro duplicado.

### 9. Market General Sales and Contract Sinks Remain Strictly Separate
- **Venda Geral no Broker:** Aplica pressão na curva de oferta e demanda (`BrokerMarket.ProcessSale`), reduzindo o `demand_index` da commodity correspondente.
- **Cumprimento de Contrato:** Atua como um sorvedouro de demanda pontual e **não** aplica pressão de baixa sobre o mercado dinâmico geral, preservando a autoridade de preços independentes.

### 10. Provider 'none' Preserves 100% Standalone Operation
A configuração padrão `Config.Broker.Workshop.Provider = 'none'` opera de forma totalmente desacoplada. Todos os sistemas de Desmanche, Bancada, Furto de Catalisador, Mercado Dinâmico, Contratos e Persona UI funcionam perfeitamente sem gerar exceptions, loops de polling ou logs de erro.

### 11. Legacy Order Compatibility Preserved
O sistema de contratos dinâmicos da v1.17 **não** substitui nem rompe as encomendas especiais legadas (`vp_chop_fence_orders`). As funções `showOrder` e `fulfillOrder` continuam disponíveis e totalmente funcionais através do menu de contexto do Broker.

### 12. deliverCar Remains Independent Authority Domain
A funcionalidade de venda de veículos roubados intactos (`deliverCar`) opera como um domínio autoritativo próprio, protegido por seu próprio ledger persistente (`vp_chop_carcass`), cooldown por jogador e validação de `vsid` e `netId`.
