# Changelog — vp_chopshop

---

## [1.14.1] — 2026-06-26 — Correções de auditoria (4 dimensões)

Auditoria completa (performance / segurança / qualidade / banco). Nenhum crítico; 0 exploits
de ganho. Reparos de refinamento aplicados:

### Fixed (Segurança)
- **[M1] `server/plates.lua`:** `witnessScore` (vindo do client) agora é clampado a 25.0 antes
  de calcular o bônus por testemunhas. Antes, `score=9999` saturava sempre o bônus máximo.
- **[M2] `server/main.lua` + `client/main.lua`:** emboscada (`VPChopAmbushMaybe`) agora é
  disparada **server-side** dentro do callback `chopPart`, após a recompensa. O callback
  `vp_chopshop:maybeAmbush` foi removido — o client não decide mais se/quando sofre emboscada
  (antes, um cheater que nunca chamava o callback nunca era emboscado).
- **[M3] `server/main.lua`:** `benchId` sanitizado com `tonumber()` antes do lookup em `benchCraft`.
- **[M4] `server/fence.lua`:** validação de `source_type` em `sellTyres` movida para antes do
  primeiro `.await` (trust), evitando dado não validado cruzar o yield.

### Fixed (Performance)
- **[A1] `client/fence.lua` + `client/main.lua`:** `canInteract` do prop de pneu no chão agora usa
  `VPChopIsTruckNearby()` (cache 500ms) em vez de `VPChopFindNearestTruck` (`GetGamePool` por
  frame). Remove o pico de resmon em uso ativo.
- **[M5] `client/partserial.lua`:** `refresh()` do `canInteract` da bancada agora roda em
  `CreateThread` (fire-and-forget) — nunca bloqueia o `canInteract` com `.await`.
- **[M6] `client/fence.lua`:** loop de carry de pneu `Wait(50)` → `Wait(100)`.
- **[M7] `client/main.lua`:** `DrawMarker` do minigame trocado de tipo 28 para tipo 0 (menor overhead).
- **[M8] `bench/welder/partserial/plates`:** `PlayerPedId()` → `cache.ped` nos `canInteract`.

### Fixed (Robustez)
- **[B2] `server/validate.lua`:** `Config.VehicleNearLiftRadius` agora passa por `tonumber()` com
  fallback (evita erro de runtime se a config vier malformada).

### Notes
- Não alterado por decisão: `ServerTyreCounts` permanece global (acesso cross-file intencional);
  loop de espera do `getWorld` no boot (baixo impacto em servidor pequeno).

---

## [1.14.0] — 2026-06-25 — Minigame de parafusos 3D (estilo "filo") no roubo de pneu e placa

### Added
- **Minigame de parafusos 3D interativo** (`client/main.lua`): câmera dedicada na superfície,
  cursor do mouse mira cada parafuso e o jogador **segura o botão esquerdo + gira o mouse** para
  desrosquear até soltar (o parafuso "pula" para fora com som). Usa o modelo `bolt.ydr` (já no
  `stream/`). Núcleo genérico `runBoltSurface(opts)` reaproveitado por duas pontas:
  - **Roda** (`VPChopBoltMinigame`): 5 parafusos em círculo na face da roda — agora conectado ao
    roubo de pneu via macaco (`doJackstandTyreSteal`), que antes só tinha barra de progresso.
  - **Placa** (`VPChopPlateBoltMinigame`): 2 ou 4 parafusos nos cantos da placa traseira —
    substitui o `lib.skillCheck` no roubo de placa (`client/plates.lua`).
- **Config nova:**
  - `Config.Jackstand.Minigame.Bolt3D` (Enable, Bolts, TurnsToLoosen, Sensitivity, HoverRadius, Timeout).
  - `Config.Plates.Bolt3D` (idem + geometria da placa: PlateZFrac / PlateYOffset / PlateHalfWidth / PlateHalfHeight).
- Locale `bolt_minigame_help` (EN + PT).

### Notes
- **Server-side intacto:** o minigame é apenas UX no client; a validação/recompensa continua nos
  callbacks `vp_chopshop:chopPart` (pneu) e `vp_chopshop:stealPlate` (placa).
- **Fallback automático** para `lib.skillCheck` se o modelo `bolt` ou o bone da roda não carregarem.
- **Geometria da placa é placeholder** — calibrar in-game (`PlateZFrac`, `PlateHalfWidth/Height`).
- As funções de minigame antes órfãs agora estão no fluxo vivo.

---

## [1.13.2] — 2026-05-31 — Rebalanceamento de economia (curva risco→recompensa)

### Changed (Economia)
- **Rodas (Fase 1) reduzidas:** eram a ação mais fácil (só macaco) e pagavam ~1110 cada
  (≈ 4440 por carro só de rodas) — uma "mina de ouro" de baixíssimo risco que invertia a curva.
  Agora ~465/roda (`aluminum 1×0.5, rubber 2, metalscrap 2`), abaixo de uma peça avançada.
- **Carcaça (Fase 4) reforçada:** era a fase mais gated (precisa soldadora) e pagava só ~1260.
  Agora ~2300, incluindo 1× `car_parts`. Mantém o desmanche completo (~8500) competitivo com a
  entrega do carro inteiro no fence (8000), e recompensa quem chega na fase final.
