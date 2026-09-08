# ReVoltVPN — doğrulanmış düzeltme ve kabul planı

Tarih: 2026-09-08. Durum: **WIP — PR/release için henüz hazır değil.**

## Kaynak ve çalışma hattı

- Upstream tabanı: `esefxdz/ReVoltVPN`, `6d8a923475ce66a511b6f7d1c99fd65ec72bcacc`.
- v3.3.5 kaynak commit'i: `4718a5912afa58201a693f757e401b4fdc3a5967`.
- Çalışma branch'i: `work/upstream-3.3.5-verified-hardening`.
- Bu checkpoint'teki son kaynak commit'i: `8a405cf79f2fcd17ea68cf7e42e42282b92cccc8`.
- PR açılmadı, main'e merge/push yapılmadı, release/APK yayımlanmadı.
- Upstream PR #7 ayrı iş hattıdır; bu branch onu değiştirmez.

## Kesin kapsam sınırları

1. **AdMob'a dokunulmaz:** adsEnabled, signature/key_id, reklam SDK'sı, consent ve support ödül akışı kapsam dışıdır.
2. Kullanıcı ayrıca istemeden PR açılmaz, main'e merge/push yapılmaz ve release yayımlanmaz.
3. Backend gerçekliği doğrulanmadan API protokolü veya quota semantiği keyfi değiştirilmez.
4. Paket kimliği, production origin, signing key, reklam kimlikleri ve sürüm numarası keyfi değiştirilmez.
5. SOCKS5 proxy-only modu sessizce transparent TUN'a çevrilmez.
6. Test yazmak testi geçirmek değildir. Cihaz/APK/backend kanıtı gereken maddeler bunlar olmadan kapanmaz.
7. Aynı SHA/workflow/input için queued/waiting/in_progress CI varken manuel rerun yapılmaz.

## Güncel iş paketleri

| ID | İş | Kabul koşulu | Güncel durum |
|---|---|---|---|
| H01 | Native ingress fail-closed | Tek authenticated loopback SOCKS5; noauth/HTTP/fazla listener reddi; UDP + loopback UDP relay zorunlu | **Kaynak düzeltildi.** Kotlin fixture'ları UDP sözleşmesine uyarlandı. Son CI kabulü bekliyor |
| H02 | Kotlin CI | `testDebugUnitTest` + JUnit XML; gerekli suite/test sayıları gerçekten yürümeli | **Kaynak tamam.** XrayCoreManager/CoreConfigPipe/VersionProbe/RuntimeGeneration evidence gate var; son CI bekliyor |
| H03 | Native dead code | Kullanılmayan delay subsystem'i ve geçici config yazıcısı olmamalı | **Kaynak tamam** |
| H04 | Network event doğruluğu | Malformed metadata güvenli fallback; geçerli event korunmalı; analyzer/test yeşil | **Kaynak tamam.** Eski CI analyzer'da yalnız `_appBackgrounded` uyarısı verdi; `dc08362` ile temizlendi, yeni CI bekliyor |
| H05 | Session config diski | Per-session credential içeren Xray config diske yazılmamalı; bounded stdin writer + EOF + process cleanup | **Kaynak tamam.** Xray `stdin:` aktarımı ve legacy `config.json` fail-closed temizliği var. Packaged binary/device doğrulaması bekliyor |
| H06 | SOCKS port sahipliği | bind-check-close sahte rezervasyonu olmamalı; Xray ilk bind sahibi; collision bounded retry ile ele alınmalı | **Kaynak tamam.** Cihaz stress testi bekliyor |
| H07 | Stop/adoption/generation | Token kaybında sahte success yok; authoritative service query; generation-scoped STOP/ACK; stale event yeni runtime'ı bozmamalı | **Kaynak tamam.** QUERY_STATE, engine-scope receiver ve ownership-first confirmation token var; `RuntimeGenerationTest` eklendi. Cihaz lifecycle kabulü bekliyor |
| H08 | Core version sorgusu | Bounded wait/output, process/stream cleanup ve executor lifecycle | **Kaynak tamam + regression testleri.** Son CI bekliyor |
| H09 | Dart error/timer lifecycle | Normal connect çift timer başlatmamalı; unconfirmed stop session saatini öldürmemeli; kullanıcı gerçek hata görmeli | **Kaynak büyük ölçüde tamam.** Analyzer regression temizlendi; cihaz lifecycle kabulü bekliyor |
| H10 | Always-on / lockdown | Protected bootstrap + runtime loop avoidance + reboot/expiry semantics + cihaz kabulü | **AÇIK.** `SUPPORTS_ALWAYS_ON=false` bilinçli korunuyor; CI yanlışlıkla true yapılmasını fail ediyor |
| H11 | APK provenance | Source SHA + config digest + toolchain + signing cert + native SO digests + APK SHA + attestation | **Pipeline hazır.** Manuel production build/attestation çalıştırılmadı |
| H12 | UDP/DNS/IPv6 | Authenticated UDP ASSOCIATE, TUN UDP roundtrip, DNS/Private DNS, IPv4/IPv6, ağ değişimi | **Kaynak kapsamı güçlendirildi.** UDP ingress validator/testleri ve SOCKS UDP ASSOCIATE var; gerçek cihaz e2e açık |
| H13 | Control-plane/backend | status/revoke/quota/authz sözleşmesini gerçek production backend ile eşleştir | **AÇIK**; AdMob bağımsız tutulacak |
| H14 | Doküman/ürün iddiaları | README/privacy/readiness ifadeleri dağıtım kanıtını aşmamalı | **AÇIK**; son kaynak/CI kabulünden sonra nihai metin güncellenecek |

