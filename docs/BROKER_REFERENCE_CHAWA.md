# BROKER REFERENCE — chawa_choplist vs vp_chopshop v1.17

**Data:** 2026-09-01  
**Autor:** Lead Gameplay Systems Architect & Principal Engineer  
**Referência Externa:** [`imchawa/chawa_choplist`](https://github.com/imchawa/chawa_choplist)  
**Status:** ESTUDO COMPARATIVO DE GAMEPLAY & ARQUITETURA DE SEGURANÇA

---

## 1. Visão Geral do chawa_choplist

O `chawa_choplist` é um recurso FiveM focado na experiência de "lista de veículos para desmanche" (Chop List). Seu loop principal consiste em:
1. Um contato/NPC entrega periodicamente uma lista de carros procurados.
2. O jogador caça os veículos na cidade, rouba, despista a polícia e entrega no ponto de desmanche.
3. O script oferece streaks, tiers de reputação, missões de elite/hot jobs e notificações policiais com rastreador.

### Pontos Fortes de Gameplay do chawa:
- Sensação de "caçada" e objetivo diário claro (listas dinâmicas).
- Progressão de reputação perceptível e recompensadora.
- Personalidade do NPC com diálogos contextuais e reações à performance do jogador.

### Limitações Arquiteturais & Vulnerabilidades Clássicas do chawa:
- **Trust-Client:** Frequentemente confia em metadados enviados pelo client (modelo de veículo, classe, cálculo de multiplicadores e conclusão).
- **Sem física ou desmanche peça a peça:** É essencialmente um sistema de *car delivery* (entrega de veículo inteiro), sem a riqueza do desmanche físico de peças, bancada, serra, solda, furto de catalisador ou carry nos braços que o `vp_chopshop` possui.
- **Economia fechada e estática:** Pagamentos em dinheiro fixos ou puramente aleatórios, sem relação com oferta/demanda real do servidor nem integração modular com oficinas de jogadores.

---

## 2. Matriz Comparativa: chawa_choplist vs vp_chopshop v1.17

| Feature / Mecânica | Como chawa faz | Vale para vp_chopshop? | Como adaptar no vp_chopshop | Risco de Segurança / Economia | Decisão Final |
|---|---|---|---|---|---|
| **NPC Rotativo & Oculto** | Ped spawna em posições configuradas; muda a cada intervalo. | ✅ **SIM** | Já possuímos em `Config.Fence.Locations` com blip dinâmico baseado em Trust. Evoluir para o Chop Broker com diálogos contextuais. | Baixo (já mitigado com spawn síncrono e locks de entidade). | **ADOTAR / POLISH** |
| **Lista de Demanda por Modelo de Veículo** | Gera lista fixa de 3 a 5 modelos específicos no client/server. | ✅ **SIM** | Integrar ao `BrokerContracts` (ex: "Sultan", "Bison"). O servidor resolve o `modelHash` da entidade real na entrega. | Tentativa de spoofing de modelo pelo client $\to$ *Mitigação: servidor extrai `GetEntityModel(veh)`*. | **ADOTAR (Server-Auth)** |
| **Demanda por Classe de Veículo** | Recompensa bônus se o carro for de determinada classe (ex: SUV, Sports). | ✅ **SIM** | Expandir para contratos de peças e veículos: "Preciso de 2 motores de Sports". | Tentativa de spoofing de classe $\to$ *Mitigação: servidor usa `GetVehicleClass(veh)`*. | **ADOTAR** |
| **Contratos de Peças Específicas** | Não possui (foco exclusivo em carro inteiro). | ✅ **SIM (Diferencial do VP)** | Permitir contratos de `adv_engine`, `catalytic_converter`, `door_*`, `tyres` e `stolen_plate` com `PartEntitlement`. | Replay / duping de peças $\to$ *Mitigação: `PartEntitlement.Consume` at-most-once*. | **ADOTAR (Core VP)** |
| **Streaks & Progressão Contínua** | Bônus progressivo por entregas consecutivas no prazo. | ⚠️ **PARCIAL** | Usar a progressão existente `vp_chop_fence_trust` (Trust 0..4) + XP contínuo. Evitar multiplicadores compostos que causem hiperinflação. | Multiplicadores empilhados gerando payout astronômico $\to$ *Mitigação: Hard Cap no preço*. | **ADAPTAR COM CAPS** |
| **Contratos de Alto Valor (Elite / Hot Jobs)** | Veículos raros protegidos com alarme forte e rastreador GPS policial. | ✅ **SIM** | Conectar com o sistema existente `Config.Alarm`, `Config.Dispatch` e `server/heat.lua`. | Client desativar alarme localmente $\to$ *Mitigação: servidor dispara alarme e rastreia o heat da placa*. | **ADOTAR** |
| **Reações e Diálogos do NPC** | Textos no chat ou UI baseados em estado de missão. | ✅ **SIM** | Menus com `ox_lib context` + falas ambientais nativas do ped (`PlayPedAmbientSpeechNative`). Diálogos de saturação, confiança, rejeição e contratos. | Zero risco (puramente cosmético/UX). | **ADOTAR** |
| **Persistência de Contratos** | JSON ou flatfile simples. | ⚠️ **NÃO (Usar SQL)** | Manter persistência no MySQL (`oxmysql`) com índices adequados e limpeza automática de expirados. | Perda de integridade / concorrência $\to$ *Mitigação: queries transacionais com affectedRows*. | **REJEITAR JSON / USAR DB** |
| **Cálculo de Preço e Payout** | `math.random` ou valor estático do config. | ❌ **NÃO** | Desenvolver o `BrokerMarket`: Fórmula de Oferta e Demanda com pressão de volume, saturação e recuperação temporal. | Inflação descontrolada $\to$ *Mitigação: Hard Floor e Hard Ceiling econômicos*. | **REJEITAR RANDOM / CRIAR ENGINE** |
| **Integração com Oficinas / Players** | Inexistente (puramente NPC delivery). | ✅ **SIM (Visão v1.17)** | `WorkshopBridge` modular: Mecânicos de jogadores podem comprar peças com prioridade econômica sobre o NPC fallback. | Race condition entre NPC e Oficina $\to$ *Mitigação: Reserva atômica de entitlement (SAGA)*. | **ADOTAR (Exclusivo VP)** |

---

## 3. Diretrizes Rígidas: O que NUNCA Importar do chawa

1. **Nunca confiar no Client para Identidade de Entidade:**
   - No `vp_chopshop`, o client envia apenas `netId` ou `entitlementId`. O servidor faz a inspeção da entidade real no pool do OneSync (`GetEntityModel`, `GetVehicleNumberPlateText`, `GetVehicleClass`, `GetVehicleEngineHealth`, `BridgeResolveVehiclePersistence`).
2. **Nunca calcular Preço, Bônus ou Recompensas no Client:**
   - Todo multiplicador de trust, tier, bônus noturno, saturação de mercado e índice de demanda é resolvido e aplicado 100% no servidor.
3. **Nunca usar Timeout de Client como Prova de Conclusão:**
   - O servidor impõe timers autoritativos com tolerância estrita (ex: `startedAt` em `catalytic:complete`, `ActionSession` expirations).
4. **Nunca permitir Replay de Entrega:**
   - Entidades entregues recebem marcadores server-side (`writeMark`), tombstones em memória e carimbo no `CarcassLedger`.

---

## 4. Conclusão da Análise

O `chawa_choplist` serve como uma excelente inspiração de **gameplay loop**, **sensação de caçada** e **personalidade do contato**. No entanto, a implementação do `vp_chopshop v1.17` transcenderá o chawa ao:
1. Aplicar a autoridade server-side e a robustez matemática do `BrokerMarket`.
2. Conectar peças físicas desmontadas (`PartEntitlement`), pneus (`TruckStorage`), catalisadores e placas roubadas.
3. Oferecer a ponte modular para a economia de jogadores e oficinas (`WorkshopBridge`), transformando o desmanche em um ecossistema econômico vivo.
