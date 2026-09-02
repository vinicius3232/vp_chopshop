# v1.18 — Forensics Live QA & Release Verification Matrix

> **Versão:** v1.18.0-RC  
> **Data de Emissão:** 2026-09-02  
> **Escopo:** Validação completa, auditável e reproduzível in-game / FiveM da stack de Crime & Perícia Policial v1.18 (`EvidenceBridge`, `TrackerManager` / LoJack, `DispatchBridge`, Scanner Forense Read-Only, Adulteração de Séries/VIN, Placas Canônicas e Inutilização Veicular Anti-Farm).  
> **Status Geral:** PENDING EXECUTION

---

## Instruções de Execução

1. Cada caso de teste deve ser executado em ambiente runtime real FiveM (QBox / ox_lib / ox_target / ox_inventory / oxmysql).
2. **Nenhum** item pode ser marcado como `[X]` antes da execução efetiva por um testador humano / QA.
3. Registre evidências reais (prints, IDs de transação, logs de console) na linha `Evidence:` e discrepâncias em `Observed:`.
4. Todas as rejeições de segurança devem falhar de forma fechada (*fail-closed*), sem vazar estado, criar dinheiro ou fabricar evidência.

---

## QA-A — BOOT / RESOURCE LIFECYCLE

- [ ] **QA-A01:** Start do resource em banco com schema v1.18 (`vp_chop_vin_scratched`, `vp_chop_fake_plates`).
  - **Preconditions:** Banco MySQL pronto (`oxmysql`), sem erros prévios.
  - **Steps:** Executar `ensure vp_chopshop` no console do servidor.
  - **Expected:** Inicialização limpa, `VPChopDBReady == true`, 0 erros de sintaxe ou nil indexing.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-A02:** Restart do resource durante runtime (`restart vp_chopshop`).
  - **Preconditions:** Servidor FiveM ativo com jogadores conectados.
  - **Steps:** Executar `restart vp_chopshop`.
  - **Expected:** Resource reinicia sem exceptions, restabelece bridges e limpa sessões de ação voláteis de forma segura.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-A03:** Restart completo do servidor FiveM.
  - **Preconditions:** Veículos com motor desmanchado previamente no mapa.
  - **Steps:** Reiniciar o servidor e reconectar.
  - **Expected:** Boot sequencial normal, handlers registrados, zero deadlocks em `MySQL.ready`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-A04:** Console do servidor e F8 sem exceptions não tratadas.
  - **Preconditions:** Resource em execução ativa.
  - **Steps:** Monitorar logs de server e client por 10 minutos durante uso.
  - **Expected:** 0 mensagens SEVERE ou stack traces não tratados.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-A05:** Inicialização com Provider de Evidência ausente/parado.
  - **Preconditions:** `Config.Evidence.Provider = 'evidences'`, mas resource `evidences` parado.
  - **Steps:** Iniciar `vp_chopshop`.
  - **Expected:** Warning limpo informando provider indisponível; resource opera em modo seguro sem crash.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-A06:** Inicialização com Provider de Dispatch ausente/parado.
  - **Preconditions:** `Config.Dispatch.Provider = 'auto'`, nenhum resource de dispatch iniciado.
  - **Steps:** Iniciar `vp_chopshop`.
  - **Expected:** DispatchBridge fallback para 'none' silencioso; zero crash no servidor.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-A07:** Providers externos de evidência/dispatch iniciados dinamicamente pós-boot.
  - **Preconditions:** `vp_chopshop` rodando com provider ausente.
  - **Steps:** Executar `start cd_dispatch` ou `start evidences`.
  - **Expected:** Dispatch/Evidence detectam o provider em runtime sem necessidade de reiniciar `vp_chopshop`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-A08:** Configuração com Provider='none' para Evidência e Dispatch.
  - **Preconditions:** `Config.Evidence.Provider = 'none'` e `Config.Dispatch.Provider = 'none'`.
  - **Steps:** Executar ciclo de desmanche e furto de catalisador.
  - **Expected:** Operação standalone 100% fluida, zero chamadas externas, zero erros.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-A09:** Submódulos P4 desligados individualmente nas flags de configuração.
  - **Preconditions:** Desativar `Config.Tracker.Enable = false` ou `Config.PartSerial.VehicleInspection.Enable = false`.
  - **Steps:** Testar desmanche na oficina e no Broker.
  - **Expected:** Funcionalidades desabilitadas não aparecem nos targets; economia e desmanche operam perfeitamente.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

