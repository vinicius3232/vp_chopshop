# Changelog — vp_chopshop

---

## [1.6.0] — 2026-04-14 — SQL Optimization

### Fixed / Optimized
- **[Performance] server/heat.lua** — `SELECT COUNT(*)` → `SELECT EXISTS(SELECT 1 ...)` na verificação de VIN scratch. `EXISTS` para ao primeiro match; `COUNT(*)` contava todas as rows (irrelevante em PK lookup, mas é prática correta que o otimizador pode tratar diferente em certos engines).
- **[Performance] server/fence.lua** — Adicionada thread de limpeza periódica (6 h) de ordens cumpridas com mais de 7 dias em `vp_chop_fence_orders`. Sem isso a tabela crescia indefinidamente, degradando o índice `idx_orders_active` ao longo do tempo.
- **[Schema] server/db.lua + sql/vp_chopshop.sql** — `placed_by` e `identifier` em todas as 6 tabelas ampliados de `VARCHAR(50)` para `VARCHAR(60)`. Formato `license2:` tem até 49 chars; margem era de apenas 1 char. Formato futuro poderia truncar silenciosamente.

### Added
- **sql/migrate_v1.6.0.sql** — Script de migração para servidores existentes (ALTER TABLE + DELETE de ordens antigas).

---

## [1.5.0] — 2026-04-14 — Feature: Vehicle Alarm System

### Added
- **[Feature] Sistema de alarme veicular probabilístico** (`client/alarm.lua` + `server/main.lua` + `shared/config.lua`):
  - Todos os veículos podem disparar alarme ao ser desmanchados (não só os trancados).
  - Probabilidade proporcional à classe do veículo GTA: Compacts 15% → Super 80%, Military 75%, OpenWheel 70%, Emergency 65%.
  - Para desarmar: requer **chave de fenda** (`Config.Alarm.DisarmItem`) + `lib.skillCheck` (`easy` + `medium`).
  - Falha no skillCheck mantém alarme ativo — jogador pode tentar novamente dentro da janela.
  - Janela configurável (padrão 30 s) para o jogador desarmar via ox_target no veículo.
  - Se não desarmado: servidor notifica o cliente → dispatch ativado (ps-dispatch / cd_dispatch / qs-dispatch).
  - Estado rastreado 100% server-side (`AlarmActive[netId]`); validação de item também server-side — sem trust-client.
  - Alarme limpo automaticamente ao desconectar ou ao descartar o veículo.
- **`Config.Alarm`** substitui `Config.AlarmOnChop` (bool simples → tabela completa com `ChanceByClass`, `DefaultChance`, `DisarmWindowSeconds`, `DisarmDistance`, `DisarmItem`, `DisarmSkillCheck`).
- Chaves de locale `alarm_title`, `alarm_triggered`, `alarm_disarm_label`, `alarm_disarmed`, `alarm_expired`, `alarm_no_item`, `alarm_skill_fail` adicionadas em todos os 5 locales (en/pt/es/fr/tr).

---

## [1.4.0] — 2026-04-14 — Audit Auto-Fix (Missing Handlers & Bridge API)

### Fixed (Critical)
- **[Logic] server/fence.lua** — Handler `vp_chopshop:tyres:jackstandTyreStolen` inexistente: server/tyres.lua (tombstone) indicava "migrado para server/main.lua", mas o handler nunca foi criado. Após cada pneu roubado com macaco, o jogador nunca recebia `Config.Jackstand.TyreItem` ('chopshop_tyre'). Adicionado handler com rate-limit (5 s), validação de source, e AddItem correto.
- **[Logic] client/fence.lua** — `TyreMissionStart()` chamada em `onSelect` do fence target "Contrato de pneus" mas função não existia em lugar nenhum do codebase (não foi migrada de client/npc.lua). Causava erro Lua silencioso (call nil). Adicionado stub com guard de `Config.TyreMission.Enable`; implementação completa de missão marcada como TODO.

