# vp_chopshop

Système de **casse automobile** (chop shop) pour FiveM : le joueur utilise un **cric mécanique** (`chopshop_jackstand`) pour soulever n'importe quel véhicule et démonter les pièces en 4 phases progressives, en obtenant des récompenses matérielles, la vente de pneus à un PNJ receleur rotatif, des embuscades optionnelles, un **système complet de plaques** (vol physique, fausse plaque qui trompe le MDT, persistance et dispatch selon les témoins), une **couche forensique** (indices d'empreinte/ADN que la police collecte), des **traces de pneus** et un **numéro de série sur les pièces** (volée/rayée/forgée/légale, avec expertise de la police). Conçu pour être utilisé avec **ox_lib**, **ox_target**, **ox_inventory** et **oxmysql** — frameworks **QBox / QBCore / ESX**.

> 🇫🇷 Ceci est la version française. Autres langues : [EN](README_en.md) · [PT](README_pt.md) · [ES](README_es.md) · [TR](README_tr.md).

---

## Prérequis obligatoires

| Ressource | Utilisation |
|---------|-----|
| `ox_lib` | Menus, barres de progression, skillchecks, callbacks |
| `ox_target` | Interaction avec le véhicule surélevé, l'établi, le poste à souder et le PNJ |
| `ox_inventory` | Objets, ajout/suppression de matériaux |
| `oxmysql` | Persistance pour l'établi et le poste à souder |

Ordre suggéré dans `server.cfg` : dépendances ox en premier, puis `ensure vp_chopshop`.

---

## Langues (UI)

Dans `shared/config.lua`, définissez **`Config.Locale`** avec l'une de ces valeurs :

| Valeur | Langue |
|-------|--------|
| `en` | English |
| `pt` | Português (par défaut) |
| `es` | Español |
| `fr` | Français |
| `tr` | Türkçe |

Les chaînes de caractères se trouvent dans `shared/locale.lua`. Pour les recettes personnalisées : utilisez `labelKey` (une clé existante dans `locale.lua`) ou le champ hérité `label` (texte fixe, pas de traduction auto).

Les **noms des objets** dans `ox_inventory` (`installation/ox_items_snippet.txt`) sont indépendants — traduisez-les manuellement dans le fichier `items.lua` si nécessaire.

---

## Comment ça marche (Joueur)

### 1. Cric mécanique — Outil principal

- Utilisez l'objet **Cric** (`chopshop_jackstand`) à proximité de n'importe quel véhicule.
- La barre de progression "Placement du cric..." lève la voiture (~8 s).
- Avec la voiture surélevée, les **points de démontage** apparaissent via `ox_target`.
- **Baisser la voiture** : utilisez le point "Retirer le cric" sur le véhicule.

### 2. Phases de démontage (toutes requièrent le cric)

| Phase | Pièces | Outil additionnel | Récompense |
|------|-------|-----------------|------------|
| **1 — Basique** | Capot, coffre, roues, portes | — | Matériaux via `Config.CarPartRewards` |
| **2 — Structure** | Portes / capot / coffre | Scie (`metal_saw`) | `car_parts` par pièce |
| **3 — Moteur** | Moteur | Tournevis (`screwdriver`) | 5× `car_parts` |
| **4 — Carcasse** | Carcasse | Poste à souder proche du véhicule | Matériaux recyclables (avec pourcentage de chance) |

> La **Phase 3** nécessite que le capot ait été retiré lors de la Phase 2.
> La **Phase 4** nécessite que le moteur ait été retiré lors de la Phase 3 et qu'un poste à souder soit placé dans le `Config.AdvancedChop.WelderRadius`.

### 3. Mise au rebut du véhicule

Après avoir retiré le nombre de pièces paramétré dans `Config.Discard.MinPartsToDiscard`, l'option **Apporter à la déchetterie** apparaît. Le joueur gagne une base en monnaie (cash) assignée via `DefaultPayout`. Si `CopsBonus.Enable` est activé, ce gain est multiplié s'il y a suffisamment de policiers en ligne.