---

## QA-B — EVIDENCEBRIDGE

- [ ] **QA-B01:** Crime elegível de desmanche gera evidência de vestígio.
  - **Preconditions:** Jogador sem luvas desmancha porta de veículo.
  - **Steps:** Completar desmanche avançado da porta.
  - **Expected:** Evidência deixada no local com tipo e placa canônica associada.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-B02:** Uso de luvas bloqueia impressão digital (*fingerprint*).
  - **Preconditions:** Jogador equipado com item de luva configurado.
  - **Steps:** Realizar corte de peça ou remoção de catalisador.
  - **Expected:** Zero evidência de impressão digital gerada; apenas vestígios materiais se aplicável.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-B03:** Evidência de DNA em caso de dano ou corte sangrento.
  - **Preconditions:** Jogador com saúde baixa ou sofrendo falha física.
  - **Steps:** Executar corte perigoso gerando vestígio biológico.
  - **Expected:** Evidência de sangue/DNA gerada no ponto exato.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-B04:** Integração com provider `evidences`.
  - **Preconditions:** Resource `evidences` iniciado e configurado.
  - **Steps:** Realizar ação de desmanche.
  - **Expected:** Evidência registrada no sistema `evidences`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-B05:** Integração com provider `vp_crimescene`.
  - **Preconditions:** Resource `vp_crimescene` iniciado e configurado.
  - **Steps:** Realizar ação de desmanche.
  - **Expected:** Marcador de cena de crime registrado no formato canônico.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-B06:** Integração com custom provider via `RegisterEvidenceProvider`.
  - **Preconditions:** Script de teste registra handler customizado no client.
  - **Steps:** Acionar desmanche de peça.
  - **Expected:** Handler customizado recebe evento formatado.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-B07:** Tentativa de hijacking de provider customizado.
  - **Preconditions:** Resource B tenta registrar provider já registrado pelo Resource A.
  - **Steps:** Executar `RegisterEvidenceProvider` a partir de outro recurso.
  - **Expected:** Rejeição segura com `already_registered`; provider original inalterado.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-B08:** Provider `none` standalone.
  - **Preconditions:** `Config.Evidence.Provider = 'none'`.
  - **Steps:** Completar desmanche de 4 portas e carcaça.
  - **Expected:** 0 chamadas externas, 0 logs de erro, recompensa entregue normalmente.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-B09:** Falha interna (crash/exception) no provider de evidência.
  - **Preconditions:** Handler do provider lança erro propositalmente.
  - **Steps:** Desmanchar peça.
  - **Expected:** `pcall` captura o erro (fail-soft); o jogador recebe sua peça/recompensa sem interrupção.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-B10:** Stop do resource de evidência durante gameplay.
  - **Preconditions:** Jogador iniciando desmanche.
  - **Steps:** Parar o resource de evidência no exato instante do commit da peça.
  - **Expected:** Desmanche finaliza com sucesso; log registra indisponibilidade sem travar a thread.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

---

## QA-C — GPS / LOJACK

