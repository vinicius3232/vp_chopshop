# POST_V118_ROADMAP.md — Canonical Future Roadmap (v1.19 → v1.23+)

> **Status:** CANONICAL ARCHITECTURAL ROADMAP (Fases 5 a 9)  
> **Baseline Base SHA:** `7ba20804cfb4bdffeeadda9b569b610c6fe83586`  
> **Branch:** `docs/post-v118-future-roadmap-prep`  
> **Target Production Version:** `v1.19.0` (Fase 5) até `v1.23.0` (Fase 9)

---

## Sumário Executivo do Roadmap

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│ MASTER EVOLUTION MAP (Pós-v1.18)                                                           │
├───────────────┬─────────────────────────────────────────────────────────────────────────────┤
│ FASE 5 (v1.19)│ WORKSHOP LIVE & DURABLE PARTS FOUNDATION (P5.0 → P5.5 + RC)                 │
│ FASE 6 (v1.20)│ CRIMINAL NETWORK & GANGS (P6.1 → P6.6)                                      │
│ FASE 7 (v1.21)│ PARTS LIFECYCLE & VEHICLE REBUILDING (P7.1 → P7.7)                          │
│ FASE 8 (v1.22)│ ADVANCED ECONOMY & LIVING MARKET (P8.1 → P8.7)                              │
│ FASE 9 (v1.23)│ OPERATIONS, TELEMETRY & SCALE (P9.1 → P9.6)                                 │
├───────────────┼─────────────────────────────────────────────────────────────────────────────┤
│ v2.x          │ OPTIONAL / DEFERRED (Boosting, Ownable Shops, Employees, Auctions, MDT)     │
└───────────────┴─────────────────────────────────────────────────────────────────────────────┘
```

---

## FASE 5 — v1.19: WORKSHOP LIVE & DURABLE PARTS FOUNDATION

Esta fase conecta a infraestrutura transacional do `WorkshopBridge` (congelada na v1.17) a ecossistemas mecânicos reais e estabelece a camada de **Peça Física Durável e Persistente** com recuperação seletiva pós-restart.

### P5.0 — Upstream Workshop Contract Audit
- **Objetivo:** Auditar e documentar a compatibilidade real de APIs públicas de mecânicos upstream (ex.: `qbx_mechanics`, `qb-mechanicjob`, `renzu_customs`).
- **Diretriz:** Proibido inventar exports ou assumir contratos inexistentes. Provedor padrão continua `none` (seguro e fail-soft).
- **Entregáveis:** `docs/research/WORKSHOP_UPSTREAM_AUDIT.md` com matriz de compatibilidade e assinatura dos métodos `PreparePurchase`, `CommitPurchase`, `AbortPurchase` e `GetTransactionStatus`.

### P5.1 — QBox Mechanics Adapter
- **Objetivo:** Implementar o adaptador oficial para o ecossistema QBox Mechanics dentro de `bridge/workshop.lua`.
- **Invariante:** Zero lógica de oficina dentro do core de desmanche. O `WorkshopBridge` mantém a autoridade estrita da SAGA em 2 fases (`PREPARED → COMMITTED / ABORTED`) com persistência na tabela `vp_chop_workshop_journal`.
- **Isolamento:** Falhas na oficina resultam em abort automático e quarentena segura da peça física.

### P5.2 — Additional Workshop Adapters
- **Objetivo:** Adicionar adaptadores adicionais auditados (ex.: Renzu / QS) baseados na demanda real do servidor.
- **Critério de Inclusão:** Cada adapter exige conformidade total com idempotência, detecção de restart, reconexão de jogador e fail-soft.

### P5.3 — B2B Workshop Orders
- **Objetivo:** Permitir que oficinas mecânicas operadas por jogadores gerem ordens de compra reais para o Broker de Desmanche.
- **Regras Econômicas:**
  - Proibido simular "mecânicos online" como demanda fake.
  - A ordem de compra B2B precisa ter lastro financeiro bloqueado no cofre da oficina.
  - O NPC Intermediário (Broker) continua como liquidez de fallback caso nenhuma oficina demande o item.

### P5.4 — Persistent Physical Part / Provenance V2 (CRÍTICO)
- **Objetivo:** Evoluir o `PartEntitlement` (autoridade logística in-memory) para uma entidade de **Peça Física Durável** que sobrevive a reinicializações de servidor mantendo sua linhagem e integridade.
- **Campos de Domínio Canônicos:**
  - `partId` (`stablePartIdentity` — UUIDv4 / PK persistente)
  - `partType` (ex.: `adv_engine`, `door`, `catalytic_converter`)
  - `serial` (identificador alfanumérico ou `nil` se riscado)
  - `sourceVehicle` / `sourceSession` (metadados de auditoria forense)
  - `sourceModel` / `vehicleClass` (classe GTA e identificador server-safe)
  - `condition` / `quality` (0.00 .. 1.00)
  - `legalState` (`stolen` | `scratched` | `forged` | `legal` | `refurbished`)
  - `installedVehicle` (destino terminal se acoplada a um veículo)
- **Invariante:** `PartEntitlement` continua como autoridade de transporte/posse; a peça durável armazena o histórico e ciclo de vida.

### P5.5 — Selective Restart Recovery
- **Objetivo:** Implementar recuperação seletiva pós-restart baseada no estudo `RESTART_RECOVERY_STUDY.md`.
- **Classificação de Estado:**
  - **Efêmero (Limpo no Boot):** `ChopSession`, `ActionSession`, `ProcessSession`, cooldowns temporários em memória.
  - **Durável (Reconciliado no Boot):** `vp_chop_carcass` (tombstones), `vp_chop_workshop_journal` (SAGA em andamento), `vp_chop_physical_parts` (peças duráveis no mundo/inventário), `vp_chop_tyre_entitlement`.

### P5-RC — Workshop Live Release Gate
- Release gate estático (100% de asserts novos cobrindo SAGA + durabilidade).
- Matriz de Live QA FiveM com cenários de crash de oficina, crash de servidor no meio do `PREPARED` e teste de duplicação zero.

---

## FASE 6 — v1.20: CRIMINAL NETWORK & GANGS

Integração com o ecossistema social e territorial do `vp_gangs`, preservando rigorosamente o boundary de domínio.

### P6.1 — Territory Tax / Chop Zones
- **Boundary:** `vp_chopshop` consulta `bridge/vp_gangs.lua` para verificar se as coordenadas da ação pertencem a uma zona dominada.
- **Mecânica:** Aplicação de taxa territorial ou retenção de fatia de comissão pelo domínio da facção local.

### P6.2 — Territory Economic Bonus
- Modificadores de payout ou redução de heat para membros da facção que operam desmanche dentro do seu próprio território.

### P6.3 — Rival Territory Alert
- Operar desmanche em território hostil emite sinalização silenciosa ou alerta para o painel de rádio/notificação da gang dominante.

### P6.4 — Cooperative / Gang Contracts
- Contratos especiais de alto escalão exigindo esforço coordenado de múltiplos jogadores (ex.: roubo de comboio de 3 SUVs blindados ou entrega de lote completo de 4 motores V8).
- O payout é rateado de forma server-authoritative entre os participantes registrados.

### P6.5 — Specialized Buyers
- Compradores do submundo especializados por nicho:
  - *O Mecânico Fantasma:* Compra exclusiva de motores de alta performance.
  - *O Receptor de Catalisadores:* Compra massiva de metais preciosos.
  - *O Hacker de ECUs:* Compra de módulos eletrônicos descaracterizados.
- **Regra:** O contato social pertence ao `vp_gangs` (Trap Phone); a verificação da integridade da peça pertence ao `vp_chopshop`.

### P6.6 — Contacts & Trap Phone Contracts
- Contratos pontuais enviados dinamicamente via mensagens de rádio ou Trap Phone pelo `vp_gangs`, consumindo os dados da peça durável via bridge versionada.

---

## FASE 7 — v1.21: PARTS LIFECYCLE & VEHICLE REBUILDING

Evolução da cadeia mecânica: descaracterização, restauração, compatibilidade e montagem de veículos completos.

### P7.1 — Condition & Quality V2
- O estado de conservação da peça removida deixa de ser binário e passa a refletir a saúde real dos componentes do veículo roubado (`EngineHealth`, `BodyHealth`, colisões sofridas).
- Fórmulas de qualidade 100% derivadas server-side (zero confiança em metadados de client).

### P7.2 — Part Compatibility Engine
- Matriz canônica de compatibilidade mecânica gerenciada pelo `vp_chopshop`:
  - Famílias de motores (Inline-4, V6, V8, Turbo/Supercharged).
  - Classes e tamanhos de chassi elegíveis.
  - Restrições estruturais de transmissão e suspensão.

### P7.3 — Part Processing & Refurbishment
- Processamento físico na bancada (`chopshop_bench`):
  - Retífica de blocos de motor danificados consumindo ferramentas e sucatas nobres.
  - Limpeza química e restauração de painéis amassados.
  - Descaracterização física (*Refurbishment*) distinta de legalização burocrática.

### P7.4 — Reusable Components
- Integração das peças físicas restauradas para substituição direta em veículos avariados em oficinas parceiras.

### P7.5 — Salvage Title / Rolling Chassis
- Aquisição legal de carcaças batidas / chassi baixado em leilão civil para servir de base de reconstrução.

### P7.6 — Full Vehicle Assembly
- Montagem sequencial de um veículo completo em bancada/elevador hidráulico:
  - Instalação do bloco de motor, transmissão, suspensão, portas e chicote elétrico.
  - **Invariante Terminal:** A peça instalada é terminalmente destruída no inventário e vinculada irreversivelmente à nova entidade veicular.

### P7.7 — VIN Rebirth & Civil Registration
- Processo de legalização burocrática e emissão de nova placa/VIN legítimo para veículos restaurados:
  - `Linhagem → Peças Compatíveis → Recondicionamento → Montagem Atestada → Validação Policial/Civil → Emissão no qbx_vehicles`.

---

## FASE 8 — v1.22: ADVANCED ECONOMY & LIVING MARKET

### P8.1 — Regional Market Multipliers
- A demanda do mercado dinâmico varia por região geográfica (ex.: Norte / Sul / Docas / Sandy Shores) sem quebrar o piso e teto do `BrokerMarket`.

### P8.2 — Specialized Demand Aggregation
- Unificação transparente da demanda de oficinas (B2B), contratos do Broker e compradores especializados em uma única fila econômica sem duplicação de liquidez.

### P8.3 — Scarcity & Supply Shock Events
- Eventos dinâmicos server-side (ex.: escassez temporária de alumínio, alta demanda de catalisadores por sindicatos industriais).

### P8.4 — Salvage Sources & Material Sinks
- Novos sumidouros econômicos para metais processados (`metalscrap`, `copper`, `steel`) para impedir hiperinflação de itens.

### P8.5 — Syndicate Ambush V2
- Emboscadas e perseguições de facções rivais escalonadas dinamicamente com base no valor da carga transportada, heat acumulado e território invadido.

### P8.6 — Contract Retaliation
- Consequências severas (emboscadas e perda de trust) caso contratos de alta relevância sejam abandonados ou fraudados.

### P8.7 — Audio, VFX & Immersion Polish
- Efeitos sonoros espaciais de serra, maçarico, faíscas e desmontagem mecânica.

---

## FASE 9 — v1.23: OPERATIONS, TELEMETRY & SCALE

### P9.1 — Broker & Workshop Telemetry
- Dashboard de métricas em tempo real para staff (volume financeiro movimentado, taxa de conversão B2B, índice de quarentenas).

### P9.2 — Transaction Audit Tools
- Visualizador administrativo da SAGA transacional (`vp_chop_workshop_journal`) e histórico de compensações.

### P9.3 — Economic Anomaly & Exploit Detection
- Sensores heurísticos server-side para identificação de velocity spikes, tentativas de replay de rede ou manipulações de preço.

### P9.4 — Multiplayer Soak Testing
- Bateria de testes de estresse com 20+ jogadores simultâneos operando desmanches e vendas concorrentes.

### P9.5 — Chaos & Partition QA
- Simulação deliberada de falhas de rede, queda de MySQL e reinicializações forçadas durante commits financeiros.

### P9.6 — Performance & Resmon Gate
- Auditoria rigorosa de resmon (Client < 0.02ms idle, Server < 0.50ms tick rate) e otimização de queries `oxmysql`.

---

## v2.x — OPTIONAL / DEFERRED (Fora do Escopo Atual)

Os seguintes recursos permanecem em estado **DEFERRED** e não serão implementados sem autorização explícita do proprietário do produto:
1. **Vehicle Boosting System:** Aplicativo de contratos de roubo por hacking eletrônico.
2. **Ownable Chopshops / Society Real Estate:** Compra e gestão de galpões privados de desmanche.
3. **Automated Employees / NPC Workers:** Desmanche autônomo passivo.
4. **Auctions & Bidding War NUI:** Sistema de leilão em tempo real de carcaças.
5. **Standalone Police MDT:** Interface própria de polícia (mantém-se a integração via exports/bridge com MDTs existentes).

---

## Procedimento de Integração Pós-RC

Após o merge da PR #52 em `pr-h/v1.15-delivercar-terminal-hardening`:
1. Fazer checkout desta branch `docs/post-v118-future-roadmap-prep`;
2. Executar rebase sobre o novo HEAD de `pr-h`;
3. Atualizar a tabela de macrofases no `docs/design/MASTER_IMPLEMENTATION_PLAN.md`;
4. Abrir a PR documental de consolidação do roadmap.