- **Efeito líquido:** renda por carro vai de ~10.100 → ~8.500, **redistribuída** do trivial
  (puxar roda) para o arriscado (desmanche profundo). Curva risco→recompensa corrigida:
  roda < peça avançada < carcaça < entrega do carro inteiro.

### Notes
- Tudo configurável em `Config.CarPartRewards` (rodas) e `Config.AdvancedChop.CarcassRewards`.
- Números escolhidos por equilíbrio interno; **calibrar in-game** conforme a escala da economia
  do servidor. Itens NÃO alterados: `WholeCarBasePayout` (8000), preços do fence, car_parts (400),
  descarte (1500), tiers/XP (curva já saudável).

---

## [1.13.1] — 2026-05-31 — Correções de auditoria (críticos + altos + rápidos)

### Fixed
- **[C1] `server/db.lua` `VPChopDbInsertFakePlate`:** o padrão `pcall(MySQL.query.await, sql, params)`
  rodava sem wrapper de função → o `await` não executava no contexto correto e a colisão de placa
  falsa nunca era detectada. Reescrito para `pcall(function() ... end)` com await sequencial
  (DELETE prévio termina antes do INSERT) e retorno baseado no **sucesso real** do INSERT
  (`MySQL.insert.await` → `insertId`), devolvendo `false` em colisão de PK.
- **[C2] `server/advanced_chop.lua`:** as Fases 2/3/4 (portas/motor/carcaça) não deixavam vestígio
  forense nem armavam marca de pneu — desmanche avançado passava 100% limpo. Adicionado helper
  `leaveAdvancedTrace` que espelha o padrão da Fase 1: `VPChopLeaveEvidence(src, vehCoords,
  'chop_part', realPlate)` + arm de marca de pneu (client + server-side), após o `markChopped` de
  cada fase. `realPlate` resolvida via `VPChopMDT.GetRealPlate` do veículo validado.
- **[C3] `client/tyremarks.lua`:** detecção de burnout lia uma roda só (`GetVehicleWheelSpeed(veh)`)
  → burnout RWD não era detectado. Agora lê as 4 rodas (`GetVehicleWheelSpeed(veh, i)`, com fallback
  defensivo à variante de 1 arg) e usa `math.max(|giro|)`. Removido fallback `PlayerPedId()` no loop
  (usa `cache.ped`).
- **[C4] `server/partserial.lua`:** `buyLegal` chamava `exports['vp_chopshop']:IssueLegalParts` (self-export).
  Lógica extraída para `issueLegalPartsImpl` (função local); export e `buyLegal` chamam a local.
- **[H1] `server/tyremarks.lua`:** sem gate de janela armada server-side, cheater criava marcas a
  qualquer hora. Adicionada tabela `ArmWindow` + helper global `VPChopArmTyreWindow(src, ms)` chamado
  nos pontos de crime (main/heat/plates/advanced_chop); `createTyreMark` rejeita fora da janela.
  Limpeza no `playerDropped` + thread periódica.
- **[H2] `client/tyremarks.lua`:** `marksThisArm` era zerado a cada crime → furava `MaxMarksPerCrime`
  em crimes encadeados. Agora só zera se a janela anterior já expirou; senão estende sem resetar.
- **[H3] `server/partserial.lua` `inspectParts`:** 1 query por slot (`VPChopDbIsLegitSerial`).
  Agrupado em UMA query em lote via novo helper `VPChopDbWhichSerialsLegit(serials) -> set`
  (`WHERE serial IN (...)` com placeholders dinâmicos). Veredito idêntico.
- **[H4] `server/tyremarks.lua` `requestTyreMarks`:** sem rate limit → dump em bulk. Adicionado
  cooldown de 10s por src + cap de tamanho do payload (`Config.TyreMarks.MaxSyncItems`, padrão 200).
- **[M1] `shared/locale.lua`:** `err_adv_only` e `err_no_screwdriver` faltavam em es/fr/tr (caíam em
  inglês). Traduções adicionadas.
- **[M2] `server/plates.lua`:** `GetVehicleNumberPlateText(veh):gsub(...)` sem guard de nil em 3
  pontos. Trocado por `(GetVehicleNumberPlateText(veh) or ''):gsub('%s+','')`.
- **[M3] `server/partserial.lua`:** `IssueLegalParts` agora limita `amount` a 100 e loga via
  `VPChopDiscordLog`.
- **[M4] `server/partserial.lua`:** cooldown de `buyLegal` 2s → 5s.
- **[M5] `server/plates.lua` `applyWitnessBonus`:** hardcap absoluto em código (cash ≤ 1000, XP ≤ 500)
  além da config.
- **[M6] Performance:** loops de lift/lower (`client/main.lua`) `Wait(16)` → `Wait(33)`. O item
  M6(b) (passar `heat` pré-calculado a `VPChopLeaveEvidence`) foi **deixado de fora**: nenhum hook
  pré-calcula heat antes da chamada, então o param só relocaria a query (1 por crime) sem reduzir
  consumo — refator sem ganho líquido.

---

## [1.13.0] — 2026-05-31 — Número de série da car_parts (economia + forense)

### Added
- **[SERIAL]** Cada `car_parts` agora carrega metadata
  `{ serial, state = 'legal'|'stolen'|'scratched'|'forged', sourceModel }`. Camada de economia
  + forense: cria RP para bandido e polícia sem alterar consumo/venda da peça.