- [ ] **QA-C01:** Veículo comum sem rastreador GPS.
  - **Preconditions:** Veículo de classe baixa (ex.: compacto/sedan comum).
  - **Steps:** Inspecionar e interagir com o veículo.
  - **Expected:** `TrackerManager.GetVehicleState` retorna `'NONE'`, nenhum ping emitido.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C02:** Veículo de alto valor com rastreador GPS ativo.
  - **Preconditions:** Veículo de classe esportiva/super (`ClassChances` configurado).
  - **Steps:** Observar veículo e entrar como motorista.
  - **Expected:** Rastreador `ACTIVE` registrado no servidor, início da emissão periódica de pings.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C03:** Recepção de sinal e blip policial de LoJack.
  - **Preconditions:** Policial em serviço (`BridgeIsPolice == true`).
  - **Steps:** Veículo com LoJack ativo em movimento.
  - **Expected:** Policial recebe coordenadas aproximadas / blip com raio estático; civis NÃO recebem o alerta.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C04:** Busca e localização do rastreador físico no veículo.
  - **Preconditions:** Jogador criminoso com alicate (`pliers`) próximo ao capô/chassi.
  - **Steps:** Selecionar target `[Procurar Rastreador GPS]`.
  - **Expected:** Barra de progresso / animação de busca informa se há rastreador instalado.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C05:** Remoção bem-sucedida de rastreador via minigame.
  - **Preconditions:** Rastreador localizado, jogador possui `pliers`.
  - **Steps:** Iniciar remoção, acertar o minigame de corte e aguardar `MinDurationMs`.
  - **Expected:** Rastreador transiciona para `REMOVED`, pings policiais cessam imediatamente.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C06:** Falha no minigame de remoção de rastreador.
  - **Preconditions:** Jogador inicia remoção de LoJack.
  - **Steps:** Errar as teclas do minigame.
  - **Expected:** Ação cancelada, rastreador permanece `ACTIVE`, alerta policial imediato emitido por sabotagem.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C07:** Cancelamento manual pelo jogador durante remoção.
  - **Preconditions:** Remoção em andamento.
  - **Steps:** Jogador pressiona tecla de cancelar / anda para trás.
  - **Expected:** Remoção abortada de forma limpa, rastreador permanece `ACTIVE`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C08:** Jogador se afasta fisicamente durante a remoção.
  - **Preconditions:** Remoção em andamento.
  - **Steps:** Mover o ped para além de 3.0 metros do veículo.
  - **Expected:** Validação de distância server-side aborta a transação com `too_far`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C09:** Jogador perde a ferramenta (`pliers`) durante a remoção.
  - **Preconditions:** Remoção iniciada com alicate no bolso.
  - **Steps:** Alicate dropado por outro script/comando antes da conclusão.
  - **Expected:** Servidor revalida posse de ferramenta no commit e rejeita com `no_tool`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C10:** Timeout de sessão de remoção de rastreador.
  - **Preconditions:** Sessão de remoção iniciada no servidor.
  - **Steps:** Segurar o payload de conclusão até após `expiresAt` (ex.: >15 segundos).
  - **Expected:** Servidor rejeita a finalização com `expired`, sessão é limpa.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C11:** Tentativa de replay de conclusão de remoção (Double Complete).
  - **Preconditions:** Remoção concluída com sucesso.
  - **Steps:** Reenviar o mesmo `removalToken`.
  - **Expected:** Servidor rejeita com `no_session` ou `invalid_token`; zero efeitos colaterais.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C12:** Dois jogadores tentando remover o mesmo rastreador em simultâneo.
  - **Preconditions:** Veículo com LoJack ativo.
  - **Steps:** Jogador A e Jogador B iniciam remoção ao mesmo tempo.
  - **Expected:** Exatamente um jogador obtém a trava e conclui; o segundo é rejeitado de forma atômica.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C13:** Desconexão do jogador durante o corte do rastreador.
  - **Preconditions:** Jogador no meio do minigame de remoção.
  - **Steps:** Forçar `quit` no console do jogador.
  - **Expected:** Sweeper limpa a sessão órfã; veículo permanece com rastreador `ACTIVE`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C14:** Restart de resource com rastreadores ativos no mapa.
  - **Preconditions:** Veículos com LoJack no mapa.
  - **Steps:** Executar `restart vp_chopshop`.
  - **Expected:** Rastreadores limpos de forma segura; novas observações recriam lifecycles saudáveis.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C15:** Reciclagem de `netId` FiveM.
  - **Preconditions:** Veículo deletado e novo veículo spawnado recebendo o mesmo `netId`.
  - **Steps:** Consultar status de rastreador no novo veículo.
  - **Expected:** `validateTrackerLifecycle` detecta divergência de statebag/handle e reseta para o novo veículo.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C16:** Mesmo modelo spawnado em novo ciclo de vida.
  - **Preconditions:** Spawnar dois veículos idênticos (ex.: Sultan).
  - **Steps:** Remover rastreador do primeiro e inspecionar o segundo.
  - **Expected:** O segundo veículo não é afetado pelo estado de remoção do primeiro.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-C17:** Confirmação definitiva de cessação de pings policiais.
  - **Preconditions:** Rastreador marcado como `REMOVED`.
  - **Steps:** Conduzir o veículo pelo mapa por 5 minutos.
  - **Expected:** Zero novos chamados/pings policiais emitidos aos oficiais.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

---

## QA-D — DISPATCHBRIDGE

