# ReVoltVPN — doğrulanmış düzeltme ve kabul planı

Tarih: 2026-09-09. Durum: **WIP — PR/release için henüz hazır değil.**

## Kaynak ve çalışma hattı

- Upstream tabanı: `esefxdz/ReVoltVPN`, `6d8a923475ce66a511b6f7d1c99fd65ec72bcacc`.
- v3.3.5 kaynak commit'i: `4718a5912afa58201a693f757e401b4fdc3a5967`.
- Client çalışma branch'i: `work/upstream-3.3.5-verified-hardening`.
- Son doğrulanmış client davranış checkpoint'i: `de1dab978d7d0086f01cc9b32f6121b6c43ce416`.
- Backend H13 çalışma branch'i: `Naveax/revoltvpn-server-rust:work/h13-control-plane-contract`.
- Backend H13 head: `000fc583c71873a5e8c6dfc2afde4d954d7cc220`, fresh main parent zinciri `ba5f4f832cc135f697fc0c0869b0ea71cddfb5f1` üzerinden ilerliyor.
- PR açılmadı, main'e merge/push yapılmadı, release/APK yayımlanmadı.

## Kesin kapsam sınırları

1. Kullanıcı ayrıca istemeden PR açılmaz, main'e merge/push yapılmaz ve release yayımlanmaz.
2. Production güvenliği için legacy AdMob bypass açılmaz.
3. AdMob SDK/consent/support ödül davranışı kapsam genişletmesi yapılmadan keyfi değiştirilmez.
4. Backend gerçekliği doğrulanmadan quota/session semantiği keyfi değiştirilmez.
5. Paket kimliği, production origin, signing key, reklam kimlikleri ve sürüm numarası keyfi değiştirilmez.
6. SOCKS5 proxy-only davranışı sessizce başka ürün semantiğine çevrilmez.
7. Test yazmak testi geçirmek değildir. Cihaz/backend/signing kanıtı gereken maddeler bunlar olmadan kapanmaz.
8. Aynı SHA/workflow/input için queued/waiting/in_progress CI varken manuel rerun yapılmaz.

## Güncel iş paketleri

| ID | İş | Kabul koşulu | Güncel durum |
|---|---|---|---|
| H01 | Native ingress fail-closed | Tek authenticated loopback SOCKS5; noauth/HTTP/fazla listener reddi; UDP + loopback UDP relay zorunlu | **SOURCE + CI ACCEPTED.** Gerçek cihaz e2e H12 altında açık |
| H02 | Kotlin CI | `testDebugUnitTest` + JUnit XML; gerekli suite/test sayıları gerçekten yürümeli | **ACCEPTED.** Native regression/evidence gate tam CI'da yeşil |
| H03 | Native dead code | Kullanılmayan delay subsystem'i ve geçici config yazıcısı olmamalı | **SOURCE ACCEPTED** |
| H04 | Network event doğruluğu | Malformed metadata güvenli fallback; geçerli event korunmalı; analyzer/test yeşil | **SOURCE + CI ACCEPTED** |
| H05 | Session config diski | Per-session credential içeren Xray config diske yazılmamalı; bounded stdin writer + EOF + process cleanup | **SOURCE + CI ACCEPTED.** Packaged/device davranışı H12/H11 altında açık |
| H06 | SOCKS port sahipliği | bind-check-close sahte rezervasyonu olmamalı; Xray ilk bind sahibi; collision bounded retry | **SOURCE + CI ACCEPTED.** Cihaz stress testi açık |
| H07 | Stop/adoption/generation | Authoritative service query; generation-scoped STOP/ACK; stale event yeni runtime'ı bozmamalı | **SOURCE + CI ACCEPTED.** Cihaz lifecycle kabulü açık |
| H08 | Core version sorgusu | Bounded wait/output, process/stream cleanup ve executor lifecycle | **SOURCE + CI ACCEPTED** |
| H09 | Dart error/timer lifecycle | Normal connect çift timer başlatmamalı; unconfirmed stop session state'i öldürmemeli; hata görünür olmalı | **SOURCE + CI ACCEPTED.** Cihaz lifecycle kabulü açık |
| H10 | Always-on / lockdown | Protected bootstrap + runtime loop avoidance + reboot/expiry semantics + cihaz kabulü | **AÇIK.** `SUPPORTS_ALWAYS_ON=false` bilinçli ve CI ile korunuyor |
| H11 | APK provenance | Source SHA + config digest + toolchain + signing cert + native SO digests + APK SHA + attestation | **Pipeline hazır.** Production signed workflow çalıştırılmadı |
| H12 | UDP/DNS/IPv6 | Authenticated UDP ASSOCIATE, TUN UDP roundtrip, DNS/Private DNS, IPv4/IPv6, ağ değişimi | **SOURCE/CI hazırlığı tamam; gerçek cihaz e2e AÇIK** |
| H13 | Control-plane/backend | status/stop/quota/authz/OpenAPI/client kimlik sözleşmesi production backend ile eşleşmeli | **SOURCE ilerledi, tam kabul AÇIK.** Client UUID canonicalization CI yeşil; backend OpenAPI/runtime drift patch'leri branch'te; backend branch CI/deployment kanıtı yok |
| H14 | Doküman/ürün iddiaları | README/privacy/readiness ifadeleri source ve deployment kanıtını aşmamalı | **SOURCE temizliği ilerledi.** Privacy/disclosure `de1dab9` full CI yeşil; README/continuity bu checkpointte güncelleniyor; production deployment iddiaları hâlâ acceptance gerektiriyor |

