# LEGACY_IDEA_RECONCILIATION.md — Comprehensive Legacy Idea & RFC Classification

> **Status:** CANONICAL RECONCILIATION AUDIT  
> **Baseline:** `v1.18-RC.2`  
> **Target Scope:** Classificação rigorosa de todas as pesquisas e RFCs anteriores (v1.14 → v1.18)

---

## 1. Critérios de Classificação

Toda ideia, estudo ou proposta presente no histórico de desenvolvimento do `vp_chopshop` é classificada segundo os seguintes critérios:

| Status | Significado Arquitetural |
|---|---|
| **`ABSORBED`** | Totalmente implementado e validado no código de produção em versões anteriores. |
| **`PARTIALLY_ABSORBED`** | Padrão fundamental adotado, mas extensões específicas (ex: persistência cross-restart) pertencem a fases futuras. |
| **`STILL_VALID`** | Design aprovado e integro, aguardando a abertura de sua respectiva fase no roadmap canônico. |
| **`SUPERSEDED`** | Substituído por uma solução mais elegante, segura, modular ou alinhada aos invariantes do projeto. |
| **`DEFERRED`** | Postergado para pós-v1.23 (v2.x opcional), sem compromisso ativo de implementação. |
| **`REJECTED`** | Definitivamente descartado por violação de segurança (Trust-No-Client), duplicação de autoridade ou inviabilidade técnica. |

---

## 2. Matriz Exaustiva de Reconciliação

### 2.1 Itens do `ROADMAP_RECONCILIATION.md` (R-0 a R-11+)

| ID / Item | Status | Justificativa Arquitetural & Rastreabilidade |
|---|:---:|---|
| **R-0: Research Freeze** | `ABSORBED` | Documentos de pesquisa arquivados e congelados em `docs/research/` na stack v1.15. |
| **R-1: CI Gate** | `ABSORBED` | Workflow `.github/workflows/harness.yml` implementado, validando exit code e contagem estática de asserts. |
| **R-2: Chore M1+M2** | `ABSORBED` | Internacionalização sanitizada com `L()` e remoção de blocos mortos em `client/fence.lua` (v1.15). |
| **R-3: Registry Drift/Parity** | `ABSORBED` | `shared/registry/parts.lua` e `tools.lua` congelados como autoridade canônica na stack v1.16. |
| **R-4: Domain Model + Config (`vehicle_part`)** | `SUPERSEDED` | Substituído pelo modelo de **Peça Física Carregada + `PartEntitlement`** (v1.16/v1.17) e evoluído para **P5.4 (Peça Durável V2)**. |
| **R-5: ProcessSession Core** | `SUPERSEDED` | A máquina de desmanche na bancada foi unificada via `PartEntitlement` + `ActionSession` (v1.16 SEC-1), tornando desnecessária uma sessão separada e frágil de bancada. |
| **R-6: Domain Executor + Quarantine** | `ABSORBED` | Padrão de quarentena econômica e isolamento de transações implementado em `server/logistics/part_entitlement.lua` e `bridge/workshop.lua`. |
| **R-7: Bench UX + Callbacks** | `ABSORBED` | `ox_target` na `chopshop_bench` interagindo diretamente com a peça física carregada nos braços do jogador (`v1.16`). |
| **R-8: Forensic Integration** | `ABSORBED` | Scanner policial read-only (`server/partserial.lua`), kit forense e `EvidenceBridge` entregues na v1.18. |
| **R-9: Workshop Commodity Contract** | `ABSORBED` | `WorkshopBridge` com transação SAGA em 2 fases (`PREPARED → COMMITTED / ABORTED`) entregue na v1.17. |
| **R-10: Restart Recovery RFC** | `PARTIALLY_ABSORBED` | `CarcassLedger` em DB (`vp_chop_carcass`) entregue na v1.15; persistência durável de peças alocada para **P5.5**. |
| **R-11+: Economia Avançada / Rebuilding** | `STILL_VALID` | Mapeado canonicamente nas **Fases 7 e 8 (v1.21 e v1.22)**. |

---

### 2.2 Itens do `PART_PROCESSING_RFC.md` (RFC #12 a #17)

