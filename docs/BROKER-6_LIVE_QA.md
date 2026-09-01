# BROKER-6 — Live QA Checklist & Release Verification Matrix

> **Versão:** v1.17.0-RC  
> **Data de Emissão:** 2026-09-01  
> **Escopo:** Validação completa e reproduzível in-game / FiveM do Chop Broker, Dynamic Market, Contracts, Workshop SAGA e Persona UI.

---

## Instruções de Execução

- Cada caso de teste deve ser executado em ambiente runtime real FiveM (QBox / ox_lib / ox_target / oxmysql).
- Marque `[X] PASS` ou `[X] FAIL` para cada item.
- Registre prints/vídeos na linha `Evidence:` e anotações de discrepância em `Observed:`.

---

## QA-A — BOOT & RESOURCE LIFECYCLE

- [ ] **QA-A01:** Start do resource em banco vazio (Fresh Install) executa migrations sem erros.
  - **Expected:** Todas as tabelas (`vp_chop_broker_market`, `vp_chop_broker_contracts`, `vp_chop_workshop_journal`, etc.) criadas perfeitamente.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-A02:** Restart do resource (`ensure vp_chopshop`).
  - **Expected:** Resource reinicia sem exceptions, recupera estado de DB e restabelece pools.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-A03:** Restart do servidor FiveM completo.
  - **Expected:** Inicialização limpa, sem deadlocks no `MySQL.ready`, `VPChopDBReady == true`.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-A04:** Console do servidor e F8 sem exceptions não tratadas.
  - **Expected:** 0 erros de sintaxe ou nil indexing durante boot.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-A05:** `BrokerMarket` inicializado com estado `IsReady() == true`.
  - **Expected:** Commodities carregadas do banco ou inicializadas com `demand_index = 1.0000`.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-A06:** `BrokerContracts` inicializado com estado `IsReady() == true`.
  - **Expected:** Janelas globais e contratos pessoais recuperados ou gerados dentro do prazo.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-A07:** `Config.Broker.Workshop.Provider = 'none'` padrão não derruba o resource.
  - **Expected:** WorkshopBridge entra em modo degradado seguro (IsReady=false) sem travar boot.
  - **Observed:**
  - **Evidence:**

---

## QA-B — NPC / BROKER PERSONA & CONTEXT UI

- [ ] **QA-B01:** Fence/Broker NPC spawna no local configurado sem flickering.
  - **Expected:** Ped visível com animação ambiente e targeting ativo.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-B02:** Target a pé possui interação única e limpa `[Falar com o Intermediário]`.
  - **Expected:** Zero "target soup" com dezenas de opções espalhadas.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-B03:** Jogador com Trust 0 abre menu e vê opção de introdução/apresentação.
  - **Expected:** Opções comerciais bloqueadas até apresentação formal.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-B04:** Jogador com Trust 1 possui acesso ao submenu de Vendas (`vp_broker_sell`).
  - **Expected:** Pode vender peças físicas, materiais soltos e pneus.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-B05:** Jogador com Trust 2 possui acesso a Missões (`hotJob`), Perfil (`status`) e Loja de Bancada (`buyBench`).
  - **Expected:** Opções liberadas conforme `capabilities`.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-B06:** Jogador com Trust 3 possui acesso a Contratos (`contracts`) e Encomenda Especial (`legacyOrder`).
  - **Expected:** Submenus correspondentes operacionais.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-B07:** Jogador com Trust 4 possui acesso à Entrega de Veículo Inteiro (`deliverCar`).
  - **Expected:** Opção de venda direta de carro ocupado ativa.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-B08:** Trust do jogador avança em runtime (sem restart de resource).
  - **Expected:** Fechar e reabrir o menu reflete imediatamente as novas opções desbloqueadas.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-B09:** Jogador distante (> 6.0m) do NPC tenta acionar callback.
  - **Expected:** Servidor rejeita autoritativamente com `err = 'distance'`.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-B10:** Interface e notificações em Português (`Config.Locale = 'pt'`).
  - **Expected:** Todos os textos traduzidos, sem chaves cruas ou textos em inglês vazando.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-B11:** Interface e notificações em Inglês (`Config.Locale = 'en'`).
  - **Expected:** Todos os textos traduzidos perfeitamente.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-B12:** Spot-check de idiomas secundários (`es`, `fr`, `tr`).
  - **Expected:** Menu abre sem falhas e exibe termos localizados em cada idioma.
  - **Observed:**
  - **Evidence:**

