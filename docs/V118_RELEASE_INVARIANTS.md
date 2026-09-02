# v1.18 — Canonical Forensics Release Invariants

> **Status:** RC / PENDING LIVE QA  
> **Versão:** v1.18.0-RC  
> **Data:** 2026-09-02  
> **Referência de Integração:** `pr-h/v1.15-delivercar-terminal-hardening` (base `7ba20804cfb4bdffeeadda9b569b610c6fe83586`)

---

## Os 12 Invariantes Canônicos Forenses e Policiais

### 1. Trust-No-Client
O client FiveM envia apenas intenções de ação, dados de UI e eventos de minigame (`{ netId, action, removalToken }`).
O servidor decide exclusivamente:
- Autorização e prontidão do jogador (`IsValidSource`, `ServerPlayerIsReady`);
- Identidade real do veículo e vínculos de persistência;
- Existência, modelo e estado do rastreador GPS / LoJack;
- Autorização, contagem de tempo mínimo e conclusão de remoção de rastreador;
- Status de raspagem de VIN e adulteração de chassi;
- Resolução de placa canônica versus placa visível;
- Permissões policiais e posse de ferramenta de perícia;
- Consequências econômicas e recompensas de desmanche.

Nenhum resultado de perícia ou estado criminal pode ser determinado ou forjado pelo cliente.

### 2. EvidenceBridge é Opcional e Fail-Soft
A ausência, parada, timeout ou exceção interna em um provider de evidências (`evidences`, `vp_crimescene`, `custom`, `none`):
- **Não** quebra o recurso `vp_chopshop`;
- **Não** impede o desmanche base ou avançado;
- **Não** interfere no funcionamento do Chop Broker, Contratos ou Workshop;
- **Não** afeta a integridade do `TrackerManager` ou do `DispatchBridge`;
- **Não** gera payouts indevidos nem transforma uma ação criminosa falha em sucesso.

A configuração `Config.Evidence.Provider = 'none'` é uma operação standalone válida e homologada.

### 3. Custom Providers Não Podem Ser Hijackados
O registro dinâmico de providers customizados (`RegisterEvidenceProvider` no server-side e `RegisterProvider` em dispatch) preserva isolamento estrito de contexto e de identidade de recurso (`GetInvokingResource`):
- Um recurso caller inválido ou concorrente **não** pode sobrescrever nem substituir arbitrariamente um provider registrado por outro recurso;
- Tentativas de re-registro ou sequestro retornam erro controlado (`already_registered` / `wrong_context`) sem causar falha no servidor ou no resource.

### 4. Evidência Não É Autoridade de Identidade
Providers externos de evidências atuam exclusivamente como receptores (*sinks*) contextuais.
Eles **nunca** decidem:
- A propriedade legítima do veículo;
- A placa real ou autoritativa;
- O valor de payouts financeiros;
- A integridade do VIN ou o status de rastreadores;
- A emissão ou transição de `PartEntitlement`, `TyreEntitlement` ou `ChopSession`.

### 5. Tracker É Server-Authoritative
O servidor é a autoridade única sobre o ciclo de vida do rastreador:
- Determina se o veículo possui rastreador GPS baseado em probabilidade ponderada por classe (`ClassChances`) ou configuração padrão;
- Mantém o estado autoritativo em memória (`ACTIVE`, `REMOVED`, `NONE`);
- Controla e autentica sessões de remoção (`removalToken`, `startedAt`, `expiresAt`, `minDurationMs`);
- Rejeita conclusões antecipadas (`too_fast`), tokens divergentes ou requisições expiradas.

Falhas, cancelamentos ou timeouts durante o minigame **nunca** convertem um rastreador `ACTIVE` em `REMOVED`.

### 6. NetId Não É Identidade Durável
O `netId` do FiveM é um identificador volátil de rede sujeito a reciclagem por pools de entidades:
- Um veículo recém-criado que reutilize um `netId` antigo **não** herda rastreadores, sessões de remoção ou alertas pendentes de lifecycles anteriores;
- A validação de ciclo de vida (`validateTrackerLifecycle` com verificação de handle de entidade, modelo e statebag local `vpChopTrackerId`) invalida e descarta imediatamente rastreadores órfãos ou entidades recicladas;
- Mesma classe ou modelo de veículo não constitui prova de identidade durável.

### 7. GetVehicleState e Leituras Forenses São Estritamente Read-Only
Consultas policiais através do scanner ou comandos periciais:
- **Nunca** chamam `ObserveVehicle`;
- **Nunca** re-rolam chances de rastreador ou alteram o status de LoJack;
- **Nunca** geram novos números de série para motores não desmanchados (`peekVehicleSerial`);
- **Nunca** gravam em statebags, tabelas de banco de dados ou ledgers econômicos;
- **Nunca** consom quotas de contratos, não emitem entitlements e não geram payouts.

O scanner observa o estado existente do mundo; ele **nunca fabrica evidências ou histórico criminal** em decorrência da inspeção.