- **[SERIAL]** **Origem ROUBADA:** as `car_parts` do desmanche (Fase 2 portas, Fase 3 motor e,
  se configurado, Fase 4 carcaça) nascem `state='stolen'` com **UMA série por VEÍCULO** — todas
  as peças do mesmo `netId` compartilham `serial` + `sourceModel` (cache em memória limpo no
  `entityRemoved`). `sourceModel` é o **display name** resolvido server-side
  (`GetDisplayNameFromVehicleModel`) — **NUNCA a placa** (regra absoluta, coerente com as
  marcas de pneu).
- **[SERIAL]** **Origem LEGAL:** export `exports['vp_chopshop']:IssueLegalParts(src, amount, source?)`
  → gera série, registra como **legítima** no DB (`vp_chop_legit_serials`) e entrega
  `car_parts` `state='legal'`. Mecânicas de oficina podem integrar. Legal e roubado **coexistem**.
- **[SERIAL]** **Bancada — riscar** (`Config.PartSerial.ScratchTier`, padrão 2): apaga a série de
  uma peça `stolen` → `state='scratched'` (scan normal mostra "Série riscada / adulterada").
- **[SERIAL]** **Bancada — forjar** (`Config.PartSerial.ForgeTier`, padrão 4): gera série falsa
  NOVA (NÃO registrada no DB) em peça `stolen`/`scratched` → `state='forged'`. Consome
  `Config.PartSerial.ForgeInputs` (rollback atômico). A forjada **parece legal** no scan normal.
- **[SERIAL]** **Inspeção da polícia:** novo item `parts_scanner` + **ox_target global em
  jogadores** "Inspecionar peças de carro" (gated por job policial). Callback
  `vp_chopshop:inspectParts` valida polícia + scanner + proximidade server-side, lê as
  `car_parts` do alvo e agrupa por estado:
  - Scan **normal**: `legal`→"Registrada", `stolen`→"ROUBADA (de um {modelo})",
    `scratched`→"Série riscada (adulterada)", `forged`→**aparece "Registrada"** (engana).
  - **Perícia** (policial com `forensic_kit`): cruza a série dos "Registrada" em
    `vp_chop_legit_serials` — não consta → **"SÉRIE FORJADA (falsa)"**. Forja só cai na perícia.
  - **NUNCA expõe placa** (nem no resultado nem no log do MDT).
- **[SERIAL]** **Vendedor legal opcional** (`Config.PartSerial.LegalVendor`): NPC fixo com
  ox_target "Comprar peças (legal)"; cobra cash (`BridgeRemoveCash`) e chama `IssueLegalParts`.
  Desligado por padrão (ajuste coords antes de habilitar).
- **[SERIAL]** Nova tabela `vp_chop_legit_serials (serial PK, source, created_at)` —
  auto-criação idempotente no `VPChopDbInit` + bloco em `sql/vp_chopshop.sql`. Helpers
  `VPChopDbRegisterLegitSerial(serial, source)` e `VPChopDbIsLegitSerial(serial)`.
- **[SERIAL]** Bloco `Config.PartSerial` (Enable, ScratchTier, ForgeTier, ForgeInputs,
  cooldowns, InspectDistance, ScannerItem, ForensicItem='forensic_kit', PoliceJobs, LegalVendor).
- **[SERIAL]** Item `parts_scanner` registrado em `ox_inventory/data/items.lua` e no
  `installation/ox_items_snippet.txt`. Locale (en/pt/es/fr/tr) para todas as notify/labels novas.
- **[SERIAL]** Novos arquivos: `server/partserial.lua` (núcleo: geração de série por carro,
  bancada, fonte legal, inspeção) e `client/partserial.lua` (opções de bancada, target global da
  polícia, vendedor legal).

### Notes
- **Stacking:** `car_parts` com metadata distinta NÃO empilha — 1 stack por carro (aceitável).
- **Economia preservada:** receitas da bancada (`bench_repairkit`, ordens do fence) e a venda no
  fence consomem `car_parts` via `RemoveItem` **sem metadata** → removem qualquer instância. O
  estado da série é uma camada FORENSE, não afeta consumo/venda.

---

## [1.12.0] — 2026-05-31 — Marcas de pneu (pista forense de fuga)

### Added
- **[TYRE]** Nova feature **standalone e 100% interna** ao `vp_chopshop`: **marcas de pneu**
  como pista forense de FUGA. Após qualquer crime do chopshop, se o criminoso **canta pneu /
  dá burnout** ao fugir (dentro de `Config.TyreMarks.ArmWindowSeconds`, ~45s), fica uma
  **marca de pneu** no chão. A polícia examina (ox_target) e descobre **APENAS o MODELO e a
  CLASSE** do veículo que fugiu (ex.: *"Marcas de pneu de um Sultan RS (Esportivo)"*).
  **NUNCA revela a placa** — pneu não fala placa. Pista FRACA (aponta o tipo de carro, não a
  pessoa). **Counterplay:** fugir dirigindo calmo (sem cantar pneu) NÃO deixa marca.
