# AI raporlarının doğrulanmış claim review'u

Tarih: 2026-09-08. Bu belge yalnız kaynak ve elde edilen CI kanıtının desteklediği sonucu yazar. Aynı kök nedenin tekrarları ayrı açık sayılmaz; stil, bakım borcu veya teorik özellik eksikliği otomatik güvenlik açığı değildir.

## Kaynakta doğrulanan ve bu branch'te düzeltilenler

| İddia | Doğrulama | Güncel sınıflandırma |
|---|---|---|
| Native noauth/HTTP fallback | Eski XrayCoreManager güvenli ingress'i native sınırda zorlamıyordu | **Düzeltildi.** Tek authenticated loopback SOCKS5 ingress; eksik/fazla/noauth/HTTP/malformed listener reddediliyor |
| Kotlin regression CI'da kanıtlanmıyor | Eski workflow native suite'i yürütmüyordu | **Düzeltildi.** `testDebugUnitTest` + JUnit XML evidence gate; gerekli suite/test sayıları zorunlu |
| Per-session config kısa süre diskte | Eski `writeText(config.json) -> Xray -> delete` yolu vardı | **Düzeltildi source-level.** Bounded stdin/EOF aktarımı; legacy plaintext file silinemiyorsa fail-closed. Packaged binary/device kabulü ayrıca bekliyor |
| Port bind-close-rebind TOCTOU | SecureSocksSession önce portu bind edip bırakıyor, Xray sonra yeniden bind ediyordu | **Düzeltildi.** Sahte rezervasyon kaldırıldı; Xray ilk gerçek bind sahibi, collision bounded retry ile ele alınıyor |
| `getCoreVersion` bounded değil | Native worker `readLine()` ile sınırsız bekleyebiliyordu | **Düzeltildi + 5 regression testi geçti** (run 34272027097) |
| Token yokken `stopVless` success | Bridge aktif runtime yokluğunu kanıtlamadan başarı dönebiliyordu | **Düzeltildi source-level.** QUERY_STATE + generation-scoped stop/ack; cihaz lifecycle kabulü bekliyor |
| Runtime status receiver Activity ömrüne bağlı | Erken status/adoption event'i kaçabilirdi | **Düzeltildi source-level.** Receiver engine/application scope'a taşındı |
| `errorMessage` kullanıcıya görünmüyor | Getter vardı fakat gerçek error UI yolu zayıftı | **Düzeltildi source-level.** Status bar error state/message tüketiyor; cihaz/UI kabulü bekliyor |
| Timer normal connect'te çift başlayabilir | native CONNECTED listener ve button success zinciri aynı session clock'u başlatabiliyordu | **Düzeltildi source-level.** Resume yalnız adopted/synced runtime için; normal yeni session tek start kapısından geçiyor |
| Unconfirmed native stop'ta session state siliniyor | Tünel yaşarken timer/state ölebilirdi | **Düzeltildi source-level.** Stop kanıtlanmazsa server-derived state/timer/sync korunuyor |
| LocalSocksTester UDP doğrulamıyor | Yalnız auth/TCP CONNECT vardı | **Düzeltildi kısmen.** Authenticated SOCKS `UDP ASSOCIATE` var. Bu internet UDP roundtrip/Discord kanıtı değildir |
| Native UDP ingress kontratı gevşek | SOCKS UDP flag/relay bind native validator'da ayrı güvence değildi | **Düzeltildi.** `udp=true` ve `ip=127.0.0.1` zorunlu; positive/negative Kotlin coverage var |
| Xray startup worker thread'e taşınınca timer Looper riski | Hardening sırasında `CountDownTimer` worker thread'den oluşturulabilir hale geldi | **Branch içi regression bulundu ve düzeltildi.** Lazy main-looper Handler ticker kullanılıyor |
| Stale Xray stop yeni generation token'ıyla DISCONNECTED yayınlayabilir | Caller confirmation token'ı gerçek core ownership'inden farklı olabilirdi | **Düzeltildi.** Owned runtime token caller token'dan öncelikli; 3 RuntimeGenerationTest eklendi |
| tun2socks build mutable HEAD'den yapılabilir | Build script repo'yu `git pull` edip o anki HEAD'i derliyordu | **Gerçek provenance zayıflığı; düzeltildi.** Exact commit zorunlu |
| Xray source build yalnız mutable ref semantiğine güveniyordu | Tag checkout vardı, exact expected commit doğrulaması yoktu | **Sertleştirildi.** v26.7.11 commit `50231eaff98ccc31b5cbd247a721c16e97fe5ec1` pinli |
| Control-plane helper herhangi URI'yi gönderebilir | Current call sites configured API'den türetiliyor olsa da ortak helper scheme/origin zorlamıyordu | **Hardening boundary eklendi.** Yalnız configured HTTPS same-origin URI kabul; redirect kapalı kalıyor. Mevcut exploit kanıtı değildir |

## Doğrulanmış fakat henüz tam kapanmamış maddeler

| İddia | Doğru sınır |
|---|---|
| Always-on kapalı | **Doğru eksik özellik.** Fakat yalnız `SUPPORTS_ALWAYS_ON=true` yapmak güvenli fix değildir. Protected bootstrap/socket-loop/reboot/expiry semantics olmadan false kalması doğru |
| APK provenance eksik | Source→APK→signing cert→native SO→workflow attestation pipeline hazır, fakat production secret/keystore ile gerçek run ve tüketici doğrulaması henüz yok |
| UDP/DNS/IPv6 uçtan uca doğrulanmadı | Source route/ingress/UDP ASSOCIATE var; gerçek Android e2e hâlâ cihaz testine bağlı |
| Backend session/status/revoke/quota yetkilendirmesi | Client branch production backend davranışını kanıtlamaz; gerçek deployment/server repo doğrulaması gerekir |
| Privacy retention/no-logs iddiaları | Client kodu bunları tek başına kanıtlayamaz; deployment/logging/retention kanıtı gerekir |