### 4. Établi (`chopshop_bench`)

- Utilisez l'objet **Établi** (Workbench) pour placer l'atelier de fabrication.
- Les recettes se configurent dans `Config.BenchRecipes` (ingrédients/résultats/durée).
- Un poste à souder est nécessaire près de l'établi pour fabriquer des éléments de la Phase 4.

### 5. Pneus — Vente et missions

- **Vente directe** : enlevez les pneus au cric → chargez-les dans un pick-up → apportez-les au PNJ acheteur → le joueur reçoit son paiement en cash (`Config.TyreSelling.PricePerTyre`).
- **Missions sous contrat** (`Config.TyreMission`) : le PNJ offre un contrat → la voiture ciblée spawne → retirez 4 pneus (mini-jeu de vis) → livrez à l'acheteur → bonus attribué.

### 6. Vol de plaques et fausses plaques (`Config.Plates`)

Système d'identité du véhicule relié au heat/MDT — c'est la plaque qui relie la voiture au crime.

- **Voler une plaque physique** : avec le tournevis (`screwdriver`), visez un véhicule cible (ox_target « Arracher la plaque ») → skillcheck → vous recevez l'objet `stolen_plate` (la plaque d'origine est conservée dans la metadata). Le véhicule reste **sans plaque visible**. Revendable au receleur ou utilisable comme matériau pour forger.
  - **Dispatch selon les témoins** : voler n'appelle pas la police automatiquement. La chance d'alerter dépend des **PNJ et joueurs proches** (avec un modificateur nocturne) — une zone déserte en pleine nuit n'alerte presque jamais, une zone fréquentée alerte davantage. Voler **avec des témoins à proximité** rapporte un **bonus de risque** (XP/argent, plafonné côté serveur).
- **Forger une fausse plaque** : à l'établi (confiance **palier 2**), consomme une `stolen_plate` + des matériaux (`plastic` + `aluminum`) → génère l'objet `fake_plate` (qui hérite de la plaque volée).
- **Appliquer une fausse plaque** (utiliser l'objet `fake_plate`) : change la plaque visible du véhicule et **trompe la recherche de plaque dans le MDT** — celui qui consulte voit la fausse plaque « propre », ce qui masque l'historique.
  - **Le heat suit la VRAIE plaque** : le déguisement trompe la police, mais le crime continue de s'accumuler sur le véhicule véritable. La fausse plaque **ne lave pas le heat** (c'est le rôle du grattage de VIN).
  - **Persistance totale** : le déguisement survit aux redémarrages et est ré-appliqué lorsque la voiture réapparaît (spawn).
  - **Sûr en garage** : ranger un véhicule déguisé **n'enregistre jamais la fausse plaque** en base (rétablie sur la vraie avant la sauvegarde) ; le déguisement revient au spawn suivant. Nécessite le hook de garage (voir Installation).
- **Retirer une fausse plaque** (police) : les métiers définis dans `Config.Plates.PoliceJobs` disposent d'un ox_target pour percer le déguisement et restaurer la vraie plaque.

### 7. Indices forensiques / Preuves (`Config.Evidence`)

Couche **forensique** reliée à la ressource [`evidences`](https://forum.cfx.re/t/free-evidence-script/5357633) — elle rend le crime réellement traçable, par-dessus le heat/MDT.

- **Chaque action criminelle laisse un indice** lié au criminel : démontage de pièce, grattage de VIN, vol de plaque, forge et application d'une fausse plaque.
- **Types :** **empreinte** (fingerprint, chance plus élevée) + **ADN** (sang, chance plus faible — « coupure/sueur »).
- **Counterplay — gants :** avoir l'objet **`gloves`** dans l'inventaire **bloque les empreintes** ; mais l'ADN peut quand même tomber (vous n'êtes jamais sûr à 100 %). Choix tactique : partir propre et préparé, ou rapide et risqué.
- **Échelle avec le heat :** une voiture plus « chaude » (super, fraîchement volée, beaucoup de pièces retirées) laisse **plus d'indices**. Travailler dans la précipitation = plus de risque.
- **La police collecte** avec le kit `evidences` et le script **identifie l'auteur** par biométrie — le bandit peut fuir, mais la scène le livre.
- **Optionnel et sûr :** si la ressource `evidences` ne tourne pas, la fonction **se désactive automatiquement** sans affecter le démontage (`Config.Evidence.Enable` active/désactive aussi).

