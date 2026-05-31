# vp_chopshop

Système de **casse automobile** (chop shop) pour FiveM : le joueur utilise un **cric mécanique** (`chopshop_jackstand`) pour soulever n'importe quel véhicule et démonter les pièces en 4 phases progressives, en obtenant des récompenses matérielles, la vente de pneus à un PNJ et des embuscades optionnelles. Conçu pour être utilisé avec **ox_lib**, **ox_target**, **ox_inventory** et **oxmysql**.

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

---

## Installation

1. **Base de données**
   Exécutez `sql/vp_chopshop.sql` (crée les 6 tables).

2. **Objets (ox_inventory)**
   Copiez les blocs de `installation/ox_items_snippet.txt` dans `ox_inventory/data/items.lua`. Objets requis :
   
   - `chopshop_jackstand` (Cric)
   - `chopshop_bench` (Établi)
   - `chopshop_welder` (Poste à souder)
   - `metal_saw` (Scie)
   - `screwdriver` (Tournevis)
   - `chopshop_tyre` (Pneu volé)

3. **Serveur**
   Ajoutez `ensure vp_chopshop` à la suite de `ox_lib`, `ox_inventory`, `ox_target`, `oxmysql`.

4. **Permissions (ACE)**
   Pour l'utilisation des commandes (administration) :
   ```
   add_ace group.admin command.choplifts allow
   add_ace group.admin command.chopremove allow
   ```

5. **Framework**
   Requiert **ESX** (`es_extended`).