## Son hardening commit zinciri

- `f77d5d2` — startup/error görünürlüğü ve SOCKS port probe race kaldırma.
- `113ef62` — Xray per-session config'i disk yerine stdin üzerinden aktarım.
- `2daf541` — authoritative runtime state/adoption, bounded diagnostics, service startup worker.
- `947e797` — Dart/native lifecycle eşleme, unconfirmed stop davranışı.
- `e87cc66` — native test evidence ve build provenance altyapısı.
- `dc08362` — SessionTimer analyzer regression temizliği.
- `55e619c` — worker-thread `CountDownTimer` yerine lazy main-looper ticker.
- `c98c78e` — disconnect ACK token'ını gerçekten sahip olunan runtime generation'ına bağlama.
- `9e60e98` — runtime generation regression testleri.
- `5ce5214` — bu test suite'ini CI evidence gate'e ekleme.
- `2be59fc` — UDP ingress fixture/negative testlerini gerçek native kontratla eşleme.
- `8a405cf` — always-on desteklenene kadar manifest capability'sini CI ile fail-closed tutma.

## Always-on / lockdown mimari kapısı

Sadece manifestte `SUPPORTS_ALWAYS_ON=true` yapmak kabul edilmez.

Mevcut TUN tasarımında uygulama paketi `addDisallowedApplication(packageName)` ile kendi VPN'inden çıkarılır. Lockdown açıkken excluded app'in control-plane erişimi kesilebilir. Ayrıca Xray/tun2socks child-process socket'lerinin VPN döngüsüne girmemesi için yalnız paket exclude'a güvenilmektedir. Bu nedenle gerçek always-on/lockdown için aşağıdakiler tamamlanmadan capability açılmaz:

1. Android/system-start durumunda command/config extra olmadan güvenli başlangıç semantiği.
2. Süresi dolmuş VLESS session credential'ını reboot/process death sonrası diriltmeyen bootstrap.
3. Xray/tun2socks outbound socket'lerinin `VpnService.protect` veya eşdeğer runtime-integrated mekanizmayla VPN döngüsünden güvenli çıkarılması.
4. Control-plane HTTP'nin lockdown sırasında ulaşılabilir kalması; Dart socket'lerinin topluca bypass edilmesine güvenilmemesi.
5. Lockdown altında başarısız bootstrap'ın direct-network fallback üretmemesi.
6. Reboot, process kill, permission revoke, quota expiry, internet yokluğu ve ağ değişimi cihaz testleri.
7. Proxy-only modunun cihaz-geneli kill-switch vaadi vermemesi.