- [ ] **QA-D01:** Alerta formatado para `ps-dispatch`.
  - **Preconditions:** `ps-dispatch` ativo.
  - **Steps:** Disparar alarme de furto de catalisador.
  - **Expected:** Chamado 10-90 criado com coordenadas, modelo, placa e jobs policiais corretos.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-D02:** Alerta formatado para `cd_dispatch`.
  - **Preconditions:** `cd_dispatch` ativo.
  - **Steps:** Disparar alarme de corte de catalisador.
  - **Expected:** Notificação `cd_dispatch:AddNotification` recebida pelos oficiais com blip temporizado.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-D03:** Alerta formatado para `qs-dispatch`.
  - **Preconditions:** `qs-dispatch` ativo.
  - **Steps:** Disparar alarme de corte.
  - **Expected:** Evento `qs-dispatch:server:CreateDispatchCall` executado com tempo em milissegundos.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-D04:** Alerta formatado para `op-dispatch`.
  - **Preconditions:** `op-dispatch` ativo.
  - **Steps:** Disparar alarme de furto.
  - **Expected:** Evento `Opto_dispatch:Server:SendAlert` acionado para cada cargo policial configurado.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-D05:** Alerta formatado para `core_dispatch`.
  - **Preconditions:** `core_dispatch` ativo.
  - **Steps:** Disparar alarme de desmanche.
  - **Expected:** Export `sendAlert` acionado com título, código e duração corretos.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-D06:** Sanitização de coordenadas e prevenção de NaN/Inf.
  - **Preconditions:** Ação executada sem coordenadas manuais ou com entidade deletada.
  - **Steps:** Disparar alerta via helper genérico.
  - **Expected:** Fallback seguro para coordenadas do ped do jogador; zero falhas de dispatch.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-D07:** Provider `none` em modo inerte.
  - **Preconditions:** `Config.Dispatch.Provider = 'none'`.
  - **Steps:** Falhar corte de catalisador com `PoliceAlertOnFail = 100`.
  - **Expected:** Função retorna `false, 'none'`, zero alertas e zero exceptions no console.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-D08:** Modo `auto` seleciona o primeiro dispatch iniciado.
  - **Preconditions:** `Config.Dispatch.Provider = 'auto'`, `ps-dispatch` rodando.
  - **Steps:** Disparar evento criminal.
  - **Expected:** `ps-dispatch` acionado automaticamente com prioridade correta.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-D09:** Isolamento contra falha interna do sistema de dispatch.
  - **Preconditions:** Script de dispatch externo quebrado ou lançando erro.
  - **Steps:** Disparar alarme de desmanche.
  - **Expected:** `pcall` no bridge captura a exceção; o fluxo criminal não é interrompido.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-D10:** Restrição de audiência estritamente policial.
  - **Preconditions:** Alerta de LoJack ou furto disparado.
  - **Steps:** Monitorar telas de jogador civil e policial.
  - **Expected:** Apenas jogadores em cargos policiais recebem o chamado e visualizam o blip no mapa.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

---

## QA-E — FORENSIC VEHICLE SCANNER