- **[TYRE]** `client/tyremarks.lua` (novo): handler `vp_chopshop:armTyreMark` arma a janela;
  detecção de burnout por heurística estável (`GetVehicleWheelSpeed` vs `GetEntitySpeed` —
  patinação = roda girando bem mais rápido que o deslocamento real), com cooldown anti-spam e
  limite `MaxMarksPerCrime`. Reporta só `netId`+coords (trust-no-client). Lado polícia: cria
  ox_target examinável a partir do broadcast e resolve o label do modelo via `GetLabelText`.
- **[TYRE]** `server/tyremarks.lua` (novo): resolve o **modelo server-side** pelo netId
  (`GetEntityModel`/`GetDisplayNameFromVehicleModel`/`GetVehicleClass`), guarda a marca em
  **memória com TTL** (`MarkTTLSeconds`, **sem tabela de DB** — evidência transiente),
  faz broadcast só para jobs policiais. Callback `vp_chopshop:examineTyreMark` com gate de
  job + proximidade server-side; retorna `{ modelName, class }`. **Nunca inclui placa**, nem
  no retorno nem no log do MDT (`VPChopMDT.ReportActivity('', src, 'tyre_marks_model:%s')`).
- **[TYRE]** Os 5 hooks de crime existentes (`chop_part`, `vin_scratch`, `plate_steal`,
  `plate_forge`, `plate_apply`) — nos mesmos pontos onde já se chama `VPChopLeaveEvidence` —
  agora também armam o client do criminoso. Nenhum hook novo criado.
- **[TYRE]** Bloco `Config.TyreMarks` (Enable, ArmWindowSeconds, MarkTTLSeconds,
  MaxMarksPerCrime, ExamineDistance, BurnoutCooldownMs, CreateCooldownMs, PoliceJobs,
  limiares de burnout, mapa pt-BR das classes GTA 0..22).
- **[TYRE]** Locale em 5 idiomas (en/pt/es/fr/tr): `tyre_target_examine`, `tyre_examine_result_fmt`.

---

## [1.11.0] — 2026-05-31 — Integração forense (link com `evidences`)

### Added
- **[EVIDENCE]** Integração server-side com o resource **`evidences`** (Advanced FiveM evidence
  script). **Toda ação de crime** do chopshop agora pode deixar **vestígio forense coletável**
  no local — **digital** (`fingerprint`) e **DNA** (`blood`/`saliva`) — vinculado
  biometricamente ao criminoso. A polícia coleta e identifica via o próprio `evidences`.
  Ações cobertas: `chop_part`, `vin_scratch`, `plate_steal`, `plate_forge`, `plate_apply`.
- **[EVIDENCE]** Nova ponte `bridge/evidence.lua` expondo `VPChopLeaveEvidence(src, coords, actionKey)`.
  Consome `exports.evidences:syncEvidence('fingerprint'|'blood'|'saliva', serverId, 'atCoords', coords, meta)`.
  **Auto-desativa** (sem crashar) se `evidences` não estiver `started` ou se `Config.Evidence.Enable=false`.
  Toda chamada ao export é defensiva (`pcall`) — falha do `evidences` nunca quebra o crime.
- **[EVIDENCE]** Counterplay: item **`gloves`** (Luvas). Possuí-lo no inventário **bloqueia digitais**
  (checado server-side via `InvCount`). **DNA ainda cai** mesmo com luvas (corte/suor),
  configurável por `Config.Evidence.GlovesBlocksDna`.
- **[EVIDENCE]** Bloco `Config.Evidence` (chances base por ação para digital/DNA, tipo de DNA,
  scaling por heat da placa — `HeatScaling`/`HeatFactor` reusam `VPChopHeatCalc`).
- **[EVIDENCE]** Item `gloves` adicionado em `installation/ox_items_snippet.txt` e registrado em
  `ox_inventory/data/items.lua` (label 'Luvas', weight 100, não consumível).

### Notes
- Feature **100% server-side**: nenhum arquivo client foi adicionado; o `evidences` cuida do
  client (coleta/identificação). O `vp_chopshop` apenas **consome** a API dele.

---

## [1.10.0] — 2026-05-31 — Placas: QBCore, persistência total, garagem, testemunhas

### Added
- **[F1 qbcore]** Bridge multi-framework agora detecta e suporta **QBCore (`qb-core`)** além de
  QBox e ESX (`bridge/server_framework.lua`). Detecção por prioridade; QBox continua LIVE.
  QBCore é PORTABILIDADE não-testada (qb-core não está neste servidor).
- **[F2 persist]** **Persistência total da placa falsa**: o disfarce sobrevive a restart e é
  **re-aplicado no spawn** do veículo owned (`AddEventHandler('entityCreated')` server-side).
  `Config.Plates.Persist`. `real_plate` virou **UNIQUE** (corrige bug de linha stale ao reaplicar).
- **[F3 garagem]** Placa falsa agora permitida em **qualquer carro** (`BlockOnOwned` neutralizado).
  Novo export **`vp_chopshop:GetRealPlateForProps(veh, props)`** + patch de 1 linha no
  `qbx_garages` parkVehicle: a garagem **nunca salva a placa falsa** (reverte p/ real antes do
  `SaveVehicle`), mas o disfarce NÃO é apagado — volta no próximo spawn.
  Doc de portabilidade qb-garages em `installation/qb-garages-hook.md`.
- **[F4 testemunhas]** Dispatch do roubo de placa virou **probabilístico por testemunhas**
  (NPCs + players próximos), com modificador noturno e **bônus por risco** (XP/cash capados
  server-side). `Config.Plates.Witness`. Helper client `VPChopWitnessScore(veh)`.

