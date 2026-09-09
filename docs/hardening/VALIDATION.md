# Validation record — 2026-09-09

Base: `6d8a923475ce66a511b6f7d1c99fd65ec72bcacc`.
Branch: `work/upstream-3.3.5-verified-hardening`.
Last behavior checkpoint before this continuity update: `de1dab978d7d0086f01cc9b32f6121b6c43ce416`.
Backend H13 branch: `Naveax/revoltvpn-server-rust:work/h13-control-plane-contract`, head `000fc583c71873a5e8c6dfc2afde4d954d7cc220`.

## Scope discipline

- PR açılmadı, main'e merge/push yapılmadı, release yayımlanmadı.
- Production güvenliği için legacy AdMob bypass açılmadı.
- AdMob SDK/consent/support davranışı keyfi değiştirilmedi.
- Aynı SHA/workflow/input için queued/waiting/in-progress CI elle yeniden tetiklenmedi.
- Gerçek cihaz, production backend deployment veya production signing kanıtı olmayan maddeler accepted sayılmadı.

## Source-level doğrulanan hardening

- Native ingress tek authenticated loopback SOCKS5 listener'a sınırlandı; noauth/HTTP/fazla listener fail-closed.
- SOCKS UDP contract `udp=true` ve loopback UDP relay bind ile validator/regression kapsamına alındı.
- Kullanılmayan native delay subsystem'i kaldırıldı.
- NetworkSnapshot malformed metadata cast yolu güvenli fallback'e çevrildi.
- Per-session Xray config plaintext `config.json` yerine bounded stdin/EOF pipe üzerinden aktarılıyor; legacy plaintext temizlenemiyorsa start fail-closed.
- SecureSocksSession bind-check-close sahte rezervasyon penceresi kaldırıldı; Xray ilk gerçek bind sahibi, collision bounded retry ile ele alınıyor.
- Token kaybında stop artık aktif runtime yokluğunu varsayarak sahte success dönmüyor; QUERY_STATE + generation-scoped stop/ack kullanılıyor.
- Native status receiver Activity ömründen çıkarılıp engine/application scope'a taşındı.
- Core version probe bounded wait/output/process cleanup ile sertleştirildi.
- Normal connect sırasında SessionTimer'ın erken/çift başlaması engellendi; unconfirmed native stop durumunda server-derived session state/deadline korunuyor.
- Worker startup timer/Looper regression'ı main-looper Handler tabanlı ticker ile düzeltildi.
- Disconnect acknowledgement gerçek sahip olunan runtime generation'ına bağlandı.
- Xray source exact commit'e pinlendi; tun2socks mutable HEAD/git-pull build'i yasaklandı.
- Control-plane HTTP configured HTTPS same-origin dışındaki URL'leri reddediyor; redirect kapalı ve response size bounded.
- Always-on/lockdown desteği tamamlanana kadar capability `false` ve CI guard ile fail-closed.
- Persisted device UUIDv4 client tarafında canonical lowercase biçime normalize edilip server'ın strict parser contract'ıyla eşlendi.
- Privacy policy ve first-launch disclosure source/runtime kanıtını aşan sabit quota, immediate deletion, logging ve no-third-party vaatlerinden temizlendi.

## Güncel CI kanıtı

### Run 131 — SHA `733dce0de363560e860af2455d237dc2a8db6869`

Android CI `34348054593`: **SUCCESS**.

Geçen ana kapılar:

- checkout/toolchain/dependency resolve
- Gradle supply-chain doğrulaması
- dependency lock ve vendored runtime provenance
- Flutter analyze
- Flutter tests
- native Kotlin regression tests
- native JUnit evidence verification/upload
- Android lint
- production release config fail-closed check
- runtime secret transport contract
- unsupported always-on guard
- Android app-data/network-security policy
- cold APK build
- vendored native source immutability
- warm APK build
- release R8 smoke build
- tracked build-input immutability
- APK ve lockfile artifact upload

Bu run device UUID canonicalization değişikliğini tam build/regression hattında doğruladı.

### Run 132 — SHA `de1dab978d7d0086f01cc9b32f6121b6c43ce416`