- [ ] **QA-E01:** Cidadão civil tenta usar o scanner veicular.
  - **Preconditions:** Jogador civil (`BridgeIsPolice == false`) com `parts_scanner` no bolso.
  - **Steps:** Tentar inspecionar veículo.
  - **Expected:** Rejeição server-side com `not_police`; zero dados do relatório exibidos.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E02:** Policial sem ferramenta pericial.
  - **Preconditions:** Policial em serviço sem `parts_scanner` e sem `forensic_kit`.
  - **Steps:** Tentar interagir no target veicular.
  - **Expected:** Target bloqueado ou callback retorna `no_tool`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E03:** Policial equipado com `parts_scanner`.
  - **Preconditions:** Policial em serviço com `parts_scanner`.
  - **Steps:** Executar perícia no veículo.
  - **Expected:** Progresso de 5 segundos executado, relatório pericial exibido no menu `ox_lib`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E04:** Policial equipado com `forensic_kit`.
  - **Preconditions:** Policial em serviço com `forensic_kit` (sem scanner).
  - **Steps:** Executar perícia no veículo.
  - **Expected:** Inspeção autorizada com flag `forensic = true` e relatório completo.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E05:** Validação de distância física da perícia.
  - **Preconditions:** Policial inicia inspeção e corre para longe antes do fim da barra.
  - **Steps:** Concluir o tempo da barra a 10 metros de distância.
  - **Expected:** Servidor rejeita a abertura do relatório por proximidade inválida.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E06:** Rejeição de entidades que não sejam veículos (Ped / Object).
  - **Preconditions:** Enviar `netId` de um ped ou objeto ao callback `inspectVehicle`.
  - **Steps:** Disparar requisição pericial.
  - **Expected:** Servidor rejeita imediatamente com `not_vehicle` (`GetEntityType ~= 2`).
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E07:** Relatório: Motor presente com número de série gravado.
  - **Preconditions:** Veículo teve motor desmanchado previamente e recolocado ou possui série gravada.
  - **Steps:** Realizar perícia policial.
  - **Expected:** Exibe badge verde `[Motor Íntegro]` e descrição com número de série.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E08:** Relatório: Motor removido / Bloco ausente.
  - **Preconditions:** Veículo teve o motor arrancado na oficina (`vpChopEngineMissing`).
  - **Steps:** Realizar perícia policial.
  - **Expected:** Exibe badge vermelho `[Motor Ausente]` com aviso de cofre vazio.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E09:** Relatório: Catalisador íntegro.
  - **Preconditions:** Veículo original de fábrica.
  - **Steps:** Realizar perícia policial.
  - **Expected:** Exibe badge verde `[Catalisador Presente]`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E10:** Relatório: Catalisador furtado / Escape cortado.
  - **Preconditions:** Veículo teve o catalisador furtado com serra circular (`catalyticStolen`).
  - **Steps:** Realizar perícia policial.
  - **Expected:** Exibe badge vermelho `[Catalisador Furtado]` com aviso de marcas de serra no cano.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E11:** Relatório: VIN de fábrica intacto.
  - **Preconditions:** Veículo legal sem histórico na tabela `vp_chop_vin_scratched`.
  - **Steps:** Realizar perícia policial.
  - **Expected:** Exibe badge verde `[VIN / Chassi Íntegro]`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E12:** Relatório: VIN raspado / Chassi adulterado.
  - **Preconditions:** Veículo com chassi adulterado registrado em `vp_chop_vin_scratched`.
  - **Steps:** Realizar perícia policial.
  - **Expected:** Exibe badge vermelho `[VIN Raspado / Adulterado]`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E13:** Relatório: VIN em estado desconhecido (DB timeout).
  - **Preconditions:** Falha simulada de banco de dados no momento da consulta.
  - **Steps:** Realizar perícia policial.
  - **Expected:** Exibe badge neutro/laranja `[VIN Indisponível / Ilegível]` sem acusar falso crime.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E14:** Relatório: Status de Rastreador GPS (`active`, `cut`, `none`).
  - **Preconditions:** Testar 3 veículos (um com LoJack ativo, um com LoJack cortado, um sem LoJack).
  - **Steps:** Realizar perícia policial nos 3 veículos.
  - **Expected:** Relatórios exibem respectivamente `[Sinal Ativo]`, `[Rastreador Cortado]` e `[Nenhum Sinal]`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-E15:** Garantia de idempotência e zero efeitos colaterais na repetição de scan.
  - **Preconditions:** Veículo inspecionado 5 vezes consecutivas por 2 policiais.
  - **Steps:** Executar múltiplos scans sequenciais.
  - **Expected:** NENHUM novo serial gerado, NENHUM rastreador criado, NENHUM payout ou alteração em banco.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

---

## QA-F — VEHICLE DISABLEMENT ANTI-FARM