## Son önemli hardening zinciri

- `f77d5d2` — startup/error görünürlüğü ve SOCKS port probe race kaldırma.
- `113ef62` — Xray per-session config'i disk yerine stdin üzerinden aktarım.
- `2daf541` — authoritative runtime state/adoption, bounded diagnostics, service startup worker.
- `947e797` — Dart/native lifecycle eşleme, unconfirmed stop davranışı.
- `e87cc66` — native test evidence ve build provenance altyapısı.
- `55e619c` — worker-thread timer/Looper düzeltmesi.
- `c98c78e` / `9e60e98` / `5ce5214` — runtime-generation ACK ownership ve CI regression gate.
- `2be59fc` — UDP ingress fixture/negative testlerini gerçek native kontratla eşleme.
- `8a405cf` — always-on capability'yi destek gelene kadar fail-closed tutma.
- `e64b8bf` — unconfirmed native shutdown sırasında server-derived deadline/state'i koruma.
- `733dce0` — persisted device UUIDv4'ü server contract için canonical lowercase biçime normalize etme.
- `de1dab9` — privacy/disclosure iddialarını doğrulanmış runtime/deployment sınırlarına çekme.

Backend H13 branch:

- `7ac3534` — status/stop nonce OpenAPI semantiğini runtime ile eşleme.
- `c30fb7f` — device_id şemasını canonical lowercase UUIDv4 parser ile eşleme ve stop body required alanını düzeltme.
- `000fc58` — nonce transport açıklamasını mevcut SSV/callback sınırıyla uyumlu hale getirme.

## H13 güven sınırı ve production activation blocker

Mevcut client main-session akışında session için üretilen korelasyon/nonce değeri AdMob `custom_data` içine girebilir ve aynı değer status/stop authorization tarafında da kullanılabilir. Managed nginx public API access logging'i kapalı tuttuğu için doğrudan edge access-log sızıntısı görülmedi. Ancak üçüncü taraf SSV trust boundary nedeniyle callback correlation verisi ile session bearer authorization secret'ının aynı değer olması production kabulünde yeniden tasarlanmalı veya açıkça gerekçelendirilmelidir.

Ayrıca current source checkpoint'te `AdManager.adsEnabled = false`. Connect UI önce `showAd('main')`, sonra `vpn.connect()` çağırıyor; `vpn.connect()` içindeki legacy fake callback best-effort ve production bypass güvenli varsayılanla kapalı olmalıdır. Bu nedenle production session issuance şu an release blocker'dır. Çözüm legacy bypass'ı production'da açmak değildir.

## Always-on / lockdown mimari kapısı

`SUPPORTS_ALWAYS_ON=true` yalnız manifest değişikliğiyle açılamaz. Tam destek için:

