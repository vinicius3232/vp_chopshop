# PHASE5_KICKOFF.md — Actionable Engineering Blueprint for Phase 5 (v1.19)

> **Status:** KICKOFF READY (Aguardando merge da v1.18-RC.2)  
> **Fase Alvo:** FASE 5 (v1.19) — Workshop Live & Durable Parts Foundation  
> **Baseline:** `7ba20804` (após merge da PR #52)  
> **Branch de Destino:** `feat/v1.19-p5.0-upstream-audit`

---

## 1. Visão Geral da Fase 5

A Fase 5 estabelece a integração definitiva entre o **mercado de desmanche** e a **economia mecânica de oficinas reais**, resolvendo simultaneamente o desafio da **persistência e proveniência de peças físicas duráveis** através de reinicializações do servidor.

---

## 2. Especificação Detalhada por Sub-Fase

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│ ESTRUTURA DE EXECUÇÃO DA FASE 5 (v1.19)                                                    │
├─────────┬────────────────────────────────────────────┬──────────────────────────────────────┤
│ SUBFASE │ TÍTULO / ESCOPO                            │ DEPENDÊNCIA                          │
├─────────┼────────────────────────────────────────────┼──────────────────────────────────────┤
│ P5.0    │ Upstream Workshop Contract Audit           │ v1.18 Merged                         │
│ P5.1    │ QBox Mechanics Adapter                     │ P5.0 Aprovado                        │
│ P5.2    │ Additional Workshop Adapters (Multi-API)   │ P5.1 Aprovado                        │
│ P5.3    │ B2B Workshop Orders & Dynamic Liquidity    │ P5.1 + BrokerMarket                  │
│ P5.4    │ Persistent Physical Part / Provenance V2   │ PartEntitlement (v1.16)              │
│ P5.5    │ Selective Restart Recovery RFC             │ P5.4 + CarcassLedger                 │
│ P5-RC   │ Workshop Live Release Gate & Live QA       │ P5.1 → P5.5 Concluídos               │
└─────────┴────────────────────────────────────────────┴──────────────────────────────────────┘
```

---

### P5.0 — Upstream Workshop Contract Audit

- **Objetivo:** Inspecionar e documentar com precisão cirúrgica as interfaces públicas dos resources de mecânica da comunidade (`qbx_mechanics`, `qb-mechanicjob`, `renzu_customs`), identificando métodos de cobrança de society, verificação de saldo e compra de peças.
- **Não-Objetivos:** Não escrever adapters em código nesta sub-fase; não assumir a existência de exports que não foram verificados diretamente no código-fonte upstream.
- **Arquivos Prováveis:**
  - `docs/research/WORKSHOP_UPSTREAM_AUDIT.md` (novo)
- **Contratos Existentes Reutilizados:** `bridge/workshop.lua` (interfaces `PreparePurchase`, `CommitPurchase`, `AbortPurchase`).
- **Novos Contratos Necessários:** Especificação formal do contrato canônico de adapter B2B.
- **Riscos & Ameaças:** Assumir compatibilidade com forks customizados de oficinas; quebra de API em atualizações upstream.
- **Impacto em DB:** Zero.
- **Estratégia de Testes:** Validação de schemas e revisão estática de assinaturas de métodos.
- **Entry Criteria:** PR #52 mergeada em `pr-h`.
- **Exit Criteria:** Relatório formal documentando as APIs reais de pelo menos 2 resources mecânicos populares.
- **Dependências:** v1.18 Homologada.
- **Rollback Strategy:** N/A (documentação pura).

---

### P5.1 — QBox Mechanics Adapter

- **Objetivo:** Implementar o adaptador oficial para o `qbx_mechanics` dentro do `WorkshopBridge`, operando transações financeiras contra a conta da oficina via SAGA transacional em 2 fases.
- **Não-Objetivos:** Não colocar lógica de sociedade, menus de mecânico ou NUI de oficina dentro do `vp_chopshop`.
- **Arquivos Prováveis:**
  - `bridge/workshop.lua` (implementação do adapter `'qbx_mechanics'`)
  - `server/broker/workshop_spec.lua` (testes de integração do adapter)
- **Contratos Existentes Reutilizados:**
  - `WorkshopBridge.PreparePurchase(provider, params)`
  - `WorkshopBridge.CommitPurchase(transactionId)`
  - `WorkshopBridge.AbortPurchase(transactionId, reason)`
  - Tabela `vp_chop_workshop_journal` (SAGA Journal)
- **Novos Contratos Necessários:** Mapeamento de society funds do QBox (`qbx_management` / `ox_inventory`).
- **Riscos & Ameaças:**
  - *Double Spending:* Falha entre a reserva do dinheiro e o consumo da peça.
  - *Mitigação:* `WorkshopBridge` bloqueia a peça em estado `COMMITTING` no `PartEntitlement` até a confirmação do Commit.
- **Impacto em DB:** Zero alteração de schema (tabela `vp_chop_workshop_journal` criada na v1.17 é reusada).
- **Estratégia de Testes:** Specs com mock do `qbx_mechanics` simulando: sucesso de compra, saldo insuficiente na oficina, crash durante commit e abort seguro com devolução do dinheiro.
- **Entry Criteria:** P5.0 aprovado.
- **Exit Criteria:** Suite `server/broker/workshop_spec.lua` 100% verde testando o adapter QBox real com 0 falhas.
- **Dependências:** P5.0.
- **Rollback Strategy:** Manter `Config.Broker.Workshop.Provider = 'none'` como fallback instantâneo.

---

### P5.2 — Additional Workshop Adapters (Multi-API)

- **Objetivo:** Adicionar adaptadores secundários para ecossistemas alternativos (ex.: Renzu Customs / QS Mechanic) conforme demanda documentada no P5.0.
- **Não-Objetivos:** Não forçar dependência de resources proprietários ou de código fechado.
- **Arquivos Prováveis:**
  - `bridge/workshop.lua`
- **Contratos Reutilizados:** Protocolo SAGA de `bridge/workshop.lua`.
- **Riscos & Ameaças:** Resources que não suportam transações em 2 fases. O `WorkshopBridge` deve envelopar compras simples em transações simuladas com rollback compensatório seguro.
- **Entry Criteria:** P5.1 homologado.
- **Exit Criteria:** Provedores secundários registrados e com testes de isolamento aprovados.
- **Dependências:** P5.1.
- **Rollback Strategy:** Desabilitar o provedor problemático via config retornando a `'none'`.

---

### P5.3 — B2B Workshop Orders & Dynamic Liquidity

- **Objetivo:** Conectar ordens de compra emitidas por oficinas mecânicas ao catálogo de contratos do Broker (`vp_chopshop:broker:getContracts`), criando demanda econômica real orientada por jogadores.
- **Regras Econômicas:**
  - Ordens B2B pagam um multiplicador premium (ex.: 1.10x a 1.30x sobre o valor de mercado).
  - O valor total da ordem permanece retido em garantia (escrow) no `WorkshopBridge`.
  - Se nenhuma oficina demandar a peça, o NPC Broker continua provendo liquidez base de compra.
- **Arquivos Prováveis:**
  - `server/broker/contracts.lua`
  - `server/broker/fence_integration.lua`
  - `server/broker/contracts_spec.lua`
- **Riscos & Ameaças:** Jogador cancelar ordem de compra no momento em que o desmanchador tenta entregar. O `WorkshopBridge` aplica lock de entrega de 60s antes do consumo.
- **Entry Criteria:** P5.1 concluído.
- **Exit Criteria:** Transações B2B completas demonstradas em specs sem duplicação de saldo nem perdas de peças.
- **Dependências:** P5.1, `BrokerContracts (v1.17)`.

---

### P5.4 — Persistent Physical Part / Provenance V2

- **Objetivo:** Criar o schema e a camada de domínio para **Peças Físicas Duráveis** (`vp_chop_physical_parts`), permitindo que motores, portas e catalisadores mantenham sua identidade, procedência, desgaste e serial cross-restart.
- **Precursor já entregue (Expansão de Minigames, PR #55):** a peça roubada já vai **física em cima da bancada** antes de processar via `_benchParts[benchId]` (server, **in-memory**, some no restart). P5.4 = trocar esse mapa in-memory pela tabela persistente + recuperação seletiva. Ver `POST_V118_ROADMAP.md` → "Trilhas Paralelas Já Entregues".
- **Não-Objetivos:** Não substituir o `PartEntitlement` (que continua como árbitro de autorização/transporte temporal).
- **Campos Canônicos da Tabela `vp_chop_physical_parts`:**
  - `part_id` VARCHAR(64) PRIMARY KEY (UUIDv4)
  - `part_type` VARCHAR(32) NOT NULL (`adv_engine`, `door`, `catalytic_converter`, etc.)
  - `serial` VARCHAR(16) NULL (identificador forense ou NULL se riscado)
  - `source_model` VARCHAR(32) NOT NULL (modelo server-safe do carro de origem)
  - `vehicle_class` TINYINT NOT NULL (classe GTA 0..22)
  - `condition_pct` DECIMAL(5,2) DEFAULT 100.00
  - `legal_state` ENUM('stolen', 'scratched', 'forged', 'refurbished', 'legal') NOT NULL
  - `owner_citizenid` VARCHAR(64) NULL
  - `installed_vehicle_id` INT NULL (se instalada em veículo permanente)
  - `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  - `updated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
- **Arquivos Prováveis:**
  - `server/db.lua` (migração de schema)
  - `server/logistics/physical_part.lua` (novo gerenciador durável)
  - `server/logistics/physical_part_spec.lua` (nova suite de testes)
- **Riscos & Ameaças:**
  - *Desync Inventário × DB:* Peça removida do inventário mas retida no banco.
  - *Mitigação:* `PartEntitlement` faz binding de `part_id` como metadata do `ox_inventory` e invalida no DB via transação atômica.
- **Entry Criteria:** P5.3 concluído.
- **Exit Criteria:** Suite `physical_part_spec.lua` 100% verde cobrindo criação, transferência de posse, raspagem e destruição terminal.
- **Dependências:** `PartEntitlement (v1.16)`.

---

### P5.5 — Selective Restart Recovery

- **Objetivo:** Implementar o reconciliador de boot que recupera o estado de transações inacabadas e peças duráveis sem tentar persistir sessões de desmanche efêmeras.
- **Diretrizes de Recuperação:**
  1. *Transações SAGA Pendentes (`PREPARED`):* Consultar status no provider; se timeout > TTL, abortar e estornar valor / liberar quarentena.
  2. *Peças em Trânsito:* Peças com `PartEntitlement` ativo no momento da queda são desarmadas de volta para o inventário do portador.
  3. *Tombstones de Carcaça:* `CarcassLedger` continua garantindo bloqueio de re-descarte.
- **Arquivos Prováveis:**
  - `server/session/carcass_ledger.lua`
  - `server/session/restart_recovery.lua` (novo)
  - `server/session/restart_recovery_spec.lua` (novo)
- **Entry Criteria:** P5.4 concluído.
- **Exit Criteria:** Simulações de crash durante cada etapa da SAGA demonstrando recuperação determinística sem duplicações.
- **Dependências:** P5.4, `CarcassLedger (v1.15)`.

---

### P5-RC — Workshop Live Release Gate & Live QA Matrix

- **Objetivo:** Congelar os invariantes da Fase 5, compilar a suite de Release Gate estático e executar a matriz de Live QA no FiveM.
- **Métricas Mínimas de Aprovação:**
  - Harness estático > 2150 asserts / 0 fail.
  - Matriz de Live QA cobrindo compras B2B reais com 2 clientes e falhas forçadas de oficina.
  - Zero duplicação financeira em 108.000 iterações de estresse.