- [ ] **QA-F01:** Tentativa de condução com motor removido (`vpChopEngineMissing`).
  - **Preconditions:** Veículo sem o bloco de motor desmanchado.
  - **Steps:** Jogador entra no banco do motorista e tenta acelerar/ligar ignição.
  - **Expected:** Motor desliga imediatamente; notificação de veículo sem motor exibida.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-F02:** Tentativa de condução com catalisador furtado (`DisableVehicle = true`).
  - **Preconditions:** `Config.CatalyticTheft.DisableVehicle = true`, catalisador cortado.
  - **Steps:** Jogador entra como motorista e tenta dar partida.
  - **Expected:** Ignição desativada; notificação informa escape rompido impedindo condução.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-F03:** Condução permitida quando `DisableVehicle = false`.
  - **Preconditions:** `Config.CatalyticTheft.DisableVehicle = false`, catalisador cortado.
  - **Steps:** Entrar como motorista e acelerar.
  - **Expected:** Veículo funciona normalmente (com barulho de escape livre).
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-F04:** Passageiros e troca de assentos em veículo desmanchado.
  - **Preconditions:** Veículo sem motor.
  - **Steps:** Jogador A entra como passageiro; Jogador B entra como motorista.
  - **Expected:** Passageiro entra normalmente; motorista tem a ignição cortada com rate-limiting.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-F05:** Rate-limiting de notificações de condução bloqueada.
  - **Preconditions:** Motorista segurando acelerador em carro sem motor.
  - **Steps:** Manter tecla 'W' pressionada por 20 segundos.
  - **Expected:** Notificação de aviso exibida no máximo a cada 5 segundos (zero spam visual).
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-F06:** Veículo guinchado / rebocado sem motor.
  - **Preconditions:** Veículo sem motor.
  - **Steps:** Caminhão de reboque (Flatbed) carrega a carcaça.
  - **Expected:** Veículo pode ser rebocado fisicamente sem interferência de scripts.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-F07:** Restauração veicular após reparo mecânico.
  - **Preconditions:** Veículo inutilizado.
  - **Steps:** Mecânico instala novo motor / repara escapamento.
  - **Expected:** Statebags limpas, veículo volta a ligar perfeitamente.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-F08:** Zero criação indevida de histórico criminal na tentativa de dirigir.
  - **Preconditions:** Cidadão civil tenta ligar carro abandonado sem motor.
  - **Steps:** Tentar partida.
  - **Expected:** Apenas bloqueio físico; NENHUM chamado policial automático ou ficha gerada.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

---

## QA-G — CANONICAL IDENTITY / PLATE / VIN

- [ ] **QA-G01:** Veículo legítimo com placa visível igual à placa real.
  - **Preconditions:** Veículo civil original com placa `ABC 1234`.
  - **Steps:** Inspecionar com scanner pericial.
  - **Expected:** `plateDisguised == false`, relatório exibe placa legítima.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-G02:** Veículo com placa clonada/disfarçada (`vp_chop_fake_plates`).
  - **Preconditions:** Veículo ostenta placa falsa `FAKE999` e possui registro original `REAL111`.
  - **Steps:** Inspecionar com scanner pericial.
  - **Expected:** `plateDisguised == true`, relatório indica adulteração de placa ostensiva.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-G03:** Resolução de placa real via `VPChopMDT.GetRealPlate`.
  - **Preconditions:** MDT integrado ativo.
  - **Steps:** Chamar resolução pericial em veículo disfarçado.
  - **Expected:** Placa canônica `REAL111` utilizada como chave para checagem de VIN e histórico.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-G04:** Indisponibilidade do resolver de MDT/Placas.
  - **Preconditions:** `VPChopMDT` indisponível temporariamente.
  - **Steps:** Inspecionar veículo.
  - **Expected:** Fallback seguro para statebag `vpFakeRealPlate` ou placa visível sanitizada.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-G05:** VIN raspado verificado contra a placa canônica.
  - **Preconditions:** Veículo com placa falsa `FAKE999` e placa real `REAL111` gravada como raspada.
  - **Steps:** Inspecionar o veículo.
  - **Expected:** Scanner identifica corretamente que o chassi original de `REAL111` está raspado.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-G06:** Entidade destruída entre início e commit da ação.
  - **Preconditions:** Desmanche ou inspeção iniciada.
  - **Steps:** Deletar o veículo via comando admin antes da barra terminar.
  - **Expected:** Commit rejeitado de forma limpa com `not_vehicle` ou `session_gone` (fail-closed).
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-G07:** Validação estrita de `netId` inteiro finito.
  - **Preconditions:** Tentativa de passar `nil`, strings ou números negativos ao endpoint.
  - **Steps:** Inspecionar veículo com payload manipulado.
  - **Expected:** Servidor rejeita imediatamente com `invalid_net`.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-G08:** Zero menção a `vpChopPlateOriginal` em produção.
  - **Preconditions:** Verificação estática e em runtime.
  - **Steps:** Varrer logs e statebags durante todas as ações.
  - **Expected:** Zero leituras ou escritas da chave depreciada.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-G09:** Fail-closed onde a identidade veicular não pode ser comprovada.
  - **Preconditions:** Veículo sem placa e sem registro de persistência.
  - **Steps:** Tentar entregar veículo no Fence (`deliverCar`) ou registrar serial.
  - **Expected:** Operação negada com segurança; zero vazamento de dinheiro.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

