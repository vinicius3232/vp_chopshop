# vp_chopshop

Sistema de desmanche (chop shop) para FiveM: macaco hidráulico → desmonte em 4 fases → materiais, pneus e fence rotativo, emboscadas, **sistema completo de placas** (placa falsa que engana o MDT), **camada forense** (digital/DNA via `evidences`), **marcas de pneu** e **número de série nas peças** (roubada/riscada/forjada/legal, com perícia da polícia). Para stacks com **ox_lib / ox_target / ox_inventory / oxmysql** — frameworks **QBox / QBCore / ESX**.

> 🇵🇹 Esta é a versão em português. Outras línguas: [EN](README_en.md) · [ES](README_es.md) · [FR](README_fr.md) · [TR](README_tr.md).

---

## Security & Compatibility

### Audit — 2026-04-27 (v1.6.7)
- Audited by fivem-audit skill (Claude Code)
- ESX fix: `_ESX.Player()` → `_ESX.GetPlayerFromId()`; `ExtendedPlayers()` → `GetPlayers()` + iteração; `xPlayer.getJob()` → `xPlayer.job.name` (property)
- Framework: **ESX-only** (bridge layer)

### Audit — 2026-04-27 (v1.6.6)
- Audited by fivem-audit skill (Claude Code)
- 1 critical, 4 high, 4 medium, 2 low resolvidos (code-reviewer pass)
- Critical C1: `ServerTyreCounts` movido para global — `server/main.lua` e `server/fence.lua` partilham a única fonte de verdade do contador de pneus
- High H1-H4: race condition na venda de pneus (`SellTyresBusy` mutex); trust decay XP floor corrigido; dead code `_npcBuyCooldown` removido; alarm dispatch quando jogador original desconectou
- Medium M1-M4: refund AddItem com pcall; tyre contract target gated por feature flag; dispatch usa coords do veículo; XP persist em pcall

### Audit — 2026-04-27 (v1.6.4)
- Audited by fivem-audit skill (Claude Code)
- 0 critical, 2 high, 1 medium issues resolved
- High: double SQL query per `VPChopHeatCheck` eliminated (H2); ghost `data_file` ytyp removed (H1)
- Medium: ESX `getAccount('money')` nil guard adicionado em `BridgeGetCash` / `BridgeRemoveCash`
- oxmysql: NECESSÁRIO — 4 tipos de query em 4 arquivos server
- Framework: **ESX-only** (bridge layer)
- oxmysql queries: 100% parametrizadas (`?` placeholders) — sem SQL injection

### Audit — 2026-04-14 (v1.6.1)
- Audited by fivem-audit skill (Claude Code)
- 0 critical, 1 high, 4 medium, 4 low issues resolved
- High: `ESX.GetPlayerFromId` (deprecated) → `ESX.Player` in `ServerPlayerIsReady`
- Medium: ~22 hardcoded PT-BR strings in `client/fence.lua` replaced by `L()` calls; 40 new locale keys added (EN + PT, ES/FR/TR inherit via fallback); dead function `VPChopStartLiftPlacement` removed; tier-up labels moved to locale system
- Low: `Config.Discord.LogPlaceLift` orphan removed; `LogPlaceWelder` key added; `BridgeAddCash` reason parameter added; `source` localized in `playerDropped`
- Framework: **ESX-only** (bridge layer)
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
- High: `truckNetId` nil in tyre truck-load path; deprecated ESX bridge APIs; `breakDoor` global broadcast
- Framework: **ESX-only** (bridge layer)
- Lua 5.4 default (lua54 directive removed — deprecated June 2025)
- All SQL queries use parameterized `?` placeholders

### Audit — 2026-04-13 (v1.3.9)
- Audited by fivem-audit skill (Claude Code)
- 0 critical, 1 high issue resolved (tool durability, XP persistence, broadcast filter)
- Framework: **ESX-only** (bridge layer)

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

### 6. Roubo de placas e placas falsas (`Config.Plates`)

