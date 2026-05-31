# vp_chopshop

FiveM için **Araba Parçalama** (Chop Shop) sistemi: Oyuncu, herhangi bir aracı kaldırmak ve parçaları 4 aşamalı olarak sökmek için **kriko** (`chopshop_jackstand`) kullanır. İşlem malzeme, dönüşümlü bir alıcı NPC'ye (fence) lastik satışı, isteğe bağlı baskınlar, **tam bir plaka sistemi** (fiziksel plaka çalma, MDT'yi kandıran sahte plaka, kalıcılık ve tanık bazlı ihbar) ve bir **adli katman** (polisin topladığı parmak izi/DNA izleri) sunar. **ox_lib**, **ox_target**, **ox_inventory** ve **oxmysql** ile en iyi uyumluluk için tasarlanmıştır — **QBox / QBCore / ESX** framework'leri.

---

## Zorunlu Gereksinimler

| Kaynak | Kullanım |
|---------|-----|
| `ox_lib` | Menüler, ilerleme çubukları, mini-oyunlar (skillcheck) vb. |
| `ox_target` | Kaldırılmış araçtaki etkileşim noktaları, masa, kaynak makinesi ve NPC |
| `ox_inventory` | Eşya yönetimi, materyal ekleyip çıkarma |
| `oxmysql` | Kaynak makineleri ve tezgahların veri tabanına kaydedilmesi |

`server.cfg` içerisindeki kurulum sırası: ox eklentileri (önce), ondan sonra `ensure vp_chopshop`.

---

## Dil (Arayüz)

Dil ayarını değiştirmek için `shared/config.lua` dosyasında **`Config.Locale`** içine şu değerlerden birini girin:

| Değer | Dil |
|-------|--------|
| `en` | English |
| `pt` | Português (varsayılan) |
| `es` | Español |
| `fr` | Français |
| `tr` | Türkçe |

Yazı alanları `shared/locale.lua` içindedir. Yeni ve özel üretim(craft) ayarlamak isterseniz, varolan `labelKey`'i kullanabilir veya çeviri dışı sabit yazı olarak eski tür `label`'i seçebilirsiniz.

`ox_inventory`'deki eşyaların adları bağımsız yürütülmektedir; özel isim vermek isterseniz `items.lua` içerisinden düzeltiniz (`installation/ox_items_snippet.txt`).

---

## Nasıl Çalışır (Oyuncu Gözünden)

### 1. Hidrolik Kriko — Ana Araç

- Araca yaklaştıktan sonra, envanterden **Kriko** (`chopshop_jackstand`) aracını kullanın.
- "Kriko yerleştiriliyor" ilerleme periyodundan sonra (~8 sn), araç havaya çıkar.
- Araç havada iken, `ox_target` eklentisine bağlı olarak araçta **sökülecek noktalar** belirir.
- **Aracı geri indirmek için**: Araçtaki "Krikoları Çıkar" hedefini(target) kullanın.

### 2. Parçalama Aşamaları (kriko haricindeki aletler)

| Aşama | Sökülen Parçalar | Ekstra Alet Gerekli mi | Kullanım Başına Ödül |
|------|-------|-----------------|------------|
| **1 — Temel** | Kaput, bagaj, lastikler, kapılar | — | `Config.CarPartRewards` içindeki yapılandırma baz alınır |
| **2 — Gövde** | Kapılar / kaput / bagaj | Testere (`metal_saw`) | Parça başına `car_parts` |
| **3 — Motor** | Motor | Tornavida (`screwdriver`) | 5× `car_parts` |
| **4 — Kasa (İskelet)** | Kasa | Aracın hemen yanında duran bir kaynak makinesi | Şansa dayalı geri dönüştürülebilir yapıdaki materyaller |

> **3. Aşama** motor sökmeye yaramaktadır ancak öncesinde Aşama 2 gereği kaput sökülmelidir.
> **4. Aşama** aracın tamamını eritmeye yaramaktadır. Öncesinde motor sökülmeli, ardından bölgeye limit olarak tanımlanan çap (`Config.AdvancedChop.WelderRadius`) dışarısına çıkmayacak şekilde kaynak makinesi eklenmelidir.

### 3. Aracın Atılması (Eritme ve çöpe çevirme)

Belirlenen sayıda parçayı (`Config.Discard.MinPartsToDiscard`) söktükten sonra, "Aracı Yok Et" özelliği belirir (target olarak). Aracı yok eden oyuncu `DefaultPayout` tabanlı bir nakit paraya layık görülür. `CopsBonus.Enable` seçeneği varsa ve oyunda çokça polis varsa para çarpan şeklinde oyuncuya katlanarak ulaşır.