Android CI `34349202579`: **SUCCESS**.

Privacy policy + first-launch disclosure değişiklikleri de aynı tam analyze/test/native/lint/APK/R8 hattından geçti. Bu nedenle `de1dab9` mevcut client source/CI checkpoint'idir.

Aynı SHA için manuel rerun yapılmadı.

## H13 client ↔ backend contract doğrulaması

Client:

- `device_id` artık geçerli UUIDv4 ise canonical lowercase string olarak kullanılıyor ve normalize edilmiş değer storage'a geri yazılıyor.
- status/stop kontrol trafiği per-generation session authorization header'ı kullanıyor.
- status tarafında no-session projection client için terminal auth failure olarak yorumlanmıyor; backend anti-oracle davranışıyla uyumlu.
- normal disconnect server revoke yoluna gidiyor; native shutdown kanıtlanmadan credential cleanup başarı varsayılmıyor.

Backend main gerçekliği:

- `parse_reference_device_id()` canonical lowercase, hyphenated version-4 UUID istiyor.
- session nonce header tam 32 lowercase hex istiyor.
- status eksik/malformed/mismatch nonce için privacy-preserving no-session döndürüyor.
- stop aynı authorization failure için 401 döndürüyor.
- stop authorization + revoke aynı per-device serialization gate altında; generation N credential'ı yarış halinde N+1'i authorize edemiyor.
- controller teardown ambiguity global fail-closed enforcement'a gidebiliyor.
- managed nginx public API access log'larını kapatıyor; query-bearing session/AdMob route'larında error logging de bastırılıyor.

Backend H13 branch düzeltmeleri:

- `7ac3534` — OpenAPI status/stop nonce semantiği runtime ile eşlendi.
- `c30fb7f` — canonical lowercase UUIDv4 schema + required stop device_id contract.
- `000fc58` — nonce transport açıklaması mevcut callback/SSV gerçeğiyle uyumlandı.

Backend workflow push'ta yalnız `main`, PR'da yalnız `main` hedefini çalıştırıyor. Kullanıcı istemeden PR açılmadığı için bu H13 branch'in henüz branch CI execution kanıtı yok. Bu nedenle backend H13 tam accepted değildir.

## AdMob / session authorization trust-boundary blocker

Mevcut activation akışında callback correlation/nonce değeri AdMob `custom_data` içine girebilir. Aynı değer status/stop bearer authorization için de kullanıldığında üçüncü taraf SSV trust boundary ile session secret boundary birleşmiş olur.

Managed nginx logging bu değerin server access log'una yazılmasını önlüyor, fakat üçüncü taraf processing sınırını ortadan kaldırmıyor. Production kabulü için callback correlation token ile session authorization secret ayrılmalı veya eşdeğer derecede güçlü ve açıkça doğrulanmış başka bir tasarım uygulanmalıdır.

Global `SessionWireMetadata` nonce validation'ını körlemesine 32-hex'e daraltmak kabul edilmedi, çünkü frozen legacy AdMob compatibility yolu `123-456` benzeri SupportNonce değerleri kullanabiliyor. Compatibility kırmadan sınır ayrımı yapılmalıdır.

## Production activation blocker

Current source checkpoint'te `AdManager.adsEnabled = false`.

Connect UI:

1. `AdManager.showAd('main')`
2. `vpn.connect()`

akışını kullanıyor. Ads disabled olduğunda real rewarded main activation yapılmıyor. `vpn.connect()` içindeki legacy fake callback best-effort olup production server'da bypass güvenli varsayılanla kapalı kalmalıdır. Bu nedenle production session issuance akışı henüz release-ready değildir.

**Legacy bypass'ı production'da açmak çözüm olarak kabul edilmez.**

## Regression/evidence kapsamı

Dart tarafında mevcut hardening coverage'i en az şunları kapsıyor:

- malformed/valid NetworkSnapshot.
- release verification fail-closed/reproducible.
- authenticated loopback SOCKS contract.
- control-plane HTTPS same-origin policy ve negatif URL vakaları.
- device ID canonicalization/legacy-uppercase/malformed/non-v4 davranışı.

