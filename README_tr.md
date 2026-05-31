# vp_chopshop

FiveM için **Araba Parçalama** (Chop Shop) sistemi: Oyuncu, herhangi bir aracı kaldırmak ve parçaları 4 aşamalı olarak sökmek için **kriko** (`chopshop_jackstand`) kullanır. İşlem sonunda malzeme, NPC'ye lastik satışı ve isteğe bağlı baskın görevleri bulunur. **ox_lib**, **ox_target**, **ox_inventory** ve **oxmysql** ile en iyi uyumluluğu sağlamak için tasarlanmıştır.

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

---

## Kurulum (Installation)

1. **Veritabanı Ayarı**
   Hemen, `sql/vp_chopshop.sql` uzantısını sunucunuza çalıştırınız. 

2. **Gerekli Envanter (ox_inventory)**
   `installation/ox_items_snippet.txt` içerisindeki eşyaları `ox_inventory/data/items.lua` yapıştırın. Liste sırasıyla:
   `chopshop_jackstand`, `chopshop_bench`, `chopshop_welder`, `metal_saw`, `screwdriver` ve `chopshop_tyre` olmalıdır.

3. **Sunucu Çekirdeği Ekleme**
   Kapsayıcı eklentilerden (oxlib, oxtarget vb.) sonraya gelecek şekilde `ensure vp_chopshop` yazısı bırakınız.

4. **Framework**
   **ESX gereklidir** (`es_extended`). Kodlama, oyuncu hazır kontrolü ve NPC para işlemleri için ESX kullanır.