### 8. Canonical Plate Domain
A placa visível exibida no veículo físico não é necessariamente a placa original de registro:
- A inspeção forense consome a autoridade canônica `VPChopMDT.GetRealPlate(visiblePlate)` (com fallback para `Entity(veh).state.vpFakeRealPlate`);
- O atributo `plateDisguised` é computado estritamente como verdadeiro quando `canonicalRealPlate ~= ''` e `canonicalRealPlate ~= visiblePlate`;
- **Zero ocorrências** do identificador legado `vpChopPlateOriginal` no caminho de produção.

### 9. VIN É Tri-State
O status forense de raspagem de chassi/VIN segue estritamente um contrato tri-state:
- `scratched`: Confirmação positiva de registro na tabela `vp_chop_vin_scratched`;
- `intact`: Confirmação positiva de ausência de registro após consulta bem-sucedida ao banco;
- `unknown`: Erro de comunicação, timeout de banco, banco indisponível (`VPChopDBReady ~= true`) ou placa ilegível.

Falhas de banco de dados **nunca** são mascaradas como VIN intacto ou falsamente acusadas como chassi adulterado.

### 10. DispatchBridge É Transporte, Não Julgamento
O DispatchBridge atua exclusivamente como barramento de transporte para despacho de chamados policiais:
- O domínio criminal (desmanche, furto de catalisador, pings de LoJack) decide quando um alerta deve ser emitido;
- Falhas, timeouts ou indisponibilidade de um sistema de dispatch externo:
  - **Não** cancelam nem concedem recompensas financeiras;
  - **Não** abortam desmanches legítimos;
  - **Não** travam o funcionamento do `TrackerManager`, `EvidenceBridge` ou `Broker`.
- A opção `Config.Dispatch.Provider = 'none'` permanece como modo standalone totalmente seguro e sem exceptions.

### 11. Forensic Inspection É Police + Tool + Distance + FeatureFlag
O callback de perícia policial veicular (`vp_chopshop:inspectVehicle`) aplica uma barreira estrita em camadas:
1. `Config.PartSerial.Enable` e `Config.PartSerial.VehicleInspection.Enable` ativos;
2. `IsValidSource(src)` e `ServerPlayerIsReady(src)`;
3. Verificação de cargo policial via `BridgeIsPolice(src, Config.PartSerial.PoliceJobs)`;
4. Posse obrigatória de ferramenta pericial (`parts_scanner` ou `forensic_kit` via `InvCount`);
5. `netId` validado como inteiro positivo finito;
6. `GetEntityType(veh) == 2` (garante entidade do tipo veículo);
7. Validação de proximidade física entre o oficial e as coordenadas do veículo;
8. Rate limiting contra flooding de inspeções.

Nenhuma interface client-side (`ox_target`) substitui ou ignora essas validações server-side.

### 12. Forensics Não Altera a Economia
A camada de crime e perícia v1.18 não altera a autoridade econômica estabelecida:
- `BrokerMarket`, `BrokerContracts`, `WorkshopBridge`, `PartEntitlement`, `TyreEntitlement`, `deliverCar`, tabelas de payout e XP de confiança permanecem matematicamente idênticos ao baseline homologado;
- O harness econômico de 108.000 iterações permanece íntegro, garantindo que a introdução de mecânicas forenses não introduziu regressões ou vazamentos de valor.

---

## Contratos Complementares de Release

### A. Inutilização por Remoção de Motor (`vpChopEngineMissing`)
A remoção do bloco de motor no desmanche avançado marca de forma autoritativa o veículo como mecanicamente inoperante (`vpChopEngineMissing`), impedindo a ignição e condução por qualquer jogador.

### B. Inutilização por Furto de Catalisador (`catalyticStolen`)
Quando `Config.CatalyticTheft.DisableVehicle = true`, o furto consumado do escapamento/catalisador marca o veículo (`catalyticStolen`), bloqueando a ignição do motor até que reparo mecânico seja executado.

### C. Enforcement de Condução Client-Side
O monitoramento client-side em thread dedicada impede a partida do motor em veículos desmanchados ou sem catalisador, com notificações rate-limited e sem fabricação de eventos criminais caso passageiros ou terceiros ingressem no veículo.

### D. Isolamento de Desativação de Módulos (Fail-Safe)
A desativação individual de qualquer submódulo da Fase 4 (`Evidence.Enable = false`, `Tracker.Enable = false`, `Dispatch.Enable = false`, `PartSerial.VehicleInspection.Enable = false`) não quebra o funcionamento dos demais sistemas nem impede o desmanche padrão.

### E. Paridade Linguística Integral (I18N)
Todas as strings de interface pericial, notificações, relatórios do scanner e mensagens de erro possuem equivalência completa nos 5 idiomas suportados (`en`, `pt`, `es`, `fr`, `tr`), sem fallback cru ou textos hardcoded.