| Proposta / Conceito | Status | Justificativa Arquitetural |
|---|:---:|---|
| **Modelo A (1 item `vehicle_part` + metadata)** | `SUPERSEDED` | Na v1.16 adotou-se o modelo físico real: o jogador carrega a peça (`door`, `engine`, `catalytic_converter`) nos braços com prop/animação e target de bancada, dispensando a proliferação de itens intermediários em inventário. |
| **Modelo B (N itens por tipo: `stolen_door_lf`, etc.)** | `REJECTED` | Explosão de itens no `ox_inventory`, complexidade de ícones e poluição desnecessária de inventário. |
| **ProcessSession separada** | `SUPERSEDED` | A autorização atômica foi absorvida pelo `PartEntitlement` (SEC-1) e pelo `chopshop_bench` handler. |
| **RewardResolver isolado** | `SUPERSEDED` | O cálculo de payout foi encapsulado no `Part Registry` + `BrokerMarket` + integradores de commodities da v1.17. |
| **Estado `processed` de peças** | `STILL_VALID` | Reenquadrado em **P7.3** (Refurbishment mecânico na bancada). |

---

### 2.3 Decisões do `ADOPT_STUDY_REJECT.md`

| ID | Item | Status | Justificativa Arquitetural |
|---|---|:---:|---|
| **A1** | Barreiras terminais com espelho em DB (`vp_chop_carcass`) | `ABSORBED` | Implementado via `CarcassLedger` em `server/session/carcass_ledger.lua` e tabela `vp_chop_carcass`. |
| **A2** | Identidade veicular = `vehicleid` + VSID | `ABSORBED` | Invariante canônico do projeto. Placa é apenas lookup volátil. |
| **A3** | Metadados de peça física | `PARTIALLY_ABSORBED` | Presente no `PartEntitlement` e `car_parts`; persistência durável cross-restart alocada para **P5.4**. |
| **A4** | CI mínimo com exit code estrito | `ABSORBED` | Implementado e ativo em `.github/workflows/harness.yml`. |
| **A5** | ProcessSession espelhando ActionSession | `SUPERSEDED` | Absorvido pela arquitetura unificada de bancada e entitlements da v1.16. |
| **A6** | WorkshopBridge modular e isolado | `ABSORBED` | Entregue na v1.17 em `bridge/workshop.lua`. |
| **A7** | `MySQL.transaction.await` para multi-row SQL | `ABSORBED` | Padrão obrigatório no `carcass_ledger` e `workshop_journal`. |
| **S1** | Migrar `TyreEntitlement` para DB | `STILL_VALID` | Alocado no estudo de **P5.5** caso testes de estresse indiquem desync econômico. |
| **S2** | Migrar `TruckStorage` para DB | `STILL_VALID` | Alocado no estudo de **P5.5**. |
| **S3** | Persistência de resumo da ChopSession | `REJECTED` | Sessões de desmanche são efêmeras por design; o bloqueio de re-chop é garantido pelo `CarcassLedger` e inventário. |
| **S4** | Startup reconciliation ativo (`GetGamePool`) | `STILL_VALID` | Proposto para auditoria em **P5.5 / P9.5**. |
| **S5** | Tool Registry / Progressão de Ferramentas | `ABSORBED` | `shared/registry/tools.lua` e `Config.Tools` entregues na v1.16. |
| **S6** | Economia de Salvage & Sinks de Materiais | `STILL_VALID` | Especificado em **P8.4**. |
| **S7** | Reuso de peças inteiras por oficinas (`engine`) | `STILL_VALID` | Especificado em **P7.4**. |
| **X1** | Mutação de estado via client sem validação | `REJECTED` | Violação gravíssima de Trust-No-Client. |
| **X2** | Payout calculado com input do client | `REJECTED` | Todo cálculo econômico é 100% server-authoritative. |
| **X3** | Placa como chave primária de ownership | `REJECTED` | Placas são adulteráveis (fake plates); a identidade real reside no `vehicleid` (qbx). |
| **X4** | Item de inventário por peça individual | `REJECTED` | Modelo físico adotado com carregamento no braço (`physical carry`). |
| **X5** | Confiar em minigame/progressbar de client | `REJECTED` | O servidor autoriza, cronometra e revalida a janela física. |

---

### 2.4 Conceitos Específicos & Ideias Futuras

| Conceito / Feature | Status | Destino no Roadmap |
|---|:---:|---|
| **Vehicle Boosting System** | `DEFERRED` | Alocado em **v2.x (Opcional)**; desnecessário para o core de desmanche. |
| **Ownable Chopshops / Galpões Privados** | `DEFERRED` | Alocado em **v2.x (Opcional)**; complexidade imobiliária/society fora de escopo. |
| **Automated Employees / NPC Workers** | `DEFERRED` | Alocado em **v2.x (Opcional)**; risco de automação passiva de economia (AFK farming). |
| **Leilões de Veículos / Bidding War NUI** | `DEFERRED` | Alocado em **v2.x (Opcional)**. |
| **Novo MDT Policial Standalone** | `REJECTED` | O `vp_chopshop` provê perícia e integra com MDTs existentes via bridge (`VPChopMDT`), sem duplicar UIs policiais. |