### Fixed (High)
- **[Logic] client/fence.lua:556** — `VPChopLoadTyreInTruck` usava variável `truckNetId` (nil, não definida no scope) em vez de `NetworkGetNetworkIdFromEntity(truck)`. Server recebia nil, guard `if not netId then return end` descartava silenciosamente. Resultado: pneus carregados via prop no chão → ox_target nunca registavam no `ServerTyreCounts` → venda tipo 'truck' retornava 0. `VPChopLoadTyreInTruckFromCarry` (linha 591) já estava correto; corrigido o path do prop.
- **[Logic] bridge/server_framework.lua** — `BridgeGetCash`, `BridgeRemoveCash` e `BridgeAddCash` (QBX) usavam `Player.Functions.GetMoney/RemoveMoney/AddMoney` (shim deprecado). Substituído por `exports.qbx_core:GetMoney/RemoveMoney/AddMoney` com assinatura canônica.
- **[Logic] bridge/server_framework.lua** — `BridgeGetIdentifier`, `BridgeGetCash` e `BridgeRemoveCash` (ESX) usavam `ESX.GetPlayerFromId(src)` (deprecado). Substituído por `ESX.Player(src)` (modern API) em 3 locais.
- **[Performance] server/advanced_chop.lua:137** — `TriggerClientEvent('vp_chopshop:adv:breakDoor', -1, ...)` fazia broadcast para todos os clientes conectados. Substituído por loop de proximidade (raio 150 u), mesmo padrão do fix L3 de v1.3.9 para breakPart.

### Fixed (Medium)
- **[Logic] server/cooldown.lua** — `AddEventHandler('playerDropped')` usava `source` diretamente sem snapshot `local src = source`. Corrigido.
- **[Structure] server/main.lua** — Comando `choplifts` renomeado para `chopbenches` (lifts removidos; nome enganoso para admins).
- **[Structure] server/validate.lua** — `ValidateVehicleNearLift()` era código morto (lift removido, função nunca chamada). Removida.

### Fixed (Low)
- **[Structure] fxmanifest.lua** — `lua54 'yes'` removido; Lua 5.4 é o padrão desde junho/2025. Versão atualizada para 1.4.0.
- **[Structure] shared/config.lua** — Removidas ~10 chaves órfãs do sistema de elevador: `Config.LiftBaseModel`, `Config.Items.placeLift`, `Config.UseFuel`, `Config.FuelMax`, `Config.FuelPerPartMin/Max`, `Config.FuelRefillPerItem`, `Config.LiftAnimation`, `Config.MinLiftSpacing`, `Config.Partner`. `Config.VehicleNearLiftRadius` mantida (ainda usada em `ValidatePlayerNearCoords`).
- **[Structure] fxmanifest.lua** — `client/tyres.lua` e `client/npc.lua` removidos do manifest (tombstones vazios; carregamento desnecessário a cada restart).
- **[Structure] client/progression.lua + shared/locale.lua** — `heatWarning` usava strings PT-BR hardcoded em vez de `L()`. Chaves `heat_warn_morno/quente/queimando` adicionadas em todos os 5 locales (en/pt/es/fr/tr); cliente agora usa `L('heat_warn_' .. level)`.

---

## [1.3.9] — 2026-04-13 — Audit Auto-Fix (Tool Durability & Performance)

### Fixed (High)
- **[Logic] server/main.lua** — `VPChopConsumeTool` usava `exports.ox_inventory:GetInventoryItems(src)`, export removido no ox_inventory v2+. Função retornava `false` silenciosamente: no basic chop (retorno ignorado) ferramentas nunca degradavam; no advanced chop (retorno verificado) o sistema inteiro era recusado mesmo com ferramenta presente. Substituído por iteração sobre `Config.Tools` com `GetItem(src, toolName, nil, false)` — export documentado — e `RemoveItem` com metadata do slot correspondente.

### Fixed (Medium)
- **[Performance] server/fence.lua** — `deliverCar` chamava `VPChopHeatGetLabel(plate)` e em seguida `VPChopHeatGetPriceMult(plate)`, cada uma disparando `VPChopHeatCalc` → `MySQL.scalar.await` para VIN scratch. Eliminada segunda query: label calculado uma vez, `heatMult` mapeado localmente via tabela `{ frio=1.0, morno=0.90, quente=0.75, queimando=0.0 }`.
- **[Performance] server/progression.lua** — `VPChopAddXp` persistia XP com `MySQL.query.await` dentro de `AddEventHandler(PART_CHOPPED)`, bloqueando a coroutine do callback chamador até conclusão do SQL. Persistência movida para `CreateThread` não-bloqueante; snapshot local (`snap`) garante consistência mesmo após playerDropped.
- **[Structure] fxmanifest.lua** — Removidos 2 tombstones do fxmanifest: `server/npc.lua` e `server/tyres.lua` (arquivos esvaziados desde migração para fence.lua); carregamento desnecessário eliminado.