1. Android/system-start güvenli bootstrap.
2. Expired credential resurrection engeli.
3. Xray/tun2socks outbound socket protection veya eşdeğer loop-avoidance.
4. Lockdown altında control-plane bootstrap.
5. Başarısız bootstrap'ta direct-network fallback olmaması.
6. Reboot/process kill/permission revoke/quota expiry/internet yokluğu/ağ değişimi cihaz testleri.
7. Proxy-only modunun cihaz-geneli kill-switch vaadi vermemesi.

Bu maddeler tamamlanana kadar `SUPPORTS_ALWAYS_ON=false` doğru fail-closed davranıştır.

## UDP / DNS / IPv6 kabul matrisi

Kaynak/CI seviyesinde hazır olan şartlar:

- authenticated SOCKS ingress.
- `udp=true`.
- loopback UDP relay bind.
- local authenticated UDP ASSOCIATE regression kapsamı.
- TUN/route ve runtime hardening için kaynak guard'ları.

Gerçek cihazda zorunlu kabul:

1. IPv4 TCP HTTPS.
2. IPv4 UDP roundtrip.
3. IPv6 TCP ve UDP roundtrip.
4. DNS UDP/TCP ve Android Private DNS.
5. Wi-Fi ↔ LTE geçişinde leak/direct fallback kontrolü.
6. Xray/tun2socks crash sırasında fail-closed davranış.
7. Activity/engine/service process lifecycle.
8. Permission revoke, session expiry ve quota exhaustion.
9. Discord voice/video, WebRTC ve QUIC gibi UDP-heavy uygulamalar.

Local SOCKS `UDP ASSOCIATE` başarısı tek başına internet UDP roundtrip kanıtı değildir.

## Release provenance kabulü

Production pipeline manuel kalır. Kabul için:

1. Temiz exact source SHA.
2. Production app-config digest.
3. Dependency lock + Gradle verification metadata.
4. Flutter/JDK/Gradle/NDK/toolchain kimliği.
5. Native `.so` SHA256 digest'leri.
6. Production APK SHA256.
7. Signing certificate SHA256 fingerprint.
8. Workflow/run identity + artifact attestation.
9. Ayrı doğrulayıcıyla source/config/cert/APK bağının kontrolü.

## Kontrol kapıları

| Kapı | Kontrol | Durum |
|---|---|---|
| K01 | Fresh branch/SHA/base | Her tur doğrulanıyor |
| K02 | PR/issue/CI çatışması ve duplicate run | Manuel duplicate rerun yapılmadı |
| K03 | İddia → hedef kaynak | H01–H14 için hedefli ilerliyor |
| K04 | Caller/consumer/state ownership | Stop/adoption/timer/config/UDP/control-plane için yapıldı |
| K05 | Yanlış pozitif/tehdit önkoşulu | Uygulandı; compatibility nonce global zorlanmadı |
| K06 | Scope/AdMob koruması | Legacy/consent/support davranışı keyfi değiştirilmedi; production bypass açılmadı |
| K07 | Positive + negative regression | Client CI tam yeşil checkpoint mevcut |
| K08 | Analyze/test/lint/APK/R8 | `de1dab9` run 132 **SUCCESS** |
| K09 | Gerçek cihaz runtime/UDP/DNS/IPv6/kill-switch | **AÇIK** |
| K10 | Production signed APK/provenance + final independent diff | **AÇIK** |

## Devam sırası

1. Bu continuity checkpoint'inin CI sonucunu oku; duplicate rerun yapma.
2. H13 backend branch için PR açmadan mümkün olan source/contract doğrulamasını bitir; CI/deployment kanıtını açık tut.
3. Production activation tasarımında AdMob correlation ile session authorization secret'ını ayıracak migration planını çıkar; legacy compatibility ve bypass güvenli varsayılanını koru.
4. H12 gerçek Android cihaz ağı/UDP/DNS/IPv6 kabul matrisi.
5. H10 protected bootstrap/runtime-loop mimarisi ve cihaz kabulü.
6. H11 production signed-build attestation.
7. H14 final independent diff ve deployment-backed privacy/readiness doğrulaması.
8. Kullanıcı ayrıca istemeden PR açma, main'e merge etme veya release yayımlama.