### Changed
- `entityRemoved` de placas: deixa de apagar o mapeamento de carros **owned** ao guardar
  (preserva persistência); só limpa **transientes** (sem `state.vehicleid`).

### Performance
- **[F2 persist] Cache em memória dos disfarces** (`DisguiseByReal`, carregado do DB no boot e
  sincronizado em apply/remove). O `entityCreated` (re-aplicação no spawn) consulta o cache O(1)
  em vez de 1 query no DB por veículo — sem isto, todo carro de trânsito NPC dispararia um SELECT.
  Gate extra: se não há **nenhum** disfarce no servidor, o handler sai sem nem criar thread.

### Migration
- Rode a migração de `vp_chop_fake_plates` (UNIQUE em `real_plate`) — o `db.lua` faz no boot
  automaticamente (idempotente); equivalente manual em `sql/vp_chopshop.sql`.

---

## [1.9.0] — 2026-05-31 — Placas falsas (Fases 2 e 3)

### Added (Feature — placa falsa)
- **Forjar placa falsa** na bancada (tier 2): consome uma `stolen_plate` específica (match por
  metadata) + insumos (`plastic`+`aluminum`, configuráveis) com rollback atômico → gera item
  `fake_plate` com metadata `{ plate }` herdada da placa roubada. Opção no menu da bancada.
- **Aplicar placa falsa** (`vp_chopshop.useFakePlateItem`): troca a placa visível do veículo e
  **engana a consulta do MDT** — quem consulta vê a placa falsa "limpa". Persistido em
  `vp_chop_fake_plates` (mapa falsa→real).
- **Heat segue a placa REAL** mesmo com a falsa exibida (novo `VPChopMDT.GetRealPlate` +
  `VPChopDbResolveRealPlate`, roteado em `server/heat.lua`). O crime segue o carro; só a consulta
  pública é enganada. VIN scratch permanece o caminho permanente/caro (não canibalizado).
- **Remoção pela polícia**: ox_target gated por job (`Config.Plates.PoliceJobs`) restaura a placa
  real e apaga o mapeamento.
- **Tabela nova** `vp_chop_fake_plates` (SQL + auto-criação em `VPChopDbInit`).
- **Sync robusto** via statebag `vpFakeRealPlate` (re-aplica a placa visível para clientes que
  entram no scope depois). A placa falsa não vai no statebag (segurança).

### Security / Design
- **[Garagem] Placa falsa bloqueada em veículo PRÓPRIO** (`Config.Plates.BlockOnOwned=true`):
  carro owned do qbx tem `state.vehicleid`; guardá-lo com placa falsa gravaria a falsa no
  `player_vehicles`. Carros criminosos (alvo real) não têm vehicleid → o disfarce funciona neles
  sem risco. Decisão que NÃO exige editar qbx_garages.
- Todos os callbacks (`forgeFakePlate`/`applyFakePlate`/`removeFakePlate`) com validação
  server-side completa: source, cooldown, proximity, posse/metadata do item, colisão de placa por
  PK, insert atômico com rollback, cleanup em `playerDropped` e `entityRemoved`.

### Notes
- Item `fake_plate` já existia no `ox_inventory` (órfão); foi **incrementado** (consume + client
  export + metadata) em vez de duplicado.
- Requer a tabela `vp_chop_fake_plates` (criada no boot) e o item `fake_plate` atualizado no
  `ox_inventory`.

---

## [1.8.0] — 2026-05-31 — Roubo de placa física (Fase 1)

### Added (Feature — Fase 1 de placas)
- **Roubo de placa física.** Nova mecânica: o jogador usa uma chave de fenda (`screwdriver`)
  num veículo alvo, passa um skillcheck e arranca a placa, recebendo o item `stolen_plate`
  com metadata `{ plate, model, takenAt }`. O veículo fica sem placa visível (broadcast
  filtrado por proximidade ~150u). Vendável no fence (~$250) e insumo futuro para placa falsa.
- **Arquivos novos:** `client/plates.lua` (ox_target em veículos + `lib.skillCheck` + handlers
  de placa-limpa/dispatch) e `server/plates.lua` (callback `vp_chopshop:stealPlate` com todas
  as validações server-side: `IsValidSource`, cooldown 30s/jogador, proximity, placa resolvida
  no servidor, flag anti-duplo-roubo por netId, rollback se inventário cheio).
- **Novo item:** `stolen_plate` (`installation/ox_items_snippet.txt`; registrar em
  `ox_inventory/data/items.lua`).
- **Config:** novo bloco `Config.Plates` (Enable, MaxDistance, StealCooldownSeconds, SkillCheck,
  ToolItem, DispatchOnSteal). `stolen_plate` adicionado a `Config.Fence.BasePrices` (250).
- **Progressão:** `XP_TABLE.plate_theft = 12` (tier 1) + tratamento no listener `PART_CHOPPED`.
- **Dispatch:** ao roubar a placa, dispara alerta de polícia reusando o mesmo mecanismo do alarme.
- **MDT:** `VPChopMDT.ReportActivity(realPlate, src, 'plate_stolen')`.
- **Locale:** 7 chaves novas em 5 idiomas (en/pt/es/fr/tr).