### Fixed (Low)
- **[L1] [Structure] sql/vp_chopshop.sql** — comment de versão atualizado de `v1.3.5` para `v1.3.9`.
- **[L2] [Logic] server/discord.lua** — `VPChopDiscordLogPlace` não verificava `Config.Discord.LogPlaceWelder`; soldadoras eram sempre logadas mesmo com Discord desativado para welders. Adicionado guard simétrico ao de bench.
- **[L3] [Performance] server/main.lua** — `TriggerClientEvent('vp_chopshop:client:breakPart', -1, ...)` substituído por loop de proximidade (raio 150 u). Clientes além do raio de streaming do veículo não recebem mais o evento; fallback sem filtragem se coords do veículo não estiverem disponíveis.

---

## [1.3.8] — 2026-04-13 — Security & Performance Audit

### Fixed (High)
- **[Security] server/fence.lua + client/fence.lua** — Tyre count para venda no truck era lido do state bag controlado pelo cliente (`chopTyreCount`), permitindo que um cliente modificado definisse o valor para `MaxTyresInTruck` sem carregar nenhum pneu e recebesse o pagamento integral. Corrigido com rastreio server-side (`ServerTyreCounts[netId]`) via evento `vp_chopshop:tyre:truckLoad` com validação de proximidade e rate limit (3s). Servidor ignora state bag no pagamento; state bag mantido no cliente com `replicate=false` apenas para feedback de UI local.

### Fixed (Medium)
- **[Performance] client/fence.lua** — `GetGamePool('CVehicle')` chamado por frame dentro de `canInteract` de cada prop de pneu. Substituído por função `isTruckNearby()` com cache compartilhado de 500ms entre todos os props.
- **[Performance] server/fence.lua** — `rotateFence()` chamava `VPChopFenceGetTrust(pid)` para todos os jogadores online, potencialmente disparando `MySQL.single.await` por jogador não cacheado. Substituído por leitura direta do `TrustCache[pid]`; jogadores sem cache não recebem notificação (irrelevante: trust == 0 não exibe blip).
- **[Structure] client/minigames.lua + client/bolt_minigame.lua** — Arquivos órfãos removidos. Funções `VPChopRunBoltMinigame`, `VPChopBoltMinigame` e `VPChopBoltMinigameFallback` já estavam implementadas em `client/main.lua`; arquivos externos nunca foram carregados (ausentes do fxmanifest).

### Fixed (Low)
- **[Structure] client/fence.lua + shared/locale.lua** — Strings hardcoded em português substituídas por chamadas `L()`. Adicionadas 16 chaves nos blocos `en` e `pt` do locale: `fence_rotated_to_fmt`, `fence_rotated_unknown`, `fence_trust_level_{1-4}`, `fence_trust_up_title_fmt`, `fence_trust_up_desc`, `fence_nothing_to_sell`, `fence_already_carrying_tyre`, `fence_tyre_carrying_hint`, `fence_tyre_loaded_fmt`, `fence_no_pickup_nearby`, `fence_truck_full`.
- **[Low] server/main.lua** — `print()` no comando admin `/choptest` envolvidos com guarda `Config.Debug`; silencioso em produção.

---

## [1.3.7] — 2026-04-12 — Tyre UX Overhaul & Target Fixes

### Fixed (High)
- **[Logic] client/main.lua** — `doJackstandTyreSteal`: chamada `VTyreSpawnWheelPropInHand` corrigida para `VPTyreSpawnWheelPropInHand`; eliminava crash nil-call ao tentar roubar pneu