---

## QA-C — BROKER DYNAMIC MARKET

- [ ] **QA-C01:** Venda de `metalscrap` no Broker.
  - **Expected:** Preço calculado dinamicamente com base no `demand_index`, pagamento efetuado.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-C02:** Venda de `steel`, `aluminum`, `copper` e `car_parts`.
  - **Expected:** Payout unitário correspondente ao índice da commodity.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-C03:** Venda de peça física carregada nos braços (`door`, `bonnet`, `adv_engine`).
  - **Expected:** Peça consumida do jogador, prop removido e dinheiro entregue.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-C04:** Venda de `catalytic_converter` nos braços.
  - **Expected:** Preço dinâmico aplicado e peça consumida.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-C05:** Venda de pneus (`TyreEntitlement` no caminhão ou inventário).
  - **Expected:** Payout conforme quantidade e estado de desgaste.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-C06:** Preço cotado na interface é idêntico ao valor creditado na conta do jogador.
  - **Expected:** Zero desvio entre cotação client-side e liquidação server-side.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-C07:** Venda em volume de uma commodity reduz seu `demand_index` (pressão de mercado).
  - **Expected:** Próxima cotação reflete preço menor dentro dos limites de piso (`PriceFloor`).
  - **Observed:**
  - **Evidence:**

- [ ] **QA-C08:** Restart do resource preserva a curva de demanda (`vp_chop_broker_market`).
  - **Expected:** Índice de demanda recuperado do banco sem resetar para 1.0 artificialmente.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-C09:** Jogador com Trust 0 tenta forçar venda via evento.
  - **Expected:** Rejeitado pelo servidor com `err_trust_gate`.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-C10:** Jogador com Heat elevado (Burning Heat).
  - **Expected:** Venda bloqueada ou com retenção de pagamento conforme regra de Heat.
  - **Observed:**
  - **Evidence:**

---

## QA-D — PHYSICAL PART EXCLUSIVITY & TERMINAL DESTINATIONS

- [ ] **QA-D01:** Retirar uma porta ou capô de um veículo no desmanche avançado.
  - **Expected:** Peça anexada aos braços do jogador com `PartEntitlement` válido.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-D02:** Largar a peça no chão (`[E]`).
  - **Expected:** Prop permanece no solo com coordenadas e metadata preservadas.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-D03:** Recolher a peça do chão (`[ALT]` / Target).
  - **Expected:** Peça volta para os braços do jogador com o mesmo `entitlementId`.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-D04:** Vender a peça carregada no Broker NPC.
  - **Expected:** `PartEntitlement` marcado como `CONSUMED`, prop removido, dinheiro pago.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-D05:** Tentar processar a mesma peça vendida na bancada de trabalho (`chopshop_bench`).
  - **Expected:** Servidor rejeita terminantemente (`err = 'consumed'` ou `'invalid_entitlement'`).
  - **Observed:**
  - **Evidence:**

- [ ] **QA-D06:** Retirar nova peça e processar na bancada (`chopshop_bench`).
  - **Expected:** Peça consumida, sucatas geradas no inventário.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-D07:** Tentar vender no Broker a peça que já foi processada na bancada.
  - **Expected:** Rejeitado terminantemente pelo servidor.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-D08:** Dois jogadores tentando interagir simultaneamente com a mesma peça.
  - **Expected:** Apenas um obtém o lock de posse; zero duplicação de peça ou payout.
  - **Observed:**
  - **Evidence:**

---

## QA-E — CONTRACTS & HIGH-DEMAND LISTINGS

- [ ] **QA-E01:** Abrir menu de contratos (`vp_broker_contracts`).
  - **Expected:** Seção Alta Procura Global exibe itens públicos ativos.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-E02:** Contrato global não exibe botão de "Aceitar".
  - **Expected:** Permite entrega direta por qualquer jogador que carregar a peça correspondente.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-E03:** Contrato pessoal com estado `AVAILABLE` é listado na seção pessoal.
  - **Expected:** Exibe detalhes de quantidade, bônus e prazo.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-E04:** Clicar em contrato pessoal `AVAILABLE`.
  - **Expected:** Dispara `acceptContract`, transiciona para `ACCEPTED` e exibe notificação de sucesso.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-E05:** Menu de contratos atualiza e exibe badge `[Aceito / Em Andamento]`.
  - **Expected:** Contrato pronto para receber entregas de peças.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-E06:** Carregar peça compatível nos braços e clicar no contrato aceito.
  - **Expected:** Dispara `fulfillContract`, remove a peça dos braços e paga recompensa com multiplicador.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-E07:** Campo `remaining` do contrato decrementa exatamente em 1 unidade.
  - **Expected:** Quota atualizada no banco (`vp_chop_broker_contracts`).
  - **Observed:**
  - **Evidence:**

