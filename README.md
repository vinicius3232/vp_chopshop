# vp_chopshop

## Security & Compatibility

### Audit — 2026-04-14 (v1.6.1)
- Audited by fivem-audit skill (Claude Code)
- 0 critical, 1 high, 4 medium, 4 low issues resolved
- High: `ESX.GetPlayerFromId` (deprecated) → `ESX.Player` in `ServerPlayerIsReady`
- Medium: ~22 hardcoded PT-BR strings in `client/fence.lua` replaced by `L()` calls; 40 new locale keys added (EN + PT, ES/FR/TR inherit via fallback); dead function `VPChopStartLiftPlacement` removed; tier-up labels moved to locale system
- Low: `Config.Discord.LogPlaceLift` orphan removed; `LogPlaceWelder` key added; `BridgeAddCash` reason parameter added; `source` localized in `playerDropped`
- Framework: QBX/QBCore/ESX compatible (bridge layer)
- All 5 locales (en/pt/es/fr/tr) now fully supported in fence UI

### v1.6.0 — 2026-04-14 — SQL Optimization
- `SELECT COUNT(*)` → `SELECT EXISTS(SELECT 1 …)` na verificação de VIN scratch
- Thread de limpeza periódica (6 h) de ordens fence cumpridas há mais de 7 dias
- `placed_by` / `identifier` em todas as 6 tabelas: `VARCHAR(50)` → `VARCHAR(60)`

### v1.5.0 — 2026-04-14
- Feature: **Sistema de Alarme Veicular** — probabilidade por classe, janela de desarme, dispatch automático
- Requer chave de fenda + `lib.skillCheck` para desarmar; estado rastreado 100% server-side

### Audit — 2026-04-14 (v1.4.0)
- Audited by fivem-audit skill (Claude Code)
- 2 critical, 4 high, 3 medium, 4 low issues resolved
- Critical: missing server handler for `jackstandTyreStolen`; `TyreMissionStart` nil-call crash
- High: `truckNetId` nil in tyre truck-load path; deprecated QBX/ESX bridge APIs; `breakDoor` global broadcast
- Framework: QBX/QBCore/ESX compatible (bridge layer)
- Lua 5.4 default (lua54 directive removed — deprecated June 2025)
- All SQL queries use parameterized `?` placeholders

### Audit — 2026-04-13 (v1.3.9)
- Audited by fivem-audit skill (Claude Code)
- 0 critical, 1 high issue resolved (tool durability, XP persistence, broadcast filter)
- Framework: QBX/QBCore/ESX compatible (bridge layer)

---

Sistema de **desmanche** (chop shop) para FiveM: o jogador usa um **macaco hidráulico** (`chopshop_jackstand`) para levantar qualquer veículo e desmontar peças em 4 fases progressivas, com recompensas em materiais, venda de pneus a NPC e emboscadas opcionais. Pensado para stacks com **ox_lib**, **ox_target**, **ox_inventory** e **oxmysql**.

---

## Requisitos obrigatórios

| Recurso | Uso |
|---------|-----|
| `ox_lib` | Menus, progress bars, skillcheck, callbacks |
| `ox_target` | Interação no veículo levantado, bancada, soldadora e NPC |
| `ox_inventory` | Itens, add/remove de materiais |
| `oxmysql` | Persistência de bancadas e soldadoras |

Ordem sugerida no `server.cfg`: dependências ox primeiro, depois `ensure vp_chopshop`.

---

## Idiomas (UI)

Em `shared/config.lua`, define **`Config.Locale`** com um destes valores:

| Valor | Idioma |
|-------|--------|
| `en` | English |
| `pt` | Português (predefinido) |
| `es` | Español |
| `fr` | Français |
| `tr` | Türkçe |

As cadeias estão em `shared/locale.lua`. Receitas personalizadas: usa `labelKey` (chave existente em `locale.lua`) ou o campo legado `label` (texto fixo, sem tradução automática).

Os **rótulos dos itens** no `ox_inventory` (`installation/ox_items_snippet.txt`) são independentes — traduz manualmente no `items.lua` se necessário.

---

## Como funciona (jogador)

### 1. Macaco hidráulico — ferramenta principal