Sistema de identidade veicular ligado ao heat/MDT — a placa é o que liga o carro ao crime.

- **Roubar placa física**: com a chave de fenda (`screwdriver`), mire um veículo alvo (ox_target "Arrancar placa") → skillcheck → recebe o item `stolen_plate` (a placa original fica na metadata). O carro fica sem placa visível. Vendável no fence ou insumo para forjar.
  - **Dispatch por testemunhas**: roubar não chama a polícia automaticamente. A chance é proporcional a **NPCs e jogadores próximos** (com modificador noturno) — área deserta de madrugada quase nunca chama, área movimentada chama mais. Roubar **com testemunhas perto** rende um **bônus de risco** (XP/cash, capado no servidor).
- **Forjar placa falsa**: na bancada (trust **tier 2**), consome uma `stolen_plate` + insumos (`plastic` + `aluminum`) → gera o item `fake_plate` (herda a placa da roubada).
- **Aplicar placa falsa** (usar o item `fake_plate`): troca a placa visível do veículo e **engana a consulta de placa do MDT** — quem consulta vê a placa falsa "limpa", escondendo o histórico.
  - **O heat segue a placa REAL**: o disfarce engana a polícia, mas o crime continua acumulando no carro verdadeiro. A placa falsa **não lava heat** (isso é papel do VIN scratch).
  - **Persistência total**: o disfarce sobrevive a restart e é re-aplicado quando o carro reaparece.
  - **Garagem segura**: guardar um carro disfarçado **nunca grava a placa falsa** no banco (revertida para a real antes de salvar); o disfarce volta no próximo spawn. Requer o hook de garagem (ver Instalação).
- **Remover placa falsa** (polícia): jobs em `Config.Plates.PoliceJobs` têm um ox_target para furar o disfarce e restaurar a placa real.

### 7. Vestígios e perícia (`Config.Evidence`)