### Notes
- Integração: feature ligada por `Config.Plates.Enable`. Requer registrar o item `stolen_plate`
  no `ox_inventory/data/items.lua` para funcionar.
- Fase 1 não persiste a placa apagada (recarregar a entidade restaura a placa original) —
  intencional; persistência/placa falsa/garagem vêm nas Fases 2-3.

---

## [1.7.0] — 2026-05-31 — Auditoria: limpeza, gameplay, segurança, performance

### Changed (Gameplay)
- [Economia] **Recompensa da Fase 1 agora é IMEDIATA**, unificada com as fases avançadas
  (2-4). Antes a recompensa ficava pendente e só era entregue ao carregar a peça até a
  bancada (`vp_chopshop:deliverPart`); agora os itens caem no inventário no momento do
  desmanche, no callback `vp_chopshop:chopPart`. Removido todo o sistema de recompensa
  pendente (`PendingPartRewards`, `VPChopStorePendingReward`, `VPChopClaimPendingReward`),
  o callback `vp_chopshop:deliverPart` e o target "entregar peça" da bancada. Fluxo
  pneu→truck→fence e craft na bancada (`benchCraft`) preservados intactos.
- [Progressão] **Emboscada ligada** (`Config.Ambush.Enable/RandomOnDismantle = true`,
  `Chance = 0.05`, `ReferralDropChance = 0.5`). A emboscada é a única fonte de
  `fence_referral` — com ela desligada, jogadores novos não conseguiam acessar o fence.

### Fixed (Security)
- [Concurrency] `server/main.lua` `playerDropped`: **bug latente corrigido** — os rate-limits
  `_chopPartRateLimit`/`_benchCraftRateLimit` eram declarados `local` *depois* do handler,
  então a limpeza no disconnect referenciava um global `nil` (leak + possível erro no
  console). Movidos para forward-declaration no topo do arquivo.
- [Security] `server/main.lua` `vp_chopshop:server:alarmDisarmed`: adicionado rate-limit
  anti-flood (2s) — cada chamada fazia lookup + export de inventário sem gating.
- [Security] `server/fence.lua` `vp_chopshop:tyres:jackstandTyreStolen`: adicionado cap de
  4 pneus por veículo (`JackstandTyreCount`) — sem isto, um cheater podia disparar o evento
  repetidamente (espaçando >5s) e gerar pneus infinitos do mesmo carro.

### Performance
- [Client] `client/main.lua`: TextUI de carry de pneu exibida 1× em vez de uma thread
  repetindo `showTextUI` a cada 200ms (5 roundtrips NUI/s desnecessários).
- [Client] `client/main.lua` `doLiftVehicle`/`doLowerVehicle`: `Wait(0)` → `Wait(16)` nos
  loops de levantar/baixar veículo (movimento é delta por `GetFrameTime`, sem perda visual).
- [Client] `client/placement.lua`: raycast de ghost-placement `Wait(16)` → `Wait(33)`.

### Removed (Dead code)
- Deletados 6 arquivos stub/tombstone do refactor do elevador: `client/npc.lua`,
  `client/tyres.lua`, `server/npc.lua`, `server/partners.lua`, `server/tyres.lua` e
  `client/lifts.lua` (este byte-idêntico ao `client/carry.lua`; nenhum estava no manifest).
- Removida função órfã `VPChopJackstandStealTyre` (`client/main.lua`) — zero chamadas; o
  fluxo vivo é `doJackstandTyreSteal`.

### Fixed (UX)
- [Client] `client/fence.lua`: opção "comprar bancada" agora só aparece se `Config.NPC.Shop.Enable`
  (espelha o gate já existente da TyreMission). Antes mostrava notificação de erro quando a
  feature estava desligada.

### Notes
- Chaves de locale órfãs (sem uso em código vivo, inofensivas): `progress_delivering_part`,
  `target_deliver_part`, `notify_part_delivered`, `notify_no_part_carrying`.
- ⚠️ Item de economia (recompensa imediata) requer teste in-game antes de produção.

---

## [1.6.7] — 2026-04-27 — ESX Bridge Fix

### Fixed
- [ESX] `bridge/server_framework.lua`: todas as ocorrências de `_ESX.Player(src)` substituídas
  por `_ESX.GetPlayerFromId(src)` — API documentada do ESX Legacy; `.Player()` não existe no
  ESX Legacy padrão, tornando `ServerPlayerIsReady`, `BridgeGetCash`, `BridgeRemoveCash` e
  `BridgeAddCash` sempre nil no ESX
- [ESX] `BridgeCountCops`: `_ESX.ExtendedPlayers()` substituído por `_ESX.GetPlayers()` +
  `GetPlayerFromId(pid)` — `ExtendedPlayers` não existe no ESX Legacy → nil call crash
- [ESX] `BridgeCountCops`: `xPlayer.getJob().name` substituído por `xPlayer.job.name` —
  no ESX Legacy moderno `job` é uma propriedade, não um método; cops nunca eram contados
- [ESX] `removeAccountMoney` / `addAccountMoney`: removido o parâmetro `label` (terceiro
  argumento) — ESX Legacy não aceita este parâmetro na assinatura padrão

---

## [1.6.6] — 2026-04-27 — Code Review Fix-All