### Changed
- **[UX] client/main.lua** — remoção de pneu migrada de loop de proximidade com tecla E (`startTyreProximityThread`) para **ox_target com `bones`** por roda (`wheel_lf`, `wheel_rf`, `wheel_lr`, `wheel_rr`); opção aparece ao mirar diretamente na roda, sem polling de distância
- **[UX] client/main.lua** — pneu carregado na mão: substituída lógica de `addLocalEntity(PlayerPedId, ...)` (impossível de interagir) por `RegisterKeyMapping` + `RegisterCommand` (`+vp_tyre_options`, tecla **G** padrão) que exibe context menu `ox_lib` com opções "Colocar no chão" e "Colocar no truck" (quando pickup está a ≤ 5 m)
- **[UX] client/main.lua** — `placeTyreHandPropOnGround()`: reutiliza o prop da mão em vez de criar novo; `DetachEntity` + `GetGroundZFor_3dCoord` + `SetEntityCoordsNoOffset` + `FreezeEntityPosition`; prop de chão recebe ox_target "Guardar no truck"
- **[UX] client/main.lua** — carry TextUI exibido via thread `Wait(200)` enquanto `VPChopCarryingPart.isTyre` for verdadeiro; `lib.hideTextUI()` garantido ao largar

### Fixed (Medium)
- **[Logic] client/main.lua** — `addRaisedCarTargets`: bones de porta verificados com `GetEntityBoneIndexByName ~= -1` antes de criar target; evita zona presa na origem em veículos de 2 portas
- **[Logic] client/main.lua** — `addRaisedCarTargets`: target de motor com bone `engine` → `bonnet`; `engine` é unreliable em GTA V, `bonnet` é o anchor correto do capô/motor
- **[Logic] client/main.lua** — `addRaisedCarTargets`: `not JackstandBusy` adicionado ao `canInteract` de todos os targets de AdvancedChop; impede múltiplas fases simultâneas

### Added
- **[Feature] client/fence.lua** — `VPChopFindNearestTruck(radius)` global: varre `GetGamePool('CVehicle')`, compara modelos com `getTruckHashes()`, retorna handle da pickup mais próxima dentro do raio; compartilhado entre `main.lua` e `fence.lua`

### Changed
- **[Logic] client/lifts.lua** — `VPChopDropCarryPart`: ao largar pneu carregado (`wasTyre`), chama `ClearPedTasksImmediately` e `lib.hideTextUI()` para encerrar animação carry e UI corretamente

---

## [1.3.6] — 2026-04-11 — SQL Consolidation & Schema Optimization