Camada **forense** ligada ao resource [`evidences`](https://forum.cfx.re/t/free-evidence-script/5357633) — torna o crime rastreável de verdade, por cima do heat/MDT.

- **Toda ação de crime deixa vestígio** vinculado ao criminoso: desmanche de peça, VIN scratch, roubo de placa, forjar e aplicar placa falsa.
- **Tipos:** **digital** (fingerprint, chance maior) + **DNA** (sangue, chance menor — "corte/suor").
- **Counterplay — luvas:** ter o item **`gloves`** no inventário **bloqueia as digitais**; mas o DNA ainda pode cair (você nunca está 100% seguro). Decisão tática: ir limpo e preparado, ou rápido e arriscado.
- **Escala com o heat:** carro mais "quente" (super, recém-roubado, muitas peças removidas) deixa **mais vestígio**. Trabalhar com pressa = mais risco.
- **A polícia coleta** com o kit do `evidences` e o script **identifica o autor** pela biometria — o bandido pode fugir, mas a cena o entrega.
- **Opcional e seguro:** se o resource `evidences` não estiver rodando, a feature **auto-desativa** sem afetar o desmanche (`Config.Evidence.Enable` também liga/desliga).

### 8. Marcas de pneu (`Config.TyreMarks`)

Pista de **fuga** — complementa a perícia, mas aponta o **veículo**, não a pessoa.

- Após um crime, se o bandido **canta pneu / dá burnout** numa janela curta (~45s), fica uma **marca no chão** ligada ao **modelo do veículo** que fugiu.
- A polícia (jobs configurados) vê o ponto e **examina** → "Marcas de pneu de um **{modelo}** (**{classe}**)". **Nunca revela a placa** (pneu não fala placa) — só o tipo de carro.
- **Counterplay:** sair dirigindo calmo (sem cantar pneu) não deixa marca.
- Marca **transiente** (TTL configurável); servidor resolve o modelo pelo netId (anti-trapaça), exame gated por job + proximidade.

### 9. Número de série das peças (`Config.PartSerial`)

Camada de **economia + forense** no item `car_parts` — RP de mercado de peças para mecânicos, bandidos e polícia.

- Cada `car_parts` carrega **série + estado** na metadata. Peça do desmanche nasce **roubada** (série "quente" + modelo de origem, **sem placa**; uma série por carro).
- **Na bancada** (skill por tier de progressão): **riscar a série** (tier médio → fica adulterada, óbvio) e **forjar uma série nova** (tier máximo → a peça **parece legal**).
- **Fonte legal:** export `exports.vp_chopshop:IssueLegalParts(src, amount)` (para mecânicas integrarem) + vendedor opcional. Séries legítimas ficam registradas no banco.
- **Polícia** (item `parts_scanner` + alvo no jogador "Inspecionar peças"): scan normal mostra **roubada / riscada / registrada**; a peça **forjada parece registrada** — só a **perícia** (com `forensic_kit`) cruza a série no registro e flagra a **forjada**.
- A série é uma camada forense: **não afeta** o consumo de `car_parts` em receitas/venda no fence.

---

## Instalação

1. **Base de dados**
   Executa `sql/vp_chopshop.sql` (cria todas as 8 tabelas: `vp_chopshop_benches`, `vp_chopshop_welders`, `vp_chop_vin_scratched`, `vp_chop_fence_trust`, `vp_chop_fence_orders`, `vp_chop_progression`, `vp_chop_fake_plates`, `vp_chop_legit_serials`). As tabelas também são criadas/migradas automaticamente no boot (idempotente).

2. **Itens (ox_inventory)**
   Copia os blocos de `installation/ox_items_snippet.txt` para `ox_inventory/data/items.lua`. Itens necessários:

   | Item | Uso |
   |------|-----|
   | `chopshop_jackstand` | Macaco — ferramenta principal |
   | `chopshop_bench` | Bancada de crafting |
   | `chopshop_welder` | Soldadora (Fase 4) |
   | `metal_saw` | Serra (Fase 2) |
   | `screwdriver` | Chave de fenda (Fase 3 + roubo de placa) |
   | `chopshop_tyre` | Pneu roubado |
   | `stolen_plate` | Placa física roubada (metadata) |
   | `fake_plate` | Placa falsa forjada (usável — aplica o disfarce) |
   | `gloves` | Luvas — evitam deixar digitais (sistema de evidências) |
   | `parts_scanner` | Scanner de peças (polícia) — inspeciona a série das `car_parts` |

3. **Servidor**
   Adiciona `ensure vp_chopshop` após `ox_lib`, `ox_inventory`, `ox_target`, `oxmysql`.

   **Evidências (opcional):** para a camada forense (seção 7), instale o resource [`evidences`](https://forum.cfx.re/t/free-evidence-script/5357633) e garanta o `ensure` dele. O vp_chopshop apenas **consome** a API (`exports.evidences:syncEvidence`) e **auto-desativa** se o resource não estiver presente — nenhuma dependência rígida. Liga/desliga em `Config.Evidence.Enable`.

   **Hook de garagem (necessário para placa falsa em carro próprio):** para a garagem nunca salvar a placa falsa, adicione no ponto onde ela captura os `props`/placa antes de salvar, ANTES do save:
   ```lua
   if GetResourceState('vp_chopshop') == 'started' then
       props = exports.vp_chopshop:GetRealPlateForProps(vehicle, props)
   end
   ```
   - **QBox (qbx_garages):** em `server/main.lua`, no callback `qbx_garages:server:parkVehicle`, antes do `SaveVehicle` (bloco tagueado `[vp_chopshop F3 garagem]`). ⚠️ Reaplique se o qbx_garages for atualizado.
   - **QBCore (qb-garages):** ver snippet em `installation/qb-garages-hook.md`.

4. **Permissões (ACE)**
   Para comandos admin (`/choplifts`, `/chopremove`), adiciona:
   ```
   add_ace group.admin command.choplifts allow
   add_ace group.admin command.chopremove allow
   ```

5. **Framework**
   O bridge em `bridge/server_framework.lua` detecta automaticamente **QBox (`qbx_core`)**, **QBCore (`qb-core`)** ou **ESX (`es_extended`)** por ordem de prioridade. Usado para `ServerPlayerIsReady`, job (gate policial das placas), dinheiro e citizenid. *(O servidor LIVE é QBox; QBCore é suportado para portabilidade mas não testado neste ambiente.)*

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
| `Config.RequireVehicleKeys` | Exige chaves do veículo (ver `Config.VehicleKeys`) |
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

### Fence NPC rotativo (`Config.Fence`)

O fence é um NPC que muda de localização a cada intervalo configurável (padrão 45 min).

| Chave | Descrição |
|-------|-----------|
| `Locations` | Lista de `{ coords=vector4, blipLabel }` — o fence aparece num deles de cada vez |
| `RotationMinutes` | Minutos entre mudança de local |
| `IntroduceItem` | Item necessário para a primeira apresentação (`fence_referral`) |
| `TrustDecayDays` | Dias de inatividade antes de baixar nível de confiança |
| `TrustXpPerLevel` | Tabela `[1]=100, [2]=300, [3]=600, [4]=1000` — XP cumulativo por nível |
| `NightBonus` | `{ Enable, StartHour, EndHour, Multiplier }` — bônus noturno no preço |
| `ItemPrices` | Preço base por item (modificado por trust/tier/heat) |
| `WholeCarEnable` | Liga entrega de carro inteiro (requer Trust 4) |
| `WholeCarPayout` | Cash base por carro inteiro entregue |
| `OrdersEnable` | Liga sistema de encomendas (requer Trust 3+) |

**Níveis de confiança:**

| Nível | Nome | Acesso |
|-------|------|--------|
| 1 | Conhecido | Vender materiais e pneus |
| 2 | Confiável | Comprar bancada no fence |
| 3 | Parceiro | Receber encomendas com bônus (×1.35–1.5) |
| 4 | Sócio | Entregar carros inteiros; bônus máximo |

### Progressão (`Config.Progression`)

Sistema de XP e tiers por jogador, persistido em `vp_chop_progression`.

| Chave | Descrição |
|-------|-----------|
| `TierXp` | `[1]=0, [2]=500, [3]=2000, [4]=5000` — XP cumulativo por tier |
| `SpeedMult` | Multiplicador de velocidade da barra de progresso por tier |
| `MaterialMult` | Multiplicador de quantidade de materiais por tier |
| `FencePriceMult` | Multiplicador de preço no fence por tier (Tier 4 = +10%) |

**XP por ação:**

| Ação | XP |
|------|-----|
| Fase 1 (peça básica) | 8 |
| Fase 2 (peça estrutural) | 15 |
| Fase 3 (motor) | 40 |
| Fase 4 (carcaça) | 60 |
| Descarte de veículo | 25 |
| Venda de pneu | 5 |
| Encomenda entregue | 120 |
| Missão de pneus | 80 |
| VIN scratch | 30 |
| Venda de material | 10 |
| Entrega de carro inteiro | 150 |

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

### Roubo de placas e placas falsas (`Config.Plates`)

| Chave | Descrição |
|-------|-----------|
| `Enable` | Liga/desliga toda a feature de placas |
| `MaxDistance` / `ApplyMaxDistance` | Distância máx. (server-side) para roubar / aplicar |
| `StealCooldownSeconds` | Cooldown anti-farm de roubo por jogador |
| `SkillCheck` | Minigame ao arrancar a placa (`{ difficulties, keys }` do `lib.skillCheck`) |
| `ToolItem` | Item exigido para roubar (padrão `screwdriver`) |
| `ForgeTier` | Trust mínimo no fence para forjar placa falsa (padrão 2) |
| `ForgeInputs` | Insumos da forja (ex.: `{ plastic = 2, aluminum = 1 }`) |
| `Persist` | Persistência total do disfarce (re-aplica no spawn, sobrevive a restart) |
| `BlockOnOwned` | (legado, inerte — agora permite qualquer carro via hook de garagem) |
| `PoliceJobs` | Jobs que podem remover a placa falsa (ex.: `{ 'police','bcso','sheriff' }`) |
| `Witness` | Dispatch por testemunhas: `{ Radius, NpcWeight, PlayerWeight, BaseChance, MaxChance, NightModifier, BonusMinScore, BonusXp, BonusCashMax }` |

### Vestígios e perícia (`Config.Evidence`)

Integração opcional com o resource `evidences`. Auto-desativa se ele não estiver rodando.

| Chave | Descrição |
|-------|-----------|
| `Enable` | Liga/desliga a camada forense |
| `GlovesItem` | Item que bloqueia digitais (padrão `gloves`) |
| `GlovesBlocksDna` | Se `true`, luvas bloqueiam também o DNA (padrão `false` — DNA ainda cai) |
| `DnaType` | Tipo de DNA deixado: `'blood'` ou `'saliva'` |
| `HeatScaling` / `HeatFactor` | Mais heat na placa → mais chance de vestígio (`chance × (1 + heat/100 × HeatFactor)`) |
| `Actions` | Chance base (0..1) de **digital** e **DNA** por ação: `chop_part`, `vin_scratch`, `plate_steal`, `plate_forge`, `plate_apply` |

### Marcas de pneu (`Config.TyreMarks`)

| Chave | Descrição |
|-------|-----------|
| `Enable` | Liga/desliga as marcas de pneu |
| `ArmWindowSeconds` | Janela após o crime em que cantar pneu deixa marca (~45) |
| `MarkTTLSeconds` | Tempo de vida da marca antes de sumir (~600) |
| `MaxMarksPerCrime` | Máx. de marcas por janela de crime |
| `ExamineDistance` | Distância para a polícia examinar |
| `Burnout` | Limiares de detecção: `{ Ratio, MinWheelSpeed, MaxRealSpeed, CooldownMs }` (calibrar in-game) |
| `PoliceJobs` | Jobs que podem examinar |
| `ClassNames` | Mapa das classes GTA (0..22) → nome pt-BR |

### Número de série das peças (`Config.PartSerial`)

| Chave | Descrição |
|-------|-----------|
| `Enable` | Liga/desliga o sistema de série em `car_parts` |
| `ScratchTier` / `ForgeTier` | Tier de progressão para riscar (médio) e forjar (máximo) |
| `ForgeInputs` | Insumos consumidos ao forjar (ex.: `{ plastic = 2, aluminum = 1 }`) |
| `LegalVendor` | Vendedor de peças legais: `{ Enable, Coords, Model, Price, Amount }` |
| `PoliceJobs` | Jobs que podem inspecionar peças |
| `ScannerItem` / `ForensicItem` | Itens: scanner da polícia (`parts_scanner`) e kit de perícia (`forensic_kit`) |

---

## Compatibilidade com frameworks

O script **não depende de framework** para a lógica principal — inventário é apenas **ox_inventory**. O bridge em `bridge/server_framework.lua` detecta o framework automaticamente e o usa para:

- `ServerPlayerIsReady` — saber se o jogador já carregou.
- `BridgeGetJob` / `BridgeIsPolice` — gate policial da remoção de placa falsa.
- `BridgeGetCash` / `BridgeRemoveCash` / `BridgeAddCash` — loja do NPC e bônus das placas.

| Framework | Suporte |
|-----------|---------|
| QBox (`qbx_core`) | Completo — exports diretos (`GetPlayer`, `AddMoney`, `job.name`) |
| QBCore (`qb-core`) | Suportado (portabilidade — `GetCoreObject`/`Functions.GetPlayer`); não testado neste ambiente |
| ESX Legacy (`es_extended`) | Completo — usa `GetPlayerFromId`, `GetPlayers`, `xPlayer.job.name` |
| Nenhum | Funcional (loja NPC e bônus em dinheiro desativados) |

**Chaves de veículo:** use `Config.VehicleKeys` para apontar seu resource/export de chaves no ESX. Se preferir desligar a verificação, defina `Config.RequireVehicleKeys = false`.

---

## Estrutura de ficheiros

| Caminho | Função |
|---------|--------|
| `bridge/server_framework.lua` | Framework detect; `ServerPlayerIsReady`; `ServerChopPlayerKey`; dinheiro NPC shop |
| `bridge/server_inventory.lua` | Wrappers ox_inventory (count/add/remove) |
| `bridge/client_notify.lua` | Notificações `lib.notify` |
| `bridge/evidence.lua` | Link forense com o resource `evidences` (`VPChopLeaveEvidence`) |
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
| `server/plates.lua` | Roubo de placa, forja/aplicação/remoção de placa falsa, persistência + cache, dispatch por testemunhas, export `GetRealPlateForProps` |
| `server/tyremarks.lua` | Marcas de pneu (resolve modelo, marca com TTL, exame da polícia) |
| `server/partserial.lua` | Série das `car_parts` (riscar/forjar, fonte legal, inspeção da polícia) |
| `server/progression.lua` | XP e tiers (escuta event bus, persiste em `vp_chop_progression`) |
| `server/discord.lua` | Webhook Discord opcional |
| `server/main.lua` | Init, callbacks de placement, broadcast do estado |
| `client/placement.lua` | Modo colocação de bancada/soldadora (raycast + preview) |
| `client/carry.lua` | Carry system de peças carregadas (`VPChopCarryingPart`) |
| `client/bench.lua` | Bancada e crafting (client) |
| `client/welder.lua` | Soldadora (client) |
| `client/fence.lua` | Blip rotativo, targets NPC, carry de pneu, truck loading |
| `client/alarm.lua` | Alarme veicular: trigger, skillcheck, dispatch |
| `client/plates.lua` | ox_target de roubo/remoção de placa, skillcheck, score de testemunhas, export `useFakePlateItem`, sync de placa visível |
| `client/tyremarks.lua` | Detecção de burnout (armar após crime) + ox_target da polícia |
| `client/partserial.lua` | Opções de série na bancada, ox_target de inspeção, vendedor legal |
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

### Auditoria — 2026-04-14 (v1.6.2)
- Auditado por fivem-audit skill (Claude Code)
- 0 críticos, 1 alto resolvido (H1: jackstandTyreStolen — exploit de pneus infinitos via evento sem validação de proximidade)
- 2 médios resolvidos (M1: pcall em saveTrust + rollback de item; M2: trust lookup redundante)
- 1 baixo pendente (L1: TyreMission stub com Enable=true)
- Framework: ESX-only
- Lua 5.4 (padrão desde jun/2025) — globals cross-file verificadas
- ox_inventory v2+, ox_target, oxmysql, ox_lib — versões atuais suportadas

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
- Framework: ESX-only
- lua54: yes — todas as funções cross-file verificadas como globais
- ox_inventory, ox_target, oxmysql, ox_lib — versões atuais suportadas

---

## Versão

`1.13.2` — definida em `fxmanifest.lua`. Histórico completo em [`CHANGELOG.md`](CHANGELOG.md).

> **v1.7.0–1.13.2:** auditoria (limpeza/segurança/performance), recompensa imediata + emboscada,
> o **sistema completo de placas** (roubo físico → forja → placa falsa que engana o MDT,
> persistente e com reversão de garagem; dispatch por testemunhas; suporte QBox/QBCore/ESX),
> a **camada forense** (vestígios de digital/DNA via integração com o resource `evidences`),
> as **marcas de pneu** (pista de fuga pelo modelo do veículo, sem placa),
> e a **série das peças** (`car_parts` roubada/riscada/forjada/legal, com perícia da polícia).
>
> **v1.13.2** — patch de hardening de auditoria (bug + segurança + performance): correção da
> detecção de colisão de placa falsa, vestígio/marca também no desmanche avançado, burnout
> detectado em carros RWD, gate server-side das marcas de pneu, entre outros. Ver CHANGELOG.