- Usa o item **Macaco** (`chopshop_jackstand`) perto de qualquer veículo.
- A barra de progresso "A colocar macacos..." levanta o carro (~8 s).
- Com o carro levantado, aparecem os **targets de desmanche** via `ox_target`.
- **Abaixar o carro**: target "Remover macacos" no veículo.

### 2. Fases de desmanche (todas requerem macaco)

| Fase | Peças | Ferramenta extra | Recompensa |
|------|-------|-----------------|------------|
| **1 — Básico** | Capô, porta-malas, rodas, portas | — | Materiais via `Config.CarPartRewards` |
| **2 — Estrutural** | Portas / capô / porta-malas | Serra (`metal_saw`) | `car_parts` por peça |
| **3 — Motor** | Motor | Chave de fenda (`screwdriver`) | 5× `car_parts` |
| **4 — Carcaça** | Carcaça | Soldadora perto do veículo | Materiais recicláveis (chance) |

> **Fase 3** requer o capô removido na Fase 2.
> **Fase 4** requer o motor removido na Fase 3 e uma soldadora colocada no raio `Config.AdvancedChop.WelderRadius`.

### 3. Alarme veicular

Ao desmontar a **primeira peça** de um veículo, o servidor rola uma chance de disparar o alarme proporcional à classe do carro (Super 80%, Military 75%, Compacts 15%…).

**Se o alarme disparar:**
- Som e luzes de alarme ativados no veículo
- Notificação `error`: *"O alarme disparou! Desative-o antes da polícia chegar."*
- Target `🪛 Desativar alarme` aparece no veículo

**Para desarmar** (janela de 30 s configurável):
1. Precisa de **chave de fenda** (`screwdriver`) no inventário
2. Passa um `lib.skillCheck` (fácil + médio)
3. Se falhar, pode tentar novamente até o tempo expirar

**Se o tempo expirar sem desarme:** dispatch automático para a polícia com a localização do veículo.

> Configurável via `Config.Alarm` — veja a seção de Configuração abaixo.

### 4. Descarte de veículo

Após remover `Config.Discard.MinPartsToDiscard` peças, o target **Descartar veículo** aparece. O jogador recebe cash (`DefaultPayout`). Com `CopsBonus.Enable`, o valor é multiplicado quando há polícias suficientes online.

### 4. Bancada (`chopshop_bench`)

- Usa o item **Bancada** para colocar a estação de crafting.
- Receitas configuradas em `Config.BenchRecipes` (inputs/outputs/duração).
- Soldadora obrigatória perto da bancada para Fase 4.

### 5. Pneus — venda e missões

- **Venda direta**: remove pneus com o macaco → carrega numa pickup truck → vai ao NPC comprador → recebe cash (`Config.TyreSelling.PricePerTyre`).
- **Missões de contrato** (`Config.TyreMission`): NPC dá contrato → veículo alvo spawna → rouba 4 pneus com minigame de parafusos → entrega ao comprador → recebe bónus.

---

## Instalação

1. **Base de dados**
   Executa `sql/vp_chopshop.sql` (cria todas as 6 tabelas: `vp_chopshop_benches`, `vp_chopshop_welders`, `vp_chop_vin_scratched`, `vp_chop_fence_trust`, `vp_chop_fence_orders`, `vp_chop_progression`).

2. **Itens (ox_inventory)**
   Copia os blocos de `installation/ox_items_snippet.txt` para `ox_inventory/data/items.lua`. Itens necessários:

   | Item | Uso |
   |------|-----|
   | `chopshop_jackstand` | Macaco — ferramenta principal |
   | `chopshop_bench` | Bancada de crafting |
   | `chopshop_welder` | Soldadora (Fase 4) |
   | `metal_saw` | Serra (Fase 2) |
   | `screwdriver` | Chave de fenda (Fase 3) |
   | `chopshop_tyre` | Pneu roubado |

3. **Servidor**
   Adiciona `ensure vp_chopshop` após `ox_lib`, `ox_inventory`, `ox_target`, `oxmysql`.

4. **Permissões (ACE)**
   Para comandos admin (`/choplifts`, `/chopremove`), adiciona:
   ```
   add_ace group.admin command.choplifts allow
   add_ace group.admin command.chopremove allow
   ```

5. **Framework (opcional)**
   Não é obrigatório ter QBCore/QBox/ESX. Sem nenhum, `ServerPlayerIsReady` retorna `true` para todos. O bridge em `bridge/server_framework.lua` usa o framework apenas para `ServerPlayerIsReady` e para dinheiro na loja do NPC.

