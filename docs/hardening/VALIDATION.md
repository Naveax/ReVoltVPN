# Validation record — 2026-09-08

Base: `6d8a923475ce66a511b6f7d1c99fd65ec72bcacc`.
Branch: `work/upstream-3.3.5-verified-hardening`.
Current checkpoint before this document update: `6543dcb8023a74326ca5e4a10644b5540a71f58f`.

## Scope discipline

- PR açılmadı, main'e merge/push yapılmadı, release yayımlanmadı.
- AdMob, consent ve support ödül akışı değiştirilmedi.
- Aynı SHA/workflow/input için queued/waiting/in-progress CI elle yeniden tetiklenmedi.
- Gerçek cihaz, production backend veya production signing kanıtı olmayan maddeler accepted sayılmadı.

## Kaynakta doğrulanan ve düzeltilenler

- Native ingress tam olarak tek authenticated loopback SOCKS5 listener'a sınırlandı; noauth/HTTP/fazla listener fail-closed.
- SOCKS UDP sözleşmesi `udp=true` ve UDP relay bind `127.0.0.1` olarak native validator ve regression fixture'larında zorunlu.
- Kullanılmayan native delay subsystem'i kaldırıldı.
- NetworkSnapshot malformed metadata cast yolu güvenli fallback'e çevrildi.
- Per-session Xray config `config.json` yerine bounded stdin/EOF pipe üzerinden aktarılıyor; legacy plaintext config silinemiyorsa start fail-closed.
- SecureSocksSession bind-check-close sahte rezervasyon penceresi kaldırıldı; Xray ilk gerçek bind sahibi, collision bounded runtime retry ile ele alınıyor.
- Token kaybında `stopVless` artık aktif runtime yokluğunu varsayarak success dönmüyor; service QUERY_STATE + generation-scoped stop/ack kullanılıyor.
- Native status receiver Activity ömründen çıkarılıp engine/application scope'a taşındı.
- `getCoreVersion` bounded wait/output/process cleanup ile sertleştirildi.
- Normal connect sırasında SessionTimer'ın erken/çift başlaması engellendi; unconfirmed native stop durumunda son server-derived session state korunuyor.
- Worker executor'a taşınan Xray startup'ın `CountDownTimer`/Looper regression'ı lazy main-looper Handler ticker ile düzeltildi.
- Disconnect acknowledgement token'ı caller'ın verdiği generation yerine öncelikle gerçekten sahip olunan runtime generation'ından türetiliyor.
- Native source build provenance: Xray exact commit'e pinli; tun2socks mutable HEAD/git-pull build'i yasak, exact commit gerekli.
- Control-plane HTTP ortak katmanı configured HTTPS same-origin dışındaki URI'leri reddediyor; redirect zaten kapalı ve response 256 KiB ile sınırlı.
- Always-on/lockdown tam desteklenene kadar `SUPPORTS_ALWAYS_ON=false` bilinçli korunuyor; CI yanlışlıkla true yapılmasını reddediyor.

## CI kanıtı

### Eski ilk failure

Run `34250095998`, SHA `0a6a2ac`:
- Gradle supply-chain doğrulaması geçti.
- Flutter kurulumu/dependency resolve/provenance adımları geçti.
- Analyze başarısız oldu; sonraki commitlerde düzeltildi.

### Run 34272027097 — SHA 55e619c

Bu koşu source hardening'in ilk önemli yürütme kanıtını verdi:

- Gradle 8.14 wrapper doğrulaması: **PASS**.
- Flutter 3.47.2 kurulumu: **PASS**.
- Dependency lock: **PASS**.
- Vendored runtime provenance pre-check: **PASS**.
- `flutter analyze`: **PASS**, `No issues found!`.
- `flutter test`: **PASS**, 4/4 test.
  - malformed NetworkSnapshot fallback.
  - valid NetworkSnapshot preservation.
  - release verification fail-closed/reproducible.
  - authenticated SOCKS IPv4 loopback contract.
- Native Kotlin compile: **PASS**.
- `VersionProbeTest`: **5/5 PASS**.
- `CoreConfigPipeTest`: **3/3 PASS**.
- XrayCoreManager malformed/invalid/missing/additional ingress negative tests: **PASS**.
- Native total: 13 tests, 2 failure.

İki failure:

1. `buildRuntimeConfigJson_keepsSecureSocksAndSanitizesLogs`
2. `buildRuntimeConfigJson_normalizesXrayRuntimeAliases`