---

## QA-H — MULTIPLAYER / RACES

- [ ] **QA-H01:** Dois jogadores criminosos interagindo no mesmo veículo.
  - **Preconditions:** Veículo levantado no macaco hidráulico.
  - **Steps:** Jogador A desmancha roda dianteira enquanto Jogador B tenta a mesma roda.
  - **Expected:** Concorrência isolada por `LockPart`; apenas um jogador obtém a trava.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-H02:** Policial escaneia veículo enquanto criminoso remove o rastreador.
  - **Preconditions:** Criminoso no meio do minigame de corte de LoJack.
  - **Steps:** Policial executa o scan pericial simultaneamente.
  - **Expected:** Scan read-only observa `ACTIVE` sem interromper ou corromper a sessão do criminoso.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-H03:** Conclusão de remoção de LoJack durante perícia policial.
  - **Preconditions:** Policial abre o relatório pericial no exato instante em que o criminoso corta o fio.
  - **Steps:** Observar relatório e estado final.
  - **Expected:** Próxima consulta já reflete `trackerStatus == 'cut'`, zero conflitos de memória.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-H04:** Desconexão do jogador criminoso durante furto de catalisador.
  - **Preconditions:** Jogador no meio do corte duplo do escapamento.
  - **Steps:** Fechar jogo do criminoso abruptamente.
  - **Expected:** Veículo permanece no mundo, sem concessão de recompensa fantasma.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-H05:** Desconexão do policial durante leitura pericial.
  - **Preconditions:** Policial na barra de progresso do scanner.
  - **Steps:** Fechar jogo do policial.
  - **Expected:** Nenhuma trava fica retida no veículo; veículo liberado imediatamente para outros oficiais.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-H06:** Três jogadores (Criminal A, Criminal B, Policial C) no mesmo setor.
  - **Preconditions:** Local de desmanche ativo com movimentação mista.
  - **Steps:** Executar corte de porta, corte de pneu e inspeção pericial em paralelo.
  - **Expected:** Todas as ações resolvem independentemente respeitando seus respectivos mutexes.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-H07:** Veículo deletado por comando admin durante ação de 2 jogadores.
  - **Preconditions:** Dois jogadores interagindo no mesmo carro.
  - **Steps:** Admin executa `/dv` no veículo.
  - **Expected:** Ambas as ações abortam com segurança sem causar exception no servidor.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-H08:** Prevenção total de estados fantasmas (*ghost state leaks*).
  - **Preconditions:** Ciclo intenso de 50 ações simultâneas em múltiplos veículos.
  - **Steps:** Analisar contadores de memória do servidor pós-stress.
  - **Expected:** Zero sessões órfãs retidas em `_activeRemovals`, `_trackers` limpo de veículos deletados.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

---

## QA-I — CROSS-DOMAIN FAILURE ISOLATION

- [ ] **QA-I01:** `EvidenceBridge` offline + Desmanche normal operacional.
  - **Preconditions:** Configurar `Config.Evidence.Provider = 'none'`.
  - **Steps:** Executar desmanche de rodas, portas, motor e carcaça.
  - **Expected:** Todas as peças desmancham perfeitamente com suas respectivas recompensas.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-I02:** `DispatchBridge` offline + Furto de catalisador operacional.
  - **Preconditions:** Configurar `Config.Dispatch.Provider = 'none'`.
  - **Steps:** Realizar furto de catalisador com falha proposital de minigame.
  - **Expected:** Falha tratada com som e corte sem crash; zero erros no console.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-I03:** Submódulo de Rastreadores desativado + Desmanche avançado.
  - **Preconditions:** `Config.Tracker.Enable = false`.
  - **Steps:** Desmanchar veículo e vender no Broker.
  - **Expected:** Todo o fluxo do desmanche avançado e venda física funciona sem interrupções.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-I04:** Inspeção policial desativada + Perícia de inventário normal.
  - **Preconditions:** `Config.PartSerial.VehicleInspection.Enable = false`.
  - **Steps:** Inspecionar peças no inventário de jogador suspeito.
  - **Expected:** `inspectParts` continua operacional; `inspectVehicle` bloqueado com segurança.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-I05:** Todos os providers externos ausentes + Broker Market 100% ativo.
  - **Preconditions:** Ambiente sem nenhum resource externo de polícia/dispatch.
  - **Steps:** Vender peças físicas, cumprir contratos e coletar pagamentos.
  - **Expected:** Mercado dinâmico, cotações e contratos operam em capacidade total.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-I06:** Workshop `Provider = 'none'` + Camada forense P4 ativa.
  - **Preconditions:** `Config.Broker.Workshop.Provider = 'none'` e P4 ativo.
  - **Steps:** Realizar perícias policiais e desmanches no servidor.
  - **Expected:** Zero conflitos ou dependências circulares entre Workshop e Forense.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-I07:** Desmanche na Bancada (`chopshop_bench`) com peças serializadas.
  - **Preconditions:** Peça de motor carregada nos braços com serial gravado.
  - **Steps:** Processar na bancada escolhendo desmontar em sucata.
  - **Expected:** Entitlement consumido como terminal `CONSUMED`, sucatas geradas no inventário.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-I08:** Entrega de veículo intacto no Fence (`deliverCar`) com placa clonada.
  - **Preconditions:** Veículo roubado com placa adulterada.
  - **Steps:** Entregar no ponto de entrega de veículos.
  - **Expected:** Veículo entregue e persistido no ledger; cooldown aplicado sem erros.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