---

## Configuração (`shared/config.lua`)

### Distâncias e modelos
| Chave | Descrição |
|-------|-----------|
| `Config.InteractDistance` | Distância máxima para interagir (ox_target) |
| `Config.MaxPlaceDistance` | Distância máxima para colocar bancada/soldadora |
| `Config.VehicleNearLiftRadius` | Raio de validação jogador↔veículo (server-side) |
| `Config.MinBenchSpacing` | Distância mínima entre bancadas |
| `Config.BenchModel` | Prop da bancada (`prop_tool_bench02`) |

### Desmanche

| Chave | Descrição |
|-------|-----------|
| `Config.RequireVehicleKeys` | Exige chaves do veículo (`qbx_vehiclekeys` / `qb-vehiclekeys`) |
| `Config.ChopCooldownSeconds` | Espera após cada peça desmontada (`0` = desligado) |
| `Config.ChopSkillCheck` | Skillcheck opcional antes da barra de progresso |
| `Config.ChopProgressMs` | Duração da barra de desmanche (ms) |
| `Config.Tools` | Configura ferramentas individuais, sua velocidade, durabilidade e propensão a avisar a polícia (`dispatchChance`) |
| `Config.Alarm` | Sistema de alarme veicular — veja tabela abaixo |
| `Config.Dispatch` | Integração automática para notificar DP via `ps-dispatch`, `cd-dispatch`, ou `qs-dispatch` |
| `Config.CarPartRewards` | Materiais por peça na Fase 1 |
| `Config.PartProps` | Props visuais carregados ao remover peça |

### Macaco hidráulico (`Config.Jackstand`)

| Chave | Descrição |
|-------|-----------|
| `Item` | Item que aciona o macaco (`chopshop_jackstand`) |
| `TyreItem` | Item gerado ao roubar pneu (`chopshop_tyre`) |
| `PropModel` | Prop GTA V do macaco (`imp_prop_axel_stand_01a`) |
| `LiftHeight` | Altura de subida do veículo (unidades GTA) |
| `LiftProgressMs` | Duração "A colocar macacos..." |
| `LowerProgressMs` | Duração "A retirar macacos..." |
| `MaxCarDistance` | Raio máximo para acionar o macaco |
| `Minigame` | Minigame de remoção de pneu (`skill_circle` / `button_mash`) |

### Desmanche avançado (`Config.AdvancedChop`)

| Chave | Descrição |
|-------|-----------|
| `SawItem` | Serra para Fase 2 |
| `ScrewdriverItem` | Chave de fenda para Fase 3 |
| `WelderRadius` | Raio de deteção da soldadora para Fase 4 |
| `DoorReward` | Recompensa por peça na Fase 2 |
| `EngineReward` | Recompensa pelo motor na Fase 3 |
| `CarcassRewards` | Recompensas com chance na Fase 4 |

### Alarme veicular (`Config.Alarm`)

| Chave | Descrição |
|-------|-----------|
| `Enable` | Liga/desliga o sistema (`true` por padrão) |
| `ChanceByClass` | Tabela `[classId] = chance` (0.0–1.0) por classe GTA. Classes omitidas usam `DefaultChance` |
| `DefaultChance` | Probabilidade padrão para classes não mapeadas (`0.25`) |
| `DisarmWindowSeconds` | Segundos para desarmar antes do dispatch (`30`) |
| `DisarmDistance` | Distância máxima do target de desarme em metros (`6.0`) |
| `DisarmItem` | Item necessário para iniciar o minigame (`'screwdriver'`) |
| `DisarmSkillCheck` | `{ difficulties, keys }` para `lib.skillCheck`; `false` = sem minigame |

**Probabilidades padrão por classe:**

| Classe GTA | Exemplos | Chance |
|------------|----------|--------|
| Super (7) | Zentorno, T20 | 80% |
| Military (19) | Insurgent, Rhino | 75% |
| OpenWheel (22) | BR8, Formula | 70% |
| Emergency (18) | Police, Ambulance | 65% |
| Sports (6) | Elegy, Rapid GT | 55% |
| Sports Classics (5) | Coquette, Monroe | 50% |
| Muscle (4) | Gauntlet, Vigero | 40% |
| SUVs (2) / Coupes (3) | Granger, Buffalo | 35% |
| Off-Road (9) | Sandking, Kamacho | 30% |
| Sedans (1) | Stanier, Emperor | 20% |
| Compacts (0) / Vans (12) | Issi, Rumpo | 15–20% |
| Motos (8) | PCJ, Bati | 10% |
| Outros | — | 25% (padrão) |