### Fixed (Critical)
- [Logic] `server/main.lua` + `server/fence.lua`: split tyre counter — `vp_chopshop:server:addTyreToTruck`
  now writes `ServerTyreCounts[netId]` (made global) instead of only the state bag; both client
  load paths (jackstand carry and fence prop ox_target) share one authoritative counter for
  `sellTyres` payout (C1)

### Fixed (High)
- [Concurrency] `server/fence.lua`: `vp_chopshop:fence:sellTyres` — added `SellTyresBusy[src]`
  mutex (identical pattern to `DeliveryBusy`); `release()` helper clears mutex on all code paths;
  `ServerTyreCounts[nid]` already zeroed before any yield (H1)
- [Logic] `server/fence.lua` `loadTrust`: trust decay now also resets `trust_xp` to
  `xpTable[new_level]` and persists both in the same UPDATE; prevents `addTrustXp` from
  immediately re-firing tierUp notifications for lost levels (H2)
- [Security] `server/main.lua`: removed dead `vp_chopshop:npcBuy` callback — no client path
  calls it (replaced by `vp_chopshop:fence:buyBench`); removed dead `_npcBuyCooldown` helpers
  and cleanup from `playerDropped` (H3)
- [Logic] `server/main.lua` alarm timeout: when the original chopper disconnects during the
  disarm window, police dispatch now fires to the nearest online player within 200m instead of
  silently dropping (H4)

### Fixed (Medium)
- [Logic] `server/fence.lua` `introduce`: `AddItem` refund return value now checked; failure
  logged to console so the item can be manually restored on DB+inventory-full edge case (M1)
- [Logic] `server/main.lua` `/choptest`: replaced `Config.ChopTool.Item` (undefined) with
  iteration over `Config.Tools` keys — admin kit now correctly includes saws and drills (M2)
- [Structure] `client/fence.lua`: `vp_fence_tyre_contract` ox_target option is no longer
  registered when `Config.TyreMission.Enable` is false — hides the button instead of showing
  "Erro." on click (M3)
- [Reliability] `server/progression.lua`: XP persist `MySQL.query.await` now wrapped in `pcall`;
  DB failures print a WARN line to console instead of silently discarding tier-ups (M4)

### Fixed (Low)
- [Versioning] `fxmanifest.lua`: bumped version `1.6.3` → `1.6.6` (L1)
- [Logic] `client/main.lua` `VPChopTriggerDispatch`: `cd_dispatch` branch now uses
  `GetEntityCoords(veh)` when available instead of player coords — dispatch blip lands on
  the vehicle, not on the fleeing player (L2)

---

## [1.6.5] — 2026-04-27 — SQL Consolidation

### Changed
- [Structure] `sql/`: consolidado para arquivo único `vp_chopshop.sql`; `migrate_v1.6.0.sql`
  removido (migração histórica v1.5.x→v1.6.0; servidores já atualizados não precisam mais)
- [Performance] `vp_chopshop_benches` e `vp_chopshop_welders`: coluna `position TEXT` alterada
  para `position VARCHAR(100)` — evita leitura off-page do InnoDB para JSON curto (~40 chars);
  dados ficam inline no B-tree leaf
- [Documentation] `vp_chopshop_welders.placed_by`: adicionado COMMENT ausente
  (`'license:... do jogador'`); alinhado com `vp_chopshop_benches`

---

## [1.6.4] — 2026-04-27 — Audit Auto-Fix

### Fixed (High)
- [Performance] `server/heat.lua`: `VPChopHeatCheck` chamava `VPChopHeatCalc` (SQL) duas
  vezes — via `notifyHeatChange` e depois via `VPChopHeatGetLabel`. Agora calcula o label
  uma vez e passa como parâmetro opcional para `notifyHeatChange` (H2)
- [Structure] `fxmanifest.lua`: `data_file 'DLC_ITYP_REQUEST' 'stream/wheel_spacer.ytyp'`
  removido — arquivo não existe na pasta stream, causando warning no console. O bolt
  minigame usa `lib.skillCheck` como fallback enquanto o modelo não for incluído (H1)

### Fixed (Medium)
- [Logic] `bridge/server_framework.lua` ESX: `x.getAccount('money')` agora tem nil guard
  antes de acessar `.money` em `BridgeGetCash` e `BridgeRemoveCash` — previne crash em
  contas ESX ausentes/corrompidas (M1)

### Fixed (Medium)
- [Structure] Deletados tombstones server (npc.lua, tyres.lua, partners.lua) — não listados
  no manifest; limpeza de diretório (M2)
- [Structure] Removidos 5 blocos `local VPChopEvt = VPChopEvt or {...}` redundantes em
  heat.lua, main.lua, fence.lua, advanced_chop.lua, progression.lua — VPChopEvt é global
  definido em bridge/mdt.lua (primeiro server_script); os fallbacks nunca eram atingidos (M3)

### Fixed (Low)
- [Structure] Deletados tombstones client (tyres.lua, npc.lua) — não listados no manifest (L1)
- [Structure] `client/lifts.lua` renomeado para `client/carry.lua` — nome reflete conteúdo
  real (carry state + VPChopDropCarryPart); fxmanifest atualizado (L2)

---

## [1.6.3] — 2026-04-25 — Audit Auto-Fix