### 4. Üretim Tezgahı (`chopshop_bench`)

- Crafthouse masası eklemek için **Workbench** adlı objeyi yerleştirin.
- Üretim şeması kuralları (`Config.BenchRecipes`) dahilinde şekillenir (ürün harcaması/girdiği süresi).
- **Aşama 4** işini halledebilmek için tezgah yakınlarında kaynak aracı elzemdir.

### 5. Lastikler — Satış Macerası

- **Direkt Satış Aşaması**: Krikoyla lastikleri söktükten sonra → bir araç bagajına ekleyin (kamyonete misal) → alıcı olan NPC karakterine gidin → anında ücret ödensin (`Config.TyreSelling.PricePerTyre`).
- **Sözleşmeli Lastik Görevleri** (`Config.TyreMission`): NPC ile doğrudan olan ikili diyalog sözleşme başlatır → rastgele spawnlanan aracı bulmanız istenir → cıvata mini-game oynayarak 4 lastiği yürütün → NPC teslimatı sonucunda görev bitirme ücreti tarafınıza bonus ile tahsil edilir.

### 6. Plaka Çalma ve Sahte Plakalar (`Config.Plates`)

Aracı suça bağlayan şey plakadır; bu sistem heat/MDT mekaniğine doğrudan bağlıdır.