### Descarte (`Config.Discard`)
| Chave | Descrição |
|-------|-----------|
| `Enable` | Liga/desliga descarte |
| `MinPartsToDiscard` | Mínimo de peças removidas para descartar |
| `DefaultPayout` | Cash base ao descartar |
| `CopsBonus` | Multiplica payout quando há polícias online |
| `PayoutByModel` | Payout específico por modelo de veículo |

### NPC (`Config.NPC`) e Fence (`Config.Fence`)

NPC fixo opcional. Targets disponíveis: **Como funciona**, **loja** (apenas bancada e soldadora), **Trabalho quente** (missão com emboscada).

| Chave | Descrição |
|-------|-----------|
| `NPC.Enable` | Liga/desliga o NPC |
| `NPC.Model` | Modelo do ped |
| `NPC.Coords` | `vector4` posição + heading |
| `NPC.Scenario` | Animação idle (ex.: `WORLD_HUMAN_CLIPBOARD`) |
| `NPC.Shop.Enable` | Liga loja de itens por dinheiro |
| `NPC.Shop.BenchPrice` | Preço da bancada |
| `NPC.Mission.Enable` | Liga missões de emboscada via NPC |
| `NPC.Mission.CooldownSeconds` | Cooldown entre pedidos de missão |
| `NPC.Mission.AmbushChance` | Probabilidade 0..1 de emboscada ocorrer |
| `Fence.NightBonus` | Adiciona um bônus de pagamento se a venda for efetuada num horário noturno de jogo |

### Emboscadas (`Config.Ambush`)

| Chave | Descrição |
|-------|-----------|
| `Enable` | Liga/desliga spawns de hostis |
| `RandomOnDismantle` | Chance aleatória a cada desmanche |
| `Chance` | Probabilidade (0..1) quando aleatório |
| `KindWeights` | Pesos por tipo: `pistol`, `dog`, `bat` |
| `CooldownSeconds` | Mínimo de segundos entre emboscadas por jogador |
| `DespawnMs` | Timeout para desaparecer os peds |

### Discord (`Config.Discord`)

Webhook opcional para log de eventos:

| Chave | Descrição |
|-------|-----------|
| `Webhook` | URL do webhook (vazio = desligado) |
| `LogChopPart` | Log de cada peça desmontada |
| `LogBenchCraft` | Log de receitas na bancada |
| `LogPlaceBench` | Log de colocação de bancada |
| `LogPlaceWelder` | Log de colocação de soldadora |

### Venda de pneus (`Config.TyreSelling`)

| Chave | Descrição |
|-------|-----------|
| `Enable` | Liga/desliga venda |
| `PickupTruckModels` | Modelos aceites para transportar pneus |
| `MaxTyresInTruck` | Máximo de pneus por viagem |
| `PricePerTyre` | Cash por pneu vendido |
| `NpcCoords` / `NpcModel` | Posição e modelo do comprador |

### Missões de pneus (`Config.TyreMission`)

| Chave | Descrição |
|-------|-----------|
| `Enable` | Liga/desliga missões |
| `MissionCooldown` | Segundos entre contratos por jogador |
| `VehicleModels` | Modelos de veículos alvo |
| `TargetLocations` | Locais de spawn do veículo alvo |
| `BonusReward` | Bónus em cash por missão completa |
| `MinigameRounds` | Parafusos por pneu (skillcheck) |

---

## Compatibilidade com frameworks

O script **não depende de framework** para a lógica principal — inventário é apenas **ox_inventory**. O bridge em `bridge/server_framework.lua` usa o framework apenas para:

- `ServerPlayerIsReady` — saber se o jogador já carregou.
- `BridgeGetCash` / `BridgeRemoveCash` / `BridgeAddCash` — loja do NPC (se `NPC.Shop.Enable = true`).