- [ ] **QA-E08:** Tentar entregar peça errada ou incompatível.
  - **Expected:** Rejeição com `err_wrong_part`, zero payout, peça permanece nos braços.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-E09:** Tentar entregar peça em contrato cujo prazo expirou (`expires_at < serverNow`).
  - **Expected:** Rejeição com `err_contract_expired`, zero mutação no banco e zero payout.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-E10:** Entregar a última peça necessária para concluir o contrato (`remaining == 0`).
  - **Expected:** Payout base + `bonus_cash` creditado exatamente uma vez; contrato finalizado (`FULFILLED`).
  - **Observed:**
  - **Evidence:**

- [ ] **QA-E11:** Double-click rápido na entrega de contrato.
  - **Expected:** Lock atômico impede double payout; exatamente 1 entrega processada.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-E12:** Restart do resource com contrato em andamento.
  - **Expected:** Contrato recupera estado `ACCEPTED` e `remaining` sem perda.
  - **Observed:**
  - **Evidence:**

---

## QA-F — LEGACY SPECIAL ORDERS

- [ ] **QA-F01:** Consultar encomenda sob medida ativa (`vp_broker_legacy_order` -> `showOrder`).
  - **Expected:** Exibe lista de itens solicitados e prazo.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-F02:** Cumprir encomenda especial com itens no inventário (`fulfillOrder`).
  - **Expected:** Itens consumidos e pagamento efetuado.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-F03:** Tentar reenviar `fulfillOrder` em seguida.
  - **Expected:** Rejeitado pelo servidor; zero double payout.
  - **Observed:**
  - **Evidence:**

---

## QA-G — DELIVERCAR (WHOLE STOLEN VEHICLE SALE)

- [ ] **QA-G01:** Jogador com Trust < 4 tenta acionar entrega de veículo inteiro.
  - **Expected:** Bloqueado pelo servidor com `err_trust_gate`.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-G02:** Jogador com Trust 4 ao volante de veículo roubado solicita entrega.
  - **Expected:** Veículo avaliado, valor creditado e entidade deletada com segurança.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-G03:** Cooldown aplicado após entrega bem-sucedida.
  - **Expected:** Próxima tentativa bloqueada até expiração do cooldown.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-G04:** Replay no mesmo veículo ou veículo com placa falsa.
  - **Expected:** Verificação contra `carcass_ledger` impede re-entrega.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-G05:** Tentativa com `netId` reciclado.
  - **Expected:** Servidor valida `vsid` e não apaga veículo não relacionado.
  - **Observed:**
  - **Evidence:**

---

## QA-H — WORKSHOP BRIDGE & DISTRIBUTED SAGA

### Modalidade H0 — Standalone Default (`Config.Broker.Workshop.Provider = 'none'`)
- [ ] **QA-H01:** Broker, Mercado, Contratos e Desmanche 100% funcionais sem provider externo.
  - **Expected:** Zero polling, zero crashes, zero mensagens de erro no console.
  - **Observed:**
  - **Evidence:**