- **Fiziksel plaka çalma**: Tornavida (`screwdriver`) ile hedef bir aracı nişanlayın (ox_target "Plakayı sök") → skillcheck → `stolen_plate` eşyasını alırsınız (orijinal plaka eşyanın metadata'sında saklanır). Araç **görünür plakasız** kalır. Bu eşya fence'e satılabilir ya da sahte plaka üretmek için girdi olur.
  - **Tanık bazlı ihbar**: Plaka çalmak polisi otomatik olarak çağırmaz. İhbar şansı **yakındaki NPC ve oyuncu** sayısıyla orantılıdır (gece çarpanı uygulanır) — gecenin köründe ıssız bir bölgede neredeyse hiç çağırmaz, kalabalık bir bölge daha sık çağırır. **Tanıkların önünde** plaka çalmak ise bir **risk bonusu** kazandırır (XP/para, sunucu tarafında sınırlandırılmıştır).
- **Sahte plaka üretme**: Tezgâhta (güven **kademe 2**), bir `stolen_plate` + girdiler (`plastic` + `aluminum`) harcanarak `fake_plate` eşyası üretilir (çalınan plakanın değerini devralır).
- **Sahte plaka uygulama** (`fake_plate` eşyasını kullanmak): Aracın görünür plakasını değiştirir ve **MDT plaka sorgusunu kandırır** — sorgu yapan kişi "temiz" sahte plakayı görür ve geçmiş gizlenmiş olur.
  - **Heat GERÇEK plakayı takip eder**: Kılık polisi kandırır, ama suç gerçek araç üzerinde birikmeye devam eder. Sahte plaka **heat temizlemez** (bu VIN kazımanın işidir).
  - **Tam kalıcılık**: Kılık, sunucu yeniden başlatmaya dayanır ve araç yeniden oluştuğunda (spawn) tekrar uygulanır.
  - **Garaj güvenli**: Kılıklı bir aracı garaja koymak **sahte plakayı asla veritabanına kaydetmez** (kaydetmeden önce gerçek plakaya döndürülür); kılık bir sonraki spawn'da geri gelir. Garaj hook'u gerektirir (bkz. Kurulum).
- **Sahte plaka kaldırma** (polis): `Config.Plates.PoliceJobs` içindeki meslekler, kılığı bozup gerçek plakayı geri getirmek için bir ox_target'a sahiptir.

### 7. Adli izler / Kanıtlar (`Config.Evidence`)

[`evidences`](https://forum.cfx.re/t/free-evidence-script/5357633) kaynağına bağlı bir **adli katman** — heat/MDT'nin üstünde çalışarak suçu gerçekten izlenebilir kılar.

- **Her suç eylemi suçluya bağlı bir iz bırakır**: parça sökme, VIN kazıma, plaka çalma, sahte plaka üretme ve uygulama.
- **Türler:** **parmak izi** (dijital, yüksek şans) + **DNA** (kan, düşük şans — "kesik/ter").
- **Karşı oyun (counterplay) — eldiven:** envanterde **`gloves`** (eldiven) eşyasının bulunması **parmak izlerini engeller**; ama DNA yine de düşebilir (asla %100 güvende değilsiniz). Taktiksel karar: temiz ve hazırlıklı mı gitmek, yoksa hızlı ve riskli mi.
- **Heat ile ölçeklenir:** daha "sıcak" bir araç (super, yeni çalınmış, çok parçası sökülmüş) **daha çok iz** bırakır. Aceleyle çalışmak = daha çok risk.
- **Polis toplar:** `evidences` kiti ile izleri toplar ve script biyometriyle **faili tespit eder** — suçlu kaçabilir, ama olay yeri onu ele verir.
- **Opsiyonel ve güvenli:** `evidences` kaynağı çalışmıyorsa özellik **otomatik devre dışı** kalır ve sökmeyi etkilemez (`Config.Evidence.Enable` ile de açılıp kapatılır).

---

## Kurulum (Installation)

1. **Veritabanı**
   `sql/vp_chopshop.sql` dosyasını çalıştırın (7 tablonun tamamını oluşturur: `vp_chopshop_benches`, `vp_chopshop_welders`, `vp_chop_vin_scratched`, `vp_chop_fence_trust`, `vp_chop_fence_orders`, `vp_chop_progression`, `vp_chop_fake_plates`). Tablolar açılışta (boot) otomatik olarak da oluşturulur/taşınır (idempotent).

2. **Eşyalar (ox_inventory)**
   `installation/ox_items_snippet.txt` içerisindeki blokları `ox_inventory/data/items.lua` dosyasına kopyalayın. Gerekli eşyalar:

   | Eşya | Kullanım |
   |------|----------|
   | `chopshop_jackstand` | Kriko — ana araç |
   | `chopshop_bench` | Üretim tezgâhı |
   | `chopshop_welder` | Kaynak makinesi (Aşama 4) |
   | `metal_saw` | Testere (Aşama 2) |
   | `screwdriver` | Tornavida (Aşama 3 + plaka çalma) |
   | `chopshop_tyre` | Çalınan lastik |
   | `stolen_plate` | Çalınan fiziksel plaka (metadata) |
   | `fake_plate` | Üretilmiş sahte plaka (kullanılabilir — kılığı uygular) |
   | `gloves` | Eldiven — parmak izi bırakmayı engeller (kanıt sistemi) |

3. **Sunucu**
   `ox_lib`, `ox_inventory`, `ox_target`, `oxmysql`'den sonra gelecek şekilde `ensure vp_chopshop` ekleyin.

   **Kanıtlar (opsiyonel):** adli katman (bölüm 7) için [`evidences`](https://forum.cfx.re/t/free-evidence-script/5357633) kaynağını kurun ve onu `ensure` edin. vp_chopshop yalnızca API'sini **kullanır** (`exports.evidences:syncEvidence`) ve kaynak mevcut değilse **otomatik devre dışı** kalır — katı bir bağımlılık yoktur. `Config.Evidence.Enable` ile açıp kapatın.

   **Garaj hook'u (kendi aracında sahte plaka için gerekli):** Garajın sahte plakayı asla kaydetmemesi için, garajın `props`/plakayı kaydetmeden önce yakaladığı yere, save'den ÖNCE şunu ekleyin:
   ```lua
   if GetResourceState('vp_chopshop') == 'started' then
       props = exports.vp_chopshop:GetRealPlateForProps(vehicle, props)
   end
   ```
   - **QBox (qbx_garages):** `server/main.lua` içinde, `qbx_garages:server:parkVehicle` callback'inde, `SaveVehicle`'dan önce (`[vp_chopshop F3 garagem]` etiketli blok). ⚠️ qbx_garages güncellenirse yeniden uygulayın.
   - **QBCore (qb-garages):** snippet için bkz. `installation/qb-garages-hook.md`.

4. **İzinler (ACE)**
   Admin komutları (`/choplifts`, `/chopremove`) için şunları ekleyin:
   ```
   add_ace group.admin command.choplifts allow
   add_ace group.admin command.chopremove allow
   ```

5. **Framework**
   `bridge/server_framework.lua` içindeki bridge, öncelik sırasına göre **QBox (`qbx_core`)**, **QBCore (`qb-core`)** veya **ESX (`es_extended`)** framework'ünü otomatik olarak algılar. Oyuncu hazır kontrolü (`ServerPlayerIsReady`), meslek (plakaların polis kontrolü), para ve citizenid için kullanılır. *(CANLI sunucu QBox'tır; QBCore taşınabilirlik için desteklenir ama bu ortamda test edilmemiştir.)*

---

## Yapılandırma (`shared/config.lua`)

### Plaka çalma ve sahte plakalar (`Config.Plates`)

| Anahtar | Açıklama |
|---------|----------|
| `Enable` | Tüm plaka özelliğini açar/kapatır |
| `MaxDistance` / `ApplyMaxDistance` | Çalma / uygulama için maks. mesafe (sunucu tarafı) |
| `StealCooldownSeconds` | Oyuncu başına çalma için anti-farm bekleme süresi |
| `SkillCheck` | Plaka sökerken oynanan mini-oyun (`lib.skillCheck`'in `{ difficulties, keys }` değeri) |
| `ToolItem` | Çalmak için gereken eşya (varsayılan `screwdriver`) |
| `ForgeTier` | Sahte plaka üretmek için fence'te gereken minimum güven (varsayılan 2) |
| `ForgeInputs` | Üretim girdileri (örn. `{ plastic = 2, aluminum = 1 }`) |
| `Persist` | Kılığın tam kalıcılığı (spawn'da yeniden uygulanır, yeniden başlatmaya dayanır) |
| `PoliceJobs` | Sahte plakayı kaldırabilen meslekler (örn. `{ 'police','bcso','sheriff' }`) |
| `Witness` | Tanık bazlı ihbar: `{ Radius, NpcWeight, PlayerWeight, BaseChance, MaxChance, NightModifier, BonusMinScore, BonusXp, BonusCashMax }` |

### Adli izler / Kanıtlar (`Config.Evidence`)

`evidences` kaynağı ile opsiyonel entegrasyon. Kaynak çalışmıyorsa otomatik devre dışı kalır.

| Anahtar | Açıklama |
|---------|----------|
| `Enable` | Adli katmanı açar/kapatır |
| `GlovesItem` | Parmak izlerini engelleyen eşya (varsayılan `gloves`) |
| `GlovesBlocksDna` | `true` ise eldiven DNA'yı da engeller (varsayılan `false` — DNA yine de düşer) |
| `DnaType` | Bırakılan DNA türü: `'blood'` (kan) veya `'saliva'` (tükürük) |
| `HeatScaling` / `HeatFactor` | Plakada daha çok heat → daha çok iz şansı (`chance × (1 + heat/100 × HeatFactor)`) |
| `Actions` | Eylem başına **parmak izi** ve **DNA** temel şansı (0..1): `chop_part`, `vin_scratch`, `plate_steal`, `plate_forge`, `plate_apply` |

> Diğer yapılandırma bölümleri (desmanche, kriko, fence, ilerleme, alarm, baskınlar, lastikler, Discord vb.) için güncel ve eksiksiz referans olarak Portekizce README'ye (`README_pt.md`) bakın.

---

## Framework Uyumluluğu

Betik, ana mantık için **framework'e bağımlı değildir** — envanter yalnızca **ox_inventory**'dir. `bridge/server_framework.lua` içindeki bridge, framework'ü otomatik olarak algılar ve şunlar için kullanır:

- `ServerPlayerIsReady` — oyuncunun yüklenip yüklenmediğini bilmek için.
- `BridgeGetJob` / `BridgeIsPolice` — sahte plaka kaldırmanın polis kontrolü.
- `BridgeGetCash` / `BridgeRemoveCash` / `BridgeAddCash` — NPC mağazası ve plaka bonusları.

| Framework | Destek |
|-----------|--------|
| QBox (`qbx_core`) | Tam — doğrudan export'lar (`GetPlayer`, `AddMoney`, `job.name`) |
| QBCore (`qb-core`) | Destekleniyor (taşınabilirlik — `GetCoreObject`/`Functions.GetPlayer`); bu ortamda test edilmedi |
| ESX Legacy (`es_extended`) | Tam — `GetPlayerFromId`, `GetPlayers`, `xPlayer.job.name` kullanır |
| Hiçbiri | Çalışır (NPC mağazası ve nakit bonusları devre dışı) |

**Araç anahtarları:** ESX'te anahtar resource'unuzu/export'unuzu işaret etmek için `Config.VehicleKeys` kullanın. Kontrolü kapatmak isterseniz `Config.RequireVehicleKeys = false` ayarlayın.

---

## Sürüm

`1.11.0` — `fxmanifest.lua` içinde tanımlıdır. Tam geçmiş için [`CHANGELOG.md`](CHANGELOG.md) dosyasına bakın.

> **v1.7.0–1.11.0:** denetim (temizlik/güvenlik/performans), anında ödül + baskın,
> **tam plaka sistemi** (fiziksel çalma → üretim → MDT'yi kandıran sahte plaka,
> kalıcı ve garaj geri dönüşümlü; tanık bazlı ihbar; QBox/QBCore/ESX desteği),
> ve **adli katman** (eylem başına parmak izi/DNA izleri, eldiven ve heat ölçeklemesi ile,
> opsiyonel `evidences` kaynağı entegrasyonu üzerinden).