## Yanlış veya aşırı kesin çıkarımlar

| Rapor ifadesi | Düzeltme |
|---|---|
| Sabit storage key başka app ile çakışır | Android app data alanları yalnız key adına göre paylaşılmaz |
| Sabit notification ID kritik açık | Notification kimliği paket/UID bağlamındadır; random ID güvenlik sınırı değildir |
| Await olmayan Dart check/set otomatik thread race'tir | Dart isolate/event-loop modeli altında somut await/reentrancy/callback sınırı gösterilmelidir |
| Local path dependency başlı başına supply-chain açığıdır | Vendoring denetlenebilir; gerçek konu provenance, exact source ve build integrity'dir |
| Kotlin notification text buffer overflow yapar | Bu kaynak memory corruption kanıtı vermiyor |
| SOCKS auth reddinde noauth fallback olmaması açıktır | Tam tersi, fail-closed beklenen davranıştır |
| Her port 49152–65535 olmalı | Güvenlik gereği değildir; önemli olan listener ownership/collision davranışıdır |
| `as String?` yanlış tipi String'e çevirir | Null'a izin verir; yanlış runtime tipi yine cast hatasıdır |
| Aynı User-Agent bireysel tracking kanıtıdır | Ortak UA benzersiz kullanıcı kimliği değildir |
| Play Integrity/root/emulator kontrolü yoksa kritik açıktır | Tek başına güvenlik açığı değildir; server authz yerine geçmez |
| `::/0` route varsa IPv6 kesin güvenlidir | Route yalnız yakalama niyetini gösterir; relay/DNS/leak e2e test gerekir |
| IP pin varsa control-plane compromise sadece DoS'tur | Tunnel destination pin ayrı trust boundary'dir; API/session control-plane etkileri ayrıca değerlendirilmelidir |
| Config SHA pin CI compromise'ı imkânsız yapar | Hash/check aynı trust domain içinde değiştirilebiliyorsa mutlak garanti değildir |
| Nonce var diye replay server-side kesin kapalıdır | Server nonce issuance/consumption/expiry davranışı ayrıca doğrulanmalıdır |
| Kullanıcı CA otomatik TLS MITM yapar | Android trust config/target SDK ve endpoint davranışı incelenmeden kesin söylenemez |
| `extractNativeLibs=false` root'a karşı değişmezlik sağlar | Root tehdit modelini çözmez |
| `debugPrint` release'te kesin stripped | Build/toolchain davranışı incelenmeden genel garanti değildir |
| Public/static Dart method kesin tree-shaking'de kalır | Reachability ve compiler davranışı belirleyicidir |
| Server kapalı kaynaksa client kötü niyetlidir | Böyle bir sonuç kaynak modelinden çıkarılamaz |
| Rust SQLite kullanılıyor diye bu client'ın privacy policy'si otomatik yanlıştır | Hangi backend'in production'da dağıtıldığı kanıtlanmalıdır |
| Current SOCKS tüm uygulamaları transparent yakalar | Bu upstream 3.3.5 hattında proxy-only modu vardır; eski transparent branch bilgisi bu tabana taşınamaz |
| `_expectedNonce` static olduğu için session hijacking kesindir | Call generation/cancel/event sırası birlikte incelenmelidir |
| `SUPPORTS_ALWAYS_ON=true` tek başına kill-switch fixidir | **Yanlış ve mevcut mimaride riskli.** App exclusion/control-plane bootstrap ve child-process socket loop çözülmeden self-deadlock/yanlış güven vaadi doğurabilir |
| UDP ASSOCIATE geçtiyse Discord kesin çalışır | Yanlış. SOCKS control path başarısı TUN→tun2socks→Xray→server→public UDP e2e kanıtı değildir |

## CI ile doğrulanan somut sonuçlar

Run `34272027097`, SHA `55e619c`:

- `flutter analyze`: PASS.
- `flutter test`: 4/4 PASS.
- Kotlin compile: PASS.
- VersionProbeTest: 5/5 PASS.
- CoreConfigPipeTest: 3/3 PASS.
- Native malformed/invalid ingress negative testleri PASS.
- İki valid Xray fixture testi, yeni UDP kontratı fixture'a eklenmediği için FAIL etti; production source failure'ı değil test drift'i. `2be59fc` ile düzeltildi.

En yeni head `6543dcb` için run `34272733143` bu belge güncellenirken queued; aynı SHA için rerun yapılmadı.

## Kapsam dışı / kanıt bekleyenler

- AdMob bypass, issuance, consent ve support ödül semantiği kullanıcı talebiyle bu seride değiştirilmez.
- Production backend authorization/replay/revoke/retention/quota enforcement ayrıca doğrulanmalı.
- Gerçek Android cihazda Wi-Fi/LTE, IPv4/IPv6, DNS/Private DNS, UDP, crash recovery, reboot, lockdown, Discord/WebRTC/QUIC kabulü yapılmalı.
- Production signed APK attestation workflow gerçek secrets ile çalıştırılmalı ve bağımsız doğrulayıcıyla tüketilmeli.
- "Tüm açıklar kapalı", "tamamen güvenli", "80 bulgunun hepsi gerçek" veya "hiç dead code yok" gibi mutlak sonuçlar mevcut kanıtı aşar.