### Modalidade H1 — Provider Integration (Mock / Custom Workshop)
- [ ] **QA-H02:** Registro de provider externo com caller identity matching.
  - **Expected:** Provider aceito via export.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-H03:** Tentativa de registro por resource não autorizado.
  - **Expected:** Rejeição com `provider_identity_mismatch`.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-H04:** `PreparePurchase` de peça física.
  - **Expected:** Status transiciona para `RESERVED_EXTERNAL` com timeout durável.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-H05:** Peça em `RESERVED_EXTERNAL` não pode ser vendida no Broker NPC.
  - **Expected:** Rejeição com `err_external_reserved`.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-H06:** Peça em `RESERVED_EXTERNAL` não pode cumprir contratos.
  - **Expected:** Rejeição com `err_external_reserved`.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-H07:** Peça em `RESERVED_EXTERNAL` não pode ser processada na bancada.
  - **Expected:** Rejeição com `err_external_reserved`.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-H08:** `CommitPurchase` persiste `COMMITTING` no journal antes da chamada remota.
  - **Expected:** Estado durável gravado em `vp_chop_workshop_journal`.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-H09:** Sucesso no provider: `COMMITTED` -> consumo local do asset -> `FINALIZED`.
  - **Expected:** Ciclo SAGA completo sem double commit.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-H10:** Perda de resposta de rede após pagamento no provider.
  - **Expected:** Retry com mesmo `txnId` é idempotente no provider.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-H11:** Restart do resource durante status `COMMITTING`.
  - **Expected:** Boot reconciler consulta status no provider antes de tomar ação.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-H12:** Provider confirma status `COMMITTED` na recuperação.
  - **Expected:** Transiciona para `FINALIZED` sem executar segundo pagamento.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-H13:** Provider retorna status `UNKNOWN`.
  - **Expected:** Asset permanece reservado (fail-closed) até resolução ou limite de tentativas.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-H14:** Row corrompida ou sem `stable_part_id`.
  - **Expected:** Isolada para `QUARANTINE` sem inventar identidade.
  - **Observed:**
  - **Evidence:**

---

## QA-I — CONCURRENCY & RACE CONDITIONS

- [ ] **QA-I01:** 2 jogadores tentando vender a mesma peça física no Broker ao mesmo tempo.
  - **Expected:** Exatamente 1 venda concluída com sucesso; a outra falha fail-closed.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-I02:** 2 jogadores tentando cumprir a última unidade (`remaining == 1`) do mesmo contrato global.
  - **Expected:** Exatamente 1 jogador cumpre e recebe o bônus; o segundo é informado que a quota esgotou.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-I03:** Venda no Broker concorrendo com processamento na Bancada.
  - **Expected:** Apenas um destino terminal consome o asset.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-I04:** Venda no Broker concorrendo com reserva de Workshop.
  - **Expected:** Apenas uma operação prevalece.
  - **Observed:**
  - **Evidence:**

---

## QA-J — PAYMENT FAILURE & REPLAY RESISTANCE

- [ ] **QA-J01:** Falha de pagamento do framework no Broker.
  - **Expected:** Transação aborta fail-closed, peça não é consumida ou é restaurada com segurança.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-J02:** Falha de pagamento no cumprimento de contrato.
  - **Expected:** Quota não é decrementada indevidamente sem pagamento comprovado.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-J03:** Replay de evento de pagamento.
  - **Expected:** Zero criação indevida de dinheiro ou duplicidade de crédito.
  - **Observed:**
  - **Evidence:**

---

## QA-K — DISCONNECT & RECONNECT

- [ ] **QA-K01:** Jogador desconecta enquanto carrega uma peça nos braços.
  - **Expected:** Ao reconectar ou após cleanup de ped, a peça não é duplicada.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-K02:** Jogador com contrato pessoal `ACCEPTED` desconecta e reconecta.
  - **Expected:** Contrato permanece associado ao `playerKey` até expiração do prazo.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-K03:** Desconexão durante a barra de progresso / minigame antes do commit terminal.
  - **Expected:** Transação não é concluída; sem payout fantasma.
  - **Observed:**
  - **Evidence:**

---

## QA-L — PERFORMANCE, RESMON & CONSOLE AUDIT

- [ ] **QA-L01:** Resmon ocioso próximo ao Broker NPC.
  - **Expected:** $\le 0.01$ ms.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-L02:** Resmon ocioso longe do Broker.
  - **Expected:** $0.00$ ms (zero loops ativos desnecessários).
  - **Observed:**
  - **Evidence:**

- [ ] **QA-L03:** Abertura e fechamento repetido de menus de contexto `ox_lib`.
  - **Expected:** Zero vazamento de memória ou criação de threads acumuladas.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-L04:** Zero polling periódico desnecessário no banco de dados.
  - **Expected:** Consultas executadas estritamente on-demand via callbacks.
  - **Observed:**
  - **Evidence:**

- [ ] **QA-L05:** Console do servidor e client limpos após 1 hora de operação contínua.
  - **Expected:** Zero spam de avisos ou exceptions.
  - **Observed:**
  - **Evidence:**

---

## Decisão de Aprovação Live QA

- **Resultado Global:** `[ ] APROVADO PARA RELEASE` / `[ ] REJEITADO (BLOQUEADORES ENCONTRADOS)`
- **Auditor / QA Lead:** 
- **Data:** 
- **SHA Testado:** 