Bu maddeler yokken `SUPPORTS_ALWAYS_ON=false` güvenli davranıştır; true yapmak feature değil regression olur.

## UDP / DNS / IPv6 kabul matrisi

Kaynak seviyesinde gerekli şartlar:

- SOCKS ingress `auth=password`.
- `udp=true`.
- UDP relay bind adresi `127.0.0.1`.
- TUN IPv4 route `0.0.0.0/0`.
- TUN IPv6 route `::/0` ve IPv6 TUN address.
- Local SOCKS authenticated UDP ASSOCIATE.

Gerçek cihazda ayrıca:

1. IPv4 TCP HTTPS.
2. IPv4 UDP roundtrip.
3. IPv6 TCP ve UDP roundtrip.
4. DNS UDP/TCP ve Android Private DNS davranışı.
5. Wi-Fi ↔ LTE geçişinde leak/direct fallback kontrolü.
6. Xray crash ve tun2socks crash sırasında trafik fail-closed.
7. Discord/WebRTC/QUIC benzeri UDP-heavy uygulama kabulü.

UDP ASSOCIATE başarısı tek başına internet UDP roundtrip kanıtı sayılmaz.

## Release provenance kabulü

Production pipeline manuel `workflow_dispatch` olarak kalır; otomatik release yapmaz. Kabul için:

1. Temiz, sabit source SHA.
2. Production app-config digest doğrulaması.
3. Dependency lock ve Gradle verification metadata.
4. Flutter/JDK/Gradle/NDK/toolchain kimliği.
5. Native `.so` SHA256 digest'leri.
6. Production APK SHA256.
7. Signing certificate SHA256 fingerprint.
8. GitHub workflow/run identity ve artifact attestation.
9. Ayrı doğrulayıcıyla digest/cert/source bağının kontrolü.

`build_xray.sh` Xray v26.7.11 commit `50231eaff98ccc31b5cbd247a721c16e97fe5ec1` üzerine sabitlendi. `build_tun2socks.sh` artık mutable `git pull` kullanarak build yapamaz; exact commit zorunludur.

## On kontrol kapısı

| Kapı | Kontrol | Durum |
|---|---|---|
| K01 | Fresh branch/SHA/base doğrulaması | Yapıldı |
| K02 | PR/issue/CI çatışması, duplicate run kontrolü | Her devam turunda yapılıyor; manuel rerun yapılmadı |
| K03 | İddia → hedef kaynak eşleme | H01–H12 için hedefli yapıldı |
| K04 | Caller/consumer/state ownership incelemesi | Stop/adoption/timer/config/UDP için yapıldı |
| K05 | Yanlış pozitif/tehdit önkoşulu ayrımı | CLAIM_REVIEW.md'de kayıtlı |
| K06 | Scope/AdMob koruması | AdMob/consent/support değiştirilmedi |
| K07 | Positive + negative regression | Native ingress/config/version/generation ve Dart metadata testleri mevcut; son CI bekliyor |
| K08 | Analyze/test/lint/build | `e87cc66` yalnız analyzer unused-field nedeniyle fail oldu; düzeltildi. Yeni SHA CI kuyruğunda |
| K09 | Gerçek cihaz runtime/UDP/DNS/IPv6/kill-switch | AÇIK |
| K10 | Production signed APK/provenance + bağımsız final diff | AÇIK |

## Devam sırası

1. En yeni SHA'nın mevcut CI run'ını oku; aynı SHA için manuel rerun yapma.
2. Analyze → Flutter test → Kotlin tests/evidence → Android lint → debug APK → R8 smoke hattında ilk gerçek failure'ı düzelt.
3. CI yeşil olmadan H01–H09'u "accepted" yazma.
4. H12 gerçek Android cihaz ağı/UDP/DNS/IPv6 kabul matrisi.
5. H10 için protected bootstrap/runtime loop mimarisi; yalnız bundan sonra always-on capability.
6. H11 production secrets ile manuel signed-build attestation.
7. H13 production backend kontrat doğrulaması.
8. H14 README/privacy/readiness iddia temizliği ve bağımsız son diff.
9. PR kullanıcı ayrıca istemeden açılmaz.