### 8. Traces de pneus (`Config.TyreMarks`)

Indice de **fuite** — complète l'expertise forensique, mais il pointe le **véhicule**, pas la personne.

- Après un crime, si le criminel **fait crisser les pneus / un burnout** dans une fenêtre courte (~45 s), une **trace reste au sol**, liée au **modèle du véhicule** qui a pris la fuite.
- La police (métiers configurés) repère le point et l'**examine** → « Traces de pneus d'un **{modèle}** (**{classe}**) ». **Ne révèle jamais la plaque** (un pneu ne dit pas la plaque) — seulement le type de voiture.
- **Counterplay :** partir au volant calmement (sans faire crisser les pneus) ne laisse aucune trace.
- Trace **transitoire** (TTL configurable) ; le serveur résout le modèle par le netId (anti-triche), examen soumis à un gate métier + proximité.

### 9. Numéro de série des pièces (`Config.PartSerial`)

Couche **économie + forensique** sur l'objet `car_parts` — RP du marché des pièces pour les mécaniciens, les bandits et la police.

- Chaque `car_parts` porte une **série + un état** dans la metadata. Les pièces issues du démontage naissent **volées** (série « chaude » + modèle d'origine, **sans plaque** ; une série par voiture).
- **À l'établi** (gate par palier de progression) : **rayer la série** (palier moyen → la pièce paraît visiblement trafiquée) et **forger une nouvelle série** (palier max → la pièce **paraît légale**).
- **Source légale :** export `exports.vp_chopshop:IssueLegalParts(src, amount)` (pour que les ateliers de mécanique s'intègrent) + vendeur optionnel. Les séries légitimes sont enregistrées en base de données.
- **Police** (objet `parts_scanner` + cible sur le joueur « Inspecter les pièces ») : le scan normal montre **volée / rayée / enregistrée** ; une pièce **forgée paraît enregistrée** — seule l'**expertise** (avec `forensic_kit`) recoupe la série dans le registre et démasque la **contrefaçon**.
- La série est une couche forensique : elle **n'affecte pas** la consommation de `car_parts` dans les recettes / la vente au receleur.

---

## Installation

1. **Base de données**
   Exécutez `sql/vp_chopshop.sql` (crée les **8 tables** : `vp_chopshop_benches`, `vp_chopshop_welders`, `vp_chop_vin_scratched`, `vp_chop_fence_trust`, `vp_chop_fence_orders`, `vp_chop_progression`, `vp_chop_fake_plates`, `vp_chop_legit_serials`). Les tables sont aussi créées/migrées automatiquement au démarrage (idempotent).

2. **Objets (ox_inventory)**
   Copiez les blocs de `installation/ox_items_snippet.txt` dans `ox_inventory/data/items.lua`. Objets requis :

   | Objet | Utilisation |
   |------|-----|
   | `chopshop_jackstand` | Cric — outil principal |
   | `chopshop_bench` | Établi de fabrication |
   | `chopshop_welder` | Poste à souder (Phase 4) |
   | `metal_saw` | Scie (Phase 2) |
   | `screwdriver` | Tournevis (Phase 3 + vol de plaque) |
   | `chopshop_tyre` | Pneu volé |
   | `stolen_plate` | Plaque physique volée (metadata) |
   | `fake_plate` | Fausse plaque forgée (utilisable — applique le déguisement) |
   | `gloves` | Gants — empêchent de laisser des empreintes (système d'indices) |
   | `parts_scanner` | Scanner de pièces (police) — inspecte la série des `car_parts` |

3. **Serveur**
   Ajoutez `ensure vp_chopshop` à la suite de `ox_lib`, `ox_inventory`, `ox_target`, `oxmysql`.

   **Preuves (optionnel) :** pour la couche forensique (section 7), installez la ressource [`evidences`](https://forum.cfx.re/t/free-evidence-script/5357633) et assurez son `ensure`. vp_chopshop se contente de **consommer** son API (`exports.evidences:syncEvidence`) et **se désactive automatiquement** si la ressource est absente — aucune dépendance dure. Activation/désactivation via `Config.Evidence.Enable`.

   **Hook de garage (nécessaire pour la fausse plaque sur un véhicule personnel) :** pour que la garage n'enregistre jamais la fausse plaque, ajoutez à l'endroit où elle capture les `props`/la plaque, AVANT la sauvegarde :
   ```lua
   if GetResourceState('vp_chopshop') == 'started' then
       props = exports.vp_chopshop:GetRealPlateForProps(vehicle, props)
   end
   ```
   - **QBox (qbx_garages) :** dans `server/main.lua`, dans le callback `qbx_garages:server:parkVehicle`, avant le `SaveVehicle` (bloc balisé `[vp_chopshop F3 garagem]`). ⚠️ Ré-appliquez si `qbx_garages` est mis à jour.
   - **QBCore (qb-garages) :** voir le snippet dans `installation/qb-garages-hook.md`.

4. **Permissions (ACE)**
   Pour les commandes admin (`/choplifts`, `/chopremove`) :
   ```
   add_ace group.admin command.choplifts allow
   add_ace group.admin command.chopremove allow
   ```

5. **Framework**
   Le bridge dans `bridge/server_framework.lua` détecte automatiquement **QBox (`qbx_core`)**, **QBCore (`qb-core`)** ou **ESX (`es_extended`)** par ordre de priorité. Utilisé pour `ServerPlayerIsReady`, le métier (gate policier des plaques), l'argent et le citizenid. *(Le serveur LIVE est QBox ; QBCore est supporté pour la portabilité mais non testé dans cet environnement.)*

---

## Configuration (`shared/config.lua`)

### Vol de plaques et fausses plaques (`Config.Plates`)

| Clé | Description |
|-------|-----------|
| `Enable` | Active/désactive toute la fonctionnalité de plaques |
| `MaxDistance` / `ApplyMaxDistance` | Distance max. (server-side) pour voler / appliquer |
| `StealCooldownSeconds` | Cooldown anti-farm de vol par joueur |
| `SkillCheck` | Mini-jeu lors de l'arrachage de la plaque (`{ difficulties, keys }` de `lib.skillCheck`) |
| `ToolItem` | Objet requis pour voler (par défaut `screwdriver`) |
| `ForgeTier` | Confiance minimale chez le receleur pour forger une fausse plaque (par défaut 2) |
| `ForgeInputs` | Matériaux de la forge (ex. : `{ plastic = 2, aluminum = 1 }`) |
| `Persist` | Persistance totale du déguisement (ré-appliqué au spawn, survit aux redémarrages) |
| `PoliceJobs` | Métiers pouvant retirer la fausse plaque (ex. : `{ 'police','bcso','sheriff' }`) |
| `Witness` | Dispatch selon les témoins : `{ Radius, NpcWeight, PlayerWeight, BaseChance, MaxChance, NightModifier, BonusMinScore, BonusXp, BonusCashMax }` |

### Indices forensiques / Preuves (`Config.Evidence`)

Intégration optionnelle avec la ressource `evidences`. Se désactive automatiquement si elle ne tourne pas.

| Clé | Description |
|-------|-----------|
| `Enable` | Active/désactive la couche forensique |
| `GlovesItem` | Objet qui bloque les empreintes (par défaut `gloves`) |
| `GlovesBlocksDna` | Si `true`, les gants bloquent aussi l'ADN (par défaut `false` — l'ADN tombe quand même) |
| `DnaType` | Type d'ADN laissé : `'blood'` ou `'saliva'` |
| `HeatScaling` / `HeatFactor` | Plus de heat sur la plaque → plus de chance d'indice (`chance × (1 + heat/100 × HeatFactor)`) |
| `Actions` | Chance de base (0..1) d'**empreinte** et d'**ADN** par action : `chop_part`, `vin_scratch`, `plate_steal`, `plate_forge`, `plate_apply` |

### Traces de pneus (`Config.TyreMarks`)

| Clé | Description |
|-------|-----------|
| `Enable` | Active/désactive les traces de pneus |
| `ArmWindowSeconds` | Fenêtre après le crime durant laquelle faire crisser les pneus laisse une trace (~45) |
| `MarkTTLSeconds` | Durée de vie de la trace avant qu'elle ne disparaisse (~600) |
| `MaxMarksPerCrime` | Nombre max. de traces par fenêtre de crime |
| `ExamineDistance` | Distance pour que la police examine |
| `Burnout` | Seuils de détection : `{ Ratio, MinWheelSpeed, MaxRealSpeed, CooldownMs }` (à calibrer en jeu) |
| `PoliceJobs` | Métiers pouvant examiner |
| `ClassNames` | Correspondance des classes GTA (0..22) → nom |

### Numéro de série des pièces (`Config.PartSerial`)

| Clé | Description |
|-------|-----------|
| `Enable` | Active/désactive le système de série sur `car_parts` |
| `ScratchTier` / `ForgeTier` | Palier de progression pour rayer (moyen) et forger (max) |
| `ForgeInputs` | Matériaux consommés à la forge (ex. : `{ plastic = 2, aluminum = 1 }`) |
| `LegalVendor` | Vendeur de pièces légales : `{ Enable, Coords, Model, Price, Amount }` |
| `PoliceJobs` | Métiers pouvant inspecter les pièces |
| `ScannerItem` / `ForensicItem` | Objets : scanner de la police (`parts_scanner`) et kit d'expertise (`forensic_kit`) |

> Le détail complet des autres clés de configuration (désmantèlement, alarme, receleur, progression, etc.) se trouve dans les versions [PT](README_pt.md) / [EN](README_en.md).

---

## Compatibilité avec les frameworks

Le script **ne dépend d'aucun framework** pour la logique principale — l'inventaire repose uniquement sur **ox_inventory**. Le bridge dans `bridge/server_framework.lua` détecte le framework automatiquement et l'utilise pour le statut du joueur, le métier (gate policier du retrait de fausse plaque), l'argent (boutique du PNJ et bonus des plaques).

| Framework | Support |
|-----------|---------|
| QBox (`qbx_core`) | Complet — exports directs (`GetPlayer`, `AddMoney`, `job.name`) |
| QBCore (`qb-core`) | Supporté (portabilité — `GetCoreObject`/`Functions.GetPlayer`) ; non testé dans cet environnement |
| ESX Legacy (`es_extended`) | Complet — utilise `GetPlayerFromId`, `GetPlayers`, `xPlayer.job.name` |
| Aucun | Fonctionnel (boutique PNJ et bonus en argent désactivés) |

---

## Version

`1.13.2` — définie dans `fxmanifest.lua`. Historique complet dans [`CHANGELOG.md`](CHANGELOG.md).

> **v1.7.0–1.13.2 :** audit (nettoyage/sécurité/performance), récompense immédiate + embuscade,
> le **système complet de plaques** (vol physique → forge → fausse plaque qui trompe le MDT,
> persistante et avec réversion en garage ; dispatch selon les témoins ; support QBox/QBCore/ESX),
> la **couche forensique** (indices d'empreinte/ADN par action, avec gants et échelle selon le heat,
> via intégration optionnelle avec la ressource `evidences`),
> les **traces de pneus** (indice de fuite par modèle de véhicule, sans plaque),
> et la **série des pièces** (`car_parts` volée/rayée/forgée/légale, avec expertise de la police).
