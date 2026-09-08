# AI raporlarının ön doğrulaması

Bu, gönderilen uzun raporların tamamının doğrulandığı anlamına gelmez. Aynı kök nedenin tekrarları ayrı açık sayılmaz. İstismar rehberi veya canlı hedef testleri bu çalışmanın kapsamında değildir.

## Kaynakta doğrulananlar

| İddia | Kaynak/kanıt | Doğru sınıflandırma |
|---|---|---|
| Native noauth/HTTP fallback | Taban XrayCoreManager.buildRuntimeConfigJson | Savunma sınırı eksikliği; normal Dart akışı authenticated ingress üretse de native kendi koşulunu zorlamıyordu. Bu branch reddediyor |
| Kotlin regression CI'da yok | android-ci.yml sadece flutter test, lint ve build çağırıyordu | Test kapsamı eksikliği; görev eklendi, geçtiği henüz kanıtlanmadı |
| config kısa süre diskte | startCore: writeText -> process start -> sleep -> delete | Doğru; app-private dosya, sıradan başka uygulamaya doğrudan erişim kanıtı değil. Hâlâ açık |
| Port bind-close-rebind | SecureSocksSession.create | Doğru kaynak penceresi; etkisi cihaz/runtime koşullarına bağlı. Auth varlığı port sahipliğini kriptografik doğrulamaz |
| Always-on kapalı | Native manifest + onStartCommand | Doğru eksik özellik; AlarmManager onun yerine geçmez |
| Delay subsystem kullanılmıyor | Repo çapında çağrı taraması ve plugin method switch | Bakım borcu; kaldırıldı. Ölü fonksiyondaki hata normal aktif akış açığı diye sunulamaz |
| NetworkSnapshot cast hatası | NetworkSnapshot.fromMap | Hatalı native metadata için robustness bug; nullable cast yanlış tipi kabul etmez. Yama eklendi |
| getCoreVersion bounded değil | Plugin executor içinde readLine | Koşullu kullanılabilirlik sorunu; askıda binary için koruma eksik. Henüz yamalanmadı |
| stopVless token yokken success | Plugin stopVless | Kaynak davranışı doğrulandı; kullanıcıdan erişilebilir hayalet VPN zinciri için event/cihaz kanıtı henüz yok |
| errorMessage çizilmiyor | VpnConnection getter, UI tüketicisi bulunamadı | UI hata görünürlüğü sorunu; henüz yamalanmadı |
| LocalSocksTester UDP doğrulamıyor | test akışı TCP CONNECT | Test eksikliği; UDP'nin bozuk olduğunun kanıtı değil |

## Yanlış veya aşırı kesin çıkarımlar

| Rapor ifadesi | Düzeltme |
|---|---|
| Sabit storage key başka app ile çakışır | Android uygulama veri alanları yalnız key adına göre paylaşılmaz |
| Sabit notification ID kritik açık | Bildirimler paket/UID bağlamlıdır; random ID güvenlik sınırı sağlamaz |
| await olmayan Dart check/set yarışı | Aynı isolate/event loop içinde böyle bir otomatik thread yarışı yok; await/reentrancy/callback sınırı gösterilmeli |
| Local path dependency override başlı başına supply-chain açık | Vendoring denetlenebilir kaynak olabilir; provenance/hash/build zinciri değerlendirilir |
| Kotlin notification text buffer overflow | Bu koddan native memory corruption çıkarılamaz |
| SOCKS auth reddinde noauth fallback olmaması açık | Reddetmek beklenen fail-closed davranıştır |
| Her port 49152–65535 aralığında olmalı | Güvenlik gereği değildir; OS ephemeral aralığı platforma bağlıdır |
| as String? yanlış tip hatasını düzeltir | Null'a izin verir; int -> String dönüşümü yine hata verir |
| Aynı UA bireysel kullanıcı tracking kanıtı | Ortak istemci imzası bireysel benzersiz kimlik değildir |
| Play Integrity/root/emulator kontrolü yok => kritik açık | Tek başına açık değildir; sunucu yetkilendirmesinin yerine geçmez |
| ::/0 var => uçtan uca IPv6 kesin çalışır | Route yakalama, relay ve DNS başarısını tek başına kanıtlamaz |
| IP pin => API compromise yalnız DoS | Tünel hedefi sabitliği control-plane gizliliği/yetkilendirmesi için aynı garanti değildir |
| Config SHA pin => CI compromise imkânsız | Hash ve build doğrulama adımı aynı güven alanında değiştirilebiliyorsa mutlak garanti yok |
| Nonce eklendi => server replay kesin kapalı | Sunucunun nonce kabul/tüketim kuralları ayrıca doğrulanmalı |
| Kullanıcı CA otomatik TLS MITM yapar | Android sürümü, target SDK ve uygulamanın trust config'i incelenmeden söylenemez |
| SO extractNativeLibs=false root'a karşı değişmezlik sağlar | Root tehdit modelini böyle çözmez |
| debugPrint release'te zorunlu stripped | Bu kesin bir genel garanti değildir; logging çağrısı ve build davranışı incelenmeli |
| Her public/static Dart method tree-shaking'de tutulur | Erişilebilirlik ve derleyici davranışı önemlidir; public olmak tek başına kanıt değil |
| Server kapalı kaynak => client kötü niyetli | Kanıtlanamaz. Aynı şekilde client kodu server'ın no-logs iddiasını kanıtlamaz |
| Rust SQLite => bu upstream privacy policy kesin yanlış | Önce hangi backend'in dağıtıldığı doğrulanmalı; ayrı repo otomatik production kanıtı değildir |
| Current SOCKS tüm uygulamaları yakalar | Bu upstream'de proxyOnly modu mevcut. Eski transparent branch bilgisi yanlış tabana taşınmış |
| Static _expectedNonce => session hijacking kesin | _currentCallId/cancel ve event sırası hesaba katılmadan söylenemez |

## Kapsam dışı ve kanıt bekleyenler

- AdMob bypass, gerçek reklam issuance/consent/support davranışı kullanıcı talebiyle korunur.
- Server session/status yetkilendirmesi, revoke, retention ve quota enforcement: backend/deployment kanıtı bekliyor.
- APK source provenance: release metadata'sı okundu; tam binary ve imza/attestation zinciri doğrulanmadı.
- Timer/stop/reconnect iddialarının tamamı, nonce format uyumluluğu, DNS leak, notification yarışları, boot timeout ve lifecycle etkileri için ayrı davranış kanıtı gerekli.
- "80 bulgunun hepsi gerçek", "hiç dead code yok", "tamamen güvenli" ve "bilinçli sabotaj yoktur" gibi kapsamlı kesin sonuçlar bu incelemenin kanıtını aşar.