Kök neden production kodu değil, test fixture drift'iydi: native validator artık `udp=true` ve `ip=127.0.0.1` zorunlu tutarken iki valid fixture eski kontratı üretmeye devam ediyordu. `2be59fcbf2cd2cf391118e60031a1c5cc0c2bb0c` bu fixture'ları gerçek kontratla eşledi ve `udp=false` / non-loopback UDP bind için negatif regression ekledi.

### Yeni test/evidence kapsamı

CI artık aşağıdaki JUnit suite'lerini gerçekten yürütmeyi zorunlu kılıyor:

- `XrayCoreManagerTest` >= 5
- `CoreConfigPipeTest` >= 3
- `VersionProbeTest` >= 5
- `RuntimeGenerationTest` >= 3

Her suite için failures/errors/skipped sıfır olmalı. JUnit XML ayrıca artifact olarak yükleniyor.

### En yeni CI

SHA `6543dcb8023a74326ca5e4a10644b5540a71f58f` için Android CI run `34272733143` oluşturuldu. Bu kayıt yazılırken **queued**. Aynı SHA için manuel rerun yapılmadı.

## Regression testleri

Dart:

- Network event malformed/valid metadata.
- Release verification fail-closed/reproducible.
- Authenticated loopback SOCKS contract.
- ControlPlanePolicy: HTTPS same-origin kabul; HTTP, cross-origin, userinfo, fragment ve invalid configured base reddi.

Kotlin:

- Exact-one secure ingress ve malformed ingress matrisi.
- UDP flag ve loopback UDP relay contract.
- CoreConfigPipe exact UTF-8/EOF, oversized input, stalled writer timeout.
- VersionProbe first-line/EOF/oversize/timeout/interrupt davranışı.
- Runtime generation acknowledgement ownership precedence.

## Build/provenance kanıtı

Kaynakta hazır:

- Xray v26.7.11 source commit: `50231eaff98ccc31b5cbd247a721c16e97fe5ec1`.
- tun2socks source build exact commit zorunluluğu.
- Gradle wrapper SHA ve distribution SHA doğrulaması.
- Gradle dependency verification metadata.
- Manuel production workflow: source SHA, app-config digest, toolchain kimliği, APK SHA256, signing certificate fingerprint, native SO digest'leri ve GitHub attestation üretmek üzere yapılandırıldı.

Henüz kanıtlanmadı:

- Production secrets/keystore ile gerçek signed APK workflow execution.
- Yayımlanmış APK ile source SHA/attestation tüketici doğrulaması.

## Açık gerçek cihaz kabulü

Henüz Android device/emulator üzerinde aşağıdakiler yürütülmedi:

- TUN IPv4 TCP/UDP roundtrip.
- TUN IPv6 TCP/UDP roundtrip.
- DNS UDP/TCP ve Android Private DNS.
- Wi-Fi ↔ LTE geçişi ve direct fallback/leak kontrolü.
- Xray crash recovery.
- tun2socks crash recovery.
- Activity recreation / Flutter engine recreation / VPN service process death.
- permission revoke.
- session expiry / quota exhaustion.
- reboot.
- Discord voice/video, WebRTC ve QUIC benzeri UDP-heavy uygulamalar.

Local SOCKS `UDP ASSOCIATE` başarısı bu e2e testlerin yerine geçmez.

## Always-on / lockdown

Current service manifest açıkça `SUPPORTS_ALWAYS_ON=false` tutuyor. Bu bilinçli fail-closed karardır; mevcut mimaride yalnız flag'i true yapmak güvenli çözüm değildir.

Tam destek için en az:

- system-start bootstrap,
- expired credential resurrection engeli,
- Xray/tun2socks outbound socket protection,
- lockdown altında control-plane bootstrap,
- no-direct-fallback,
- reboot/process-death/device kabulü

gereklidir.

## Ortam sınırları

- Bu sohbet ortamında fiziksel Android cihaz/emulator çalıştırılmadı.
- Production backend deployment ve server-side authorization/replay/retention davranışı henüz bu client branch kanıtıyla doğrulanmış değildir.
- Production signing secrets kullanılmadı.
- CI/toolchain uyarıları (Gradle/AGP/Kotlin gelecekteki minimum sürümler ve bazı deprecated Android API'ler) bakım borcu olarak kaydedildi; mevcut güvenlik düzeltme serisini kör toolchain upgrade ile genişletmedik.

## Kabul kuralı

H01–H09 source-level düzeltmelerinin önemli bölümü tamamlandı, fakat en yeni SHA'nın tam analyze/test/native evidence/lint/APK/R8 hattı yeşil görülmeden "CI accepted" sayılmaz. H10/H11/H12/H13/H14 kendi cihaz, production veya dokümantasyon kanıt kapılarına göre açık kalır.