### Fixed (High)
- [Performance] `bridge/server_framework.lua`: `exports['es_extended']:getSharedObject()` era chamado
  em CADA invocação de bridge. Migrado para cache único em `CreateThread` (`_ESX`); todas as
  funções usam o cache com guarda nil (H2)
- [Security] `client/main.lua` + `server/main.lua`: contagem de pneus no truck migrada
  de state bag cliente (`Entity(t).state:set(...)`) para evento de servidor
  `vp_chopshop:server:addTyreToTruck`; servidor valida proximidade e faz o set
  autoritativo — previne exploit de reset do contador via state bag (H3)

### Fixed (Medium)
- [Performance] `server/main.lua`: `_npcBuyCooldown` migrado de `os.time()` (suscetível
  a ajuste de relógio) para `GetGameTimer()` em ms (monotônico) (M4)

---

## [1.6.3] — 2026-04-15 — Integração qs-mechanic-creator

### Added
- **[Feature] shared/config.lua + shared/locale.lua** — 2 novas receitas de bancada para integração com `qs-mechanic-creator`:
  - `bench_repairkit`: `car_parts×5 + metalscrap×10 → repairkit×1` (12s) — converte peças de desmanche em kit de reparo para oficinas legítimas
  - `bench_rope`: `rubber×8 + plastic×5 → rope×1` (8s) — transforma sobras da carcaça (Fase 4) em corda de recuperação de veículos
- Chaves de locale adicionadas em todas as 5 línguas (en, pt, es, fr, tr)

---

## [1.6.2] — 2026-04-14 — Audit Auto-Fix

### Fixed (High)
- **[Security] server/fence.lua + client/main.lua** — `jackstandTyreStolen` disparado sem parâmetros: cliente não passava netId do veículo, servidor não tinha como validar proximidade. Um cliente modificado podia obter `chopshop_tyre` indefinidamente (1 item/5s via rate-limit). Agora o cliente passa `NetworkGetNetworkIdFromEntity(veh)` e o servidor executa `ValidatePlayerNearVehicle(src, veh, 8.0)` antes de `AddItem`.

### Fixed (Medium)
- **[Logic] server/fence.lua:fence:introduce** — `saveTrust(src)` era chamado sem pcall depois de `RemoveItem('fence_referral')`. Falha de DB resultava em item consumido mas trust não persistido: ao desconectar, `TrustCache` limpo → trust volta a 0. Agora: `pcall(saveTrust, src)`; em erro → `AddItem(src, 'fence_referral', 1)` + retorno `{ ok=false, err='db' }`.
- **[Logic] server/fence.lua:fulfillOrder** — `VPChopFenceGetTrust(src)` chamado duas vezes (guard na linha 621 + cálculo de `trustM` na linha 654): segunda chamada era redundante (cache hit mas desnecessária). Armazenado em `local trust` e reutilizado.

### Fixed (Low)
- **[Logic] shared/config.lua** — `Config.TyreMission.Enable` alterado de `true` para `false`. `TyreMissionStart()` é stub não implementado; target "Contrato de pneus" exibia "Erro." no menu fence.

---

## [1.6.1] — 2026-04-14 — Audit Auto-Fix

### Fixed (High)
- **[Logic] bridge/server_framework.lua** — `ESX.GetPlayerFromId(src)` depreciado na função `ServerPlayerIsReady` substituído por `ESX.Player(src)` — alinha com as demais chamadas ESX no mesmo arquivo.

### Fixed (Medium)
- **[Structure] client/fence.lua** — ~22 strings PT-BR hardcoded substituídas por chamadas `L()` (menus Vender Materiais, Seu Status, Encomenda Ativa, Entregar Veículo e targets de pneu). Todas as 5 locales agora respeitadas.
- **[Structure] shared/locale.lua** — 40 novas chaves adicionadas em EN e PT: `fence_sell_*`, `fence_status_*`, `fence_order_*`, `fence_car_*`, `fence_tyre_pick_label`, `fence_tyre_load_label`, `tier_label_1..4`, `tier_unlock_2..4`. ES/FR/TR herdam do EN via fallback automático.
- **[Logic] client/placement.lua** — `VPChopStartLiftPlacement()` removida — referenciava `Config.LiftBaseModel` (nil) e callback inexistente `vp_chopshop:placeLift`.
- **[Structure] server/progression.lua + client/progression.lua** — Labels e unlocks de tier-up movidos para `locale.lua`; servidor envia apenas `newTier`, cliente chama `L('tier_label_N')` e `L('tier_unlock_N')`.
- **[Logic] server/main.lua** — `/choptest` kit: linha `Config.Items.fuel` (nil desde v1.5.x) removida — evitava `AddItem(target, nil, 5)` em runtime.

### Fixed (Low)
- **[Structure] shared/config.lua** — `Config.Discord.LogPlaceLift = false` removida (elevador removido). `Config.Discord.LogPlaceWelder = false` adicionada (era verificada em `server/discord.lua` mas não existia).
- **[Logic] server/main.lua:437** — `BridgeAddCash(source, payout)` agora passa `'discard_payout'` como reason para transaction logging.
- **[Structure] server/fence.lua** — `playerDropped` handler de `JackstandStealCooldown` localiza `source` antes do body (padrão defensivo consistente).

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
- **[Logic] bridge/server_framework.lua** — ponte ESX para `BridgeGetCash`, `BridgeRemoveCash` e `BridgeAddCash`.
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