---

## QA-J — REGRESSION & I18N SPOT CHECK

- [ ] **QA-J01:** Idioma Português (`pt`).
  - **Preconditions:** `Config.Locale = 'pt'`.
  - **Steps:** Inspecionar veículo e abrir relatório pericial.
  - **Expected:** Todos os títulos, badges e descrições exibidos em português correto.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-J02:** Idioma Inglês (`en`).
  - **Preconditions:** `Config.Locale = 'en'`.
  - **Steps:** Inspecionar veículo e abrir relatório pericial.
  - **Expected:** 0 palavras em português; todas as mensagens em inglês idiomático.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-J03:** Idioma Espanhol (`es`).
  - **Preconditions:** `Config.Locale = 'es'`.
  - **Steps:** Inspecionar veículo e abrir relatório pericial.
  - **Expected:** 100% de paridade de chaves em espanhol.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-J04:** Idioma Francês (`fr`).
  - **Preconditions:** `Config.Locale = 'fr'`.
  - **Steps:** Inspecionar veículo e abrir relatório pericial.
  - **Expected:** 100% de paridade de chaves em francês.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-J05:** Idioma Turco (`tr`).
  - **Preconditions:** `Config.Locale = 'tr'`.
  - **Steps:** Inspecionar veículo e abrir relatório pericial.
  - **Expected:** 100% de paridade de chaves em turco.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-J06:** Regressão: Minigame de Rodas e entrega de Pneus.
  - **Preconditions:** Veículo levantado no macaco.
  - **Steps:** Desparafusar 5 parafusos da roda dianteira.
  - **Expected:** Roda removida visualmente e item de pneu / entitlement entregue.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-J07:** Regressão: Minigame de Painéis e Carcaça.
  - **Preconditions:** Veículo com serra circular e maçarico.
  - **Steps:** Cortar capô e cortar linhas estruturais da carcaça.
  - **Expected:** Minigames 3D com câmera e efeitos visuais funcionam perfeitamente.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

- [ ] **QA-J08:** Regressão: Contratos do Broker e Encomendas.
  - **Preconditions:** Menu do Intermediário.
  - **Steps:** Aceitar e cumprir contrato de alta procura.
  - **Expected:** Pagamento dinâmico efetuado, quota atualizada, Trust XP creditado.
  - **Observed:**
  - **Evidence:**
  - **Result:** PENDING

---

## QA-K — FINAL RELEASE EVIDENCE & ENVIRONMENT

### Ambiente de Teste Registrado
- **FiveM Artifact / Server Build:** PENDING
- **Framework:** QBox (commit/versão: PENDING)
- **ox_lib:** PENDING
- **ox_target:** PENDING
- **ox_inventory:** PENDING
- **oxmysql:** PENDING
- **Evidence Provider Utilizado:** PENDING
- **Dispatch Provider Utilizado:** PENDING
- **Data e Horário do Teste:** PENDING
- **Oficiais / Testadores Participantes:** PENDING

### Sumário Final de Execução
- **Total de Casos:** 92
- **PASS:** 0
- **FAIL:** 0
- **BLOCKED:** 0
- **PENDING / NOT RUN:** 92
- **Conclusão:** PENDING LIVE QA EXECUTION BY QA LEAD / OWNER