Kotlin tarafında:

- exact-one secure ingress ve malformed ingress matrisi.
- UDP flag + loopback UDP relay contract.
- CoreConfigPipe exact UTF-8/EOF, oversized input, stalled writer timeout.
- VersionProbe bounded output/timeout/interrupt.
- RuntimeGeneration ownership/ack precedence.

## Build/provenance durumu

Kaynak/pipeline hazır:

- Xray v26.7.11 source commit `50231eaff98ccc31b5cbd247a721c16e97fe5ec1`.
- tun2socks exact source commit zorunluluğu.
- Gradle wrapper/distribution doğrulaması.
- dependency verification metadata.
- production workflow source SHA, app-config digest, toolchain, APK SHA256, signing cert fingerprint, native SO digests ve attestation üretmek üzere yapılandırıldı.

Henüz kanıtlanmadı:

- production secrets/keystore ile gerçek signed APK execution.
- yayımlanmış APK ile source/config/cert/attestation tüketici doğrulaması.

## Açık gerçek cihaz kabulü

Henüz fiziksel Android cihaz/emulator üzerinde tam acceptance yapılmadı:

- TUN IPv4 TCP/UDP roundtrip.
- TUN IPv6 TCP/UDP roundtrip.
- DNS UDP/TCP ve Android Private DNS.
- Wi-Fi ↔ LTE transition ve direct fallback/leak.
- Xray crash recovery/fail-closed.
- tun2socks crash recovery/fail-closed.
- Activity recreation / Flutter engine recreation / VPN service process death.
- permission revoke.
- session expiry / quota exhaustion.
- reboot/system-start.
- Discord voice/video, WebRTC, QUIC ve diğer UDP-heavy application davranışı.

Local SOCKS `UDP ASSOCIATE` başarısı bu e2e kanıtların yerine geçmez.

## Always-on / lockdown

`SUPPORTS_ALWAYS_ON=false` current güvenli davranıştır. Tam destek için en az:

- protected system-start bootstrap,
- expired credential resurrection engeli,
- Xray/tun2socks outbound socket loop protection,
- lockdown altında control-plane bootstrap,
- no-direct-fallback,
- reboot/process-death/device acceptance

gereklidir.

## Privacy/readiness doğrulaması

`de1dab9` ile source-backed policy şu gerçeklere çekildi:

- session quota sabit ürün vaadi değildir; server-authoritative.
- terminal session row'un anında silindiği vaat edilmez.
- managed nginx public access logging kapalıdır.
- Rust service journal retention production host ayarıyla doğrulanmadan kısa retention iddiası yapılmaz.
- rewarded ads current checkpoint'te disabled.
- AdMob gelecekte enabled olursa third-party processing açıkça disclosure edilir.
- local Xray access logging hardening'i production server/Xray deployment logging kanıtı yerine geçmez.

Production host retention, deployed Xray config ve signed artifact provenance görülmeden daha güçlü privacy/readiness garantileri accepted değildir.

## Ortam sınırları

- Bu sohbet ortamında fiziksel Android cihaz/emulator yürütülmedi.
- Production backend host'a deployment yapılmadı veya canlı host state burada kanıtlanmadı.
- Production signing secret/keystore kullanılmadı.
- Server H13 branch için PR açılmadığı için rust-strict branch CI oluşmadı.

## Kabul özeti

- H01-H09: source-level hardening ve client CI acceptance büyük ölçüde tamamlandı; cihaz-bağımlı alt kabul maddeleri H12/lifecycle kapılarında açık.
- H10: açık.
- H11: açık.
- H12: açık, gerçek cihaz gerekli.
- H13: client contract tarafı CI ile ilerledi; backend source patch var, backend branch CI/deployment ve SSV/session-secret sınırı açık.
- H14: privacy/disclosure CI ile güncellendi; README/continuity bu checkpointte güncelleniyor, production deployment-backed final claim review açık.

Production release kabulü için H10/H11/H12/H13 ve deployment-backed H14 bitmeden "tam güvenli / production-ready" denmez.