| Framework | Suporte |
|-----------|---------|
| QBox (`qbx_core`) | Completo |
| QBCore (`qb-core`) | Completo |
| ESX (`es_extended`) | Funcional (sem suporte a `esx_inventory`) |
| Nenhum | Funcional (loja NPC em dinheiro desativada) |

**Chaves de veículo:** integração explícita com `qbx_vehiclekeys` e `qb-vehiclekeys`. Com outro sistema, `Config.RequireVehicleKeys = false` desativa a verificação.

---

## Estrutura de ficheiros

| Caminho | Função |
|---------|--------|
| `bridge/server_framework.lua` | Framework detect; `ServerPlayerIsReady`; `ServerChopPlayerKey`; dinheiro NPC shop |
| `bridge/server_inventory.lua` | Wrappers ox_inventory (count/add/remove) |
| `bridge/client_notify.lua` | Notificações `lib.notify` |
| `shared/config.lua` | Config global compartilhada |
| `shared/locale.lua` | Textos UI (en, pt, es, fr, tr) |
| `shared/chop_parts.lua` | Peças desmontáveis e ordem no menu |
| `server/db.lua` | oxmysql: CRUD bancadas e soldadoras |
| `server/validate.lua` | `ValidatePlayerNearPoint`, `ValidatePlayerNearVehicle` |
| `server/cooldown.lua` | Cooldown opcional entre desmontagens |
| `server/chop.lua` | Fase 1: lógica servidor de desmontar peça e recompensas |
| `server/advanced_chop.lua` | Fases 2-4: porta/motor/carcaça, rate limiting |
| `server/bench.lua` | Lógica de receitas na bancada |
| `server/ambush.lua` | Emboscadas (netId-based): `VPChopAmbushMaybe`, `VPChopNpcMissionAccept` |
| `server/fence.lua` | NPC rotativo, trust, ordens, venda de itens, jackstand server-side |
| `server/heat.lua` | Heat system (VIN scratch, componentes MDT + peças) |
| `server/progression.lua` | XP e tiers (escuta event bus, persiste em `vp_chop_progression`) |
| `server/discord.lua` | Webhook Discord opcional |
| `server/main.lua` | Init, callbacks de placement, broadcast do estado |
| `client/placement.lua` | Modo colocação de bancada/soldadora (raycast + preview) |
| `client/lifts.lua` | Utilitários de peças carregadas (`VPChopCarryingPart`) |
| `client/bench.lua` | Bancada e crafting (client) |
| `client/welder.lua` | Soldadora (client) |
| `client/fence.lua` | Blip rotativo, targets NPC, carry de pneu, truck loading |
| `client/alarm.lua` | Alarme veicular: trigger, skillcheck, dispatch |
| `client/progression.lua` | XP float, tier-up notification |
| `client/main.lua` | Jackstand system, Fases 1-4, sync do mundo, descarte |

---

## Depuração

- `Config.Debug = true` em `shared/config.lua` ativa prints de diagnóstico.
- Se `ox_target` não arrancar, o cliente avisa na consola F8 e não regista targets.
- Comandos admin (requerem ACE):
  - `/choplifts` — lista bancadas e soldadoras ativas no servidor.
  - `/chopremove <id> <bench|welder>` — remove bancada ou soldadora por ID.

---

## Segurança & Compatibilidade

### Auditoria — 2026-04-12
- Auditado por fivem-audit skill (Claude Code)
- 3 críticos, 5 altos resolvidos (v1.3.3 → v1.3.5)
- Consolidação e otimização de schema SQL (v1.3.6)

### UX Overhaul — 2026-04-12 (v1.3.7)
- Remoção de pneus migrada para ox_target por roda (bones `wheel_*`); fim do polling de proximidade
- Pneu carregado: G key abre menu "Colocar no chão / Colocar no truck" (`RegisterKeyMapping`)
- Prop de pneu colocado no chão recebe ox_target para guardar no truck diretamente
- Fix: bones inexistentes (2 portas) não criam mais targets na origem do veículo
- Fix: bone do motor corrigido de `engine` → `bonnet`
- lua54: `VPChopFindNearestTruck` exposta como global em `client/fence.lua`
- Framework: QBox / QBCore / ESX compatível
- lua54: yes — todas as funções cross-file verificadas como globais
- ox_inventory, ox_target, oxmysql, ox_lib — versões atuais suportadas

---

## Versão

`1.6.1` — definida em `fxmanifest.lua`.