### Changed
- **[Structure] sql/** — `vp_chopshop_rp.sql` removido; todas as 6 tabelas agora em `sql/vp_chopshop.sql`; `vp_chopshop_lifts` (depreciada) removida; `vp_chopshop_welders` (que existia apenas no runtime de `db.lua`) adicionada ao arquivo de install
- **[Structure] server/db.lua** — DDL inline de todas as tabelas sincronizado com o arquivo SQL consolidado:
  - `int(11)` → `INT UNSIGNED NOT NULL` nos PKs auto-increment
  - `longtext` → `TEXT` em campos `position` e `order_data` (max 65 KB — mais que suficiente)
  - `int(11) heading` → `SMALLINT UNSIGNED NOT NULL DEFAULT 0` (0-359 cabe em 2 bytes)
  - `TINYINT` → `TINYINT UNSIGNED` em `trust_level` e `tier` (valores 0-4 e 1-4)
  - `INT` → `MEDIUMINT UNSIGNED` em `trust_xp`, `xp`, `total_chops` (0-~50 000 realistas, 3 bytes)
  - `INDEX idx_identifier (for_identifier)` → `INDEX idx_orders_active (for_identifier, fulfilled_at, created_at)` — índice composto cobre os dois padrões de acesso: listar pedidos ativos e marcar como cumprido

---

## [1.3.5] — 2026-04-11 — Code Review Fixes

### Fixed (Critical)
- **[Logic] server/fence.lua** — `sellItems`: `realTotal` acumulado apenas dos itens efetivamente removidos; paga `realTotal` em vez de `totalValue` do dry-run, eliminando overpay quando algum `RemoveItem` falha entre as duas fases
- **[Security/Logic] server/fence.lua** — `fulfillOrder`: `UPDATE ... WHERE fulfilled_at IS NULL` atômico executado **antes** do `BridgeAddCash`; `affectedRows=0` aciona rollback de itens; elimina double-pay via race condition de chamadas simultâneas
- **[Security] server/fence.lua** — `sellTyres`: `chopTyreCount` lido do state bag (escrito pelo cliente) limitado ao máximo configurado (`MaxTyresInTruck`); previne cliente modificado recebendo payout de 9999 pneus

### Fixed (High)
- **[Security] server/fence.lua** — `sellTyres`: `source_type` validado como `'truck'` ou `'inventory'` antes de processar; rejeita valores inválidos com `err='invalid_type'`
- **[Logic] server/fence.lua** — `getOrder`: `MySQL.insert.await` envolvido em `pcall`; `OrderGenBusy[key]` agora limpo mesmo em erro de DB (mutex não fica permanentemente travado)
- **[Logic] server/advanced_chop.lua** — `InvAdd` verificado em todas as 3 fases (2/3/4); inventário cheio agora notifica o jogador via `ox_lib:notify` em vez de silenciosamente perder o item
- **[Logic] client/main.lua** — `VPChopJackstandStealTyre`: reset antecipado de `JackstandBusy = false` removido da linha pós-progressBar; mutex agora mantido durante todas as operações assíncronas (`VPChopSpawnTyreProp`, `VPTyreSpawnWheelPropInHand`)
- **[Logic] server/fence.lua** — `rotateFence`: despawn síncrono direto (sem evento separado) antes de spawnar; elimina race condition onde spawn completava antes do despawn, criando NPCs orphan acumulativos

### Fixed (Medium)
- **[Logic] client/fence.lua** — `VPChopLoadTyreInTruck`: substituído `joaat(m)` por iteração para usar `getTruckHashes()` (cache pré-calculado); consistente com `canInteract` e o loop de carry
- **[Logic] server/fence.lua** — `deliverCar`: cooldown agora comparado inteiramente via `TIMESTAMPDIFF` no MySQL; elimina dependência do relógio do FiveM vs MySQL (`os.time()` vs `UNIX_TIMESTAMP`)
- **[Logic] server/fence.lua** — `deliverCar`: mutex `DeliveryBusy[key]` adicionado; previne dois callbacks simultâneos passarem pelo cooldown check antes de qualquer um escrever no DB
- **[Logic] client/placement.lua** — controle 73 (X) no ghost placement agora verificado somente se `not VPChopCarryingPart`; elimina conflito quando ambas as loops estão ativas
- **[Performance] client/fence.lua** — `Wait(10)` → `Wait(100)` nos dois loops de polling de model load (`VPChopSpawnTyreProp` e `VPChopPickUpTyre`); alinhado com o padrão em `main.lua`

### Fixed (Low)
- **[Structure] server/fence.lua + heat.lua + progression.lua + advanced_chop.lua** — `source` localizado como `local src = source` em todos os handlers `playerDropped`; padrão consistente com o restante do codebase; `DeliveryBusy` também limpo no disconnect
- **[Structure] client/fence.lua** — labels de ox_target do NPC fence migrados de strings PT-BR hardcoded para `L('fence_target_*')`; novos keys adicionados a `shared/locale.lua` em `en` e `pt`
- **[Logic] server/fence.lua** — `saveTrust` chamado via `pcall` em `addTrustXp`; falha de DB ao salvar XP não aborta o payout já realizado ao jogador
- **[Structure] client/main.lua** — `local AdvChopState = {}` movido para o topo do arquivo (antes do handler `onResourceStop`); corrige forward-reference implícita que acessava `_G.AdvChopState` em vez da local

---

## [1.3.4] — 2026-04-11 — Audit Medium/Low Fixes

### Fixed (Medium)
- **[Logic] server/fence.lua** — `sellItems`: refatorado com dry-run via `GetItemCount` antes de remover qualquer item; `totalValue > 0` verificado antes de qualquer mutação de inventário; rollback implícito (nenhum item removido se nada for vendável)
- **[Logic] server/fence.lua** — `getOrder`: mutex `OrderGenBusy` por chave de jogador adicionado; previne criação de dois pedidos simultâneos via duplo-click

### Fixed (Low)
- **[Structure] client/jackstand.lua** — Arquivo stub sem propósito deletado; comentário de aviso estava embutido no próprio arquivo (não carregado pelo fxmanifest)
- **[Structure] bridge/server_framework.lua** — `BridgeRemoveCash`/`BridgeAddCash`: parâmetro `reason` adicionado às assinaturas; call sites que passam `'fence_sale'`, `'fence_car'`, `'npc_buy_bench'` etc. agora propagam o label corretamente ao framework

---

## [1.3.3] — 2026-04-11 — Audit Auto-Fix

### Fixed (High)
- **[Security/Logic] server/main.lua** — `vp_chopshop:getWorld` callback adicionado parâmetro `source` + guard `GetPlayerName`; loop de espera bloqueante não mais executável sem jogador válido (vetor DoS eliminado)
- **[Logic] server/advanced_chop.lua** — `chopEngine` (Fase 3) agora consome a chave de fenda via `InvRemove` após obter o mutex, eliminando uso gratuito ilimitado com uma única chave
- **[Logic/Structure] server/fence.lua** — `fence:buyBench`: item agora referenciado via `Config.Items.placeBench` (não mais hardcoded `'chopshop_bench'`); guard `price < 1` adicionado para prevenir bancada gratuita com `BenchPrice = 0`

### Fixed (Critical — sessão anterior)
- **[Security] server/main.lua** — `maybeAmbush` e `npcAcceptMission` callbacks: guards `GetPlayerName` adicionados
- **[Logic] server/main.lua** — `benchCraft`: mutex `BenchCraftBusy` adicionado para prevenir TOCTOU double-craft
- **[Logic] server/fence.lua** — `sellTyres`: retorno de `RemoveItem` agora verificado (sem payout em falha de remoção)
- **[Logic] server/fence.lua** — `deliverCar`: cooldown persistido no DB (com `pcall`) antes de deletar veículo e pagar; elimina spam via falha de DB
- **[Security] server/heat.lua** — `vinScratch`: cooldown de 3s por jogador adicionado; previne XP farming via spam de callback
- **[Performance] client/main.lua** — Handlers `syncWorld`, `addBench`, `addWelder` envolvidos em `CreateThread`; previne crash "attempt to yield from outside a coroutine"
- **[Performance] client/main.lua** — Loops de lift/lower reduzidos de `Wait(5)` → `Wait(16)` (200 Hz → 60 Hz); incrementos Z reescalados para manter duração de animação
- **[Performance] client/fence.lua** — Loop de carry de pneu reduzido de `Wait(0)` → `Wait(50)` (60+ Hz → 20 Hz)
- **[Performance] client/fence.lua** — Hashes de modelo de truck (`joaat`) cacheados via `getTruckHashes()` — eliminado recálculo por frame em `canInteract` e no loop de carry
- **[Performance] client/placement.lua** — Loop de ghost placement reduzido de `Wait(0)` → `Wait(16)` (equivalente a 60 fps)

---

## [1.3.2] — 2026-04-11 — Heavy RP Gameplay

### Added
- **Heat system** (`server/heat.lua`) — pontuação de risco por veículo (0-100), VIN scratching, multiplicador de emboscada baseado em heat
- **Fence NPC** (`server/fence.lua`, `client/fence.lua`) — contato criminal rotativo (45 min), economia de trust (0-4 níveis), 8 callbacks, entrega de pneus/ordens/carro inteiro
- **Progression** (`server/progression.lua`, `client/progression.lua`) — sistema XP de 4 tiers persistido em `vp_chop_progression`
- **Tyre prop system** — pneus roubados via jackstand aparecem no chão como props carregáveis/entregáveis via caminhonete
- **Referral drop** — NPCs de emboscada têm 15% de chance de dropar `fence_referral` ao morrer
- **Novos itens** — `fence_referral` e `vin_kit` registrados em `ox_inventory`

### Changed
- `server/ambush.lua` — `VPChopHeatGetMultiplier` integrado; thread de drop de referral adicionada
- `client/main.lua` — spawn de prop de pneu após roubo via jackstand; `VPChopJackstandStealTyre` envolvido em `CreateThread` com mutex correto
- `fxmanifest.lua` — novos arquivos adicionados; `server/heat.lua` posicionado antes de `server/ambush.lua` (load order fix)

### Removed (Tombstoned)
- `server/npc.lua`, `client/npc.lua` — lógica migrada para `server/fence.lua` / `client/fence.lua`
- `server/tyres.lua`, `client/tyres.lua` — lógica migrada para `server/main.lua` / `client/fence.lua`
