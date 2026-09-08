# ReVoltVPN — doğrulanmış düzeltme ve kabul planı

Tarih: 2026-09-08. Durum: **WIP — PR/release için hazır değil.**

## Kaynak ve çalışma hattı

- Upstream tabanı: `esefxdz/ReVoltVPN`, `6d8a923475ce66a511b6f7d1c99fd65ec72bcacc`.
- v3.3.5 kaynak commit'i: `4718a5912afa58201a693f757e401b4fdc3a5967`; taban bunun bildirim düzeltmesi içeren devamıdır.
- Fork main: `3da20fb386d6b611b8bd1fc3754e5cb229efd662`. Bu tabanla aynı ürün kesiti değildir.
- Çalışma branch'i: `work/upstream-3.3.5-verified-hardening`.
- Upstream PR #7 (`pr/fix-connection-mode-persistence`) açık; bu plan o PR'yi değiştirmez.
- `hardening/release-native-security` başka bir aktif çalışma hattıdır. Bu oturum sırasında iki farklı SHA için queued CI görüldü (34249607998, 34249570068). Üzerine yazma veya kör cherry-pick yapma; taşınacak her değişikliği taze diff ile karşılaştır.
- Yerel başlangıç temizdi; repo içinde AGENTS.md bulunmadı.

## Kesin kapsam sınırları

1. **AdMob'a dokunulmaz:** adsEnabled, test bypass, signature/key_id, reklam SDK'sı, consent ve support ödül akışı bu serinin değişiklik kapsamı dışındadır. Bilinçli bypass'ı hata sayma veya debug guard ekleyerek release bootstrap'ını bozma.
2. **PR açılmaz, main'e merge/push yapılmaz, release/APK yayımlanmaz.** Yalnız bu branch'e incelemeye uygun kaynak ve belge commit'leri.
3. Upstream API protokolü backend doğrulanmadan değiştirilmez. Rust backend geliştirilmiş olması bu istemcinin üretimde onu kullandığını kanıtlamaz.
4. Paket kimliği, imza anahtarı, server/API origin, reklam kimlikleri, sürüm numarası ve quota politikası keyfi değiştirilmez.
5. SOCKS5 proxy-only modu sessizce transparent TUN'a dönüştürülmez. Eski transparent branch'ler topluca alınmaz.
6. Android VPN izni, runtime token/generation kontrolleri, IPv4/IPv6 rotaları, hedef pin ve TLS doğrulaması korunur.
7. Branch protection gibi yönetim ayarları bu kaynak düzeltme serisinden ayrıdır; koruma bilgisi tek başına exploit kanıtı değildir.
8. Canlı sunucu/üçüncü taraf üzerinde istismar denemesi yapılmaz. Testler yerel/sentetik girdiler ve kontrollü cihaz laboratuvarıyla sınırlıdır.
9. Root/same-UID saldırgan varsayımı normal üçüncü taraf uygulama erişimiyle karıştırılmaz. Stil, dead code ve hardening eksikliği otomatik güvenlik açığı sayılmaz.
10. APK, gerçek cihaz ve backend kanıtı yoksa o maddeler kapatılmaz. Testi yazmak testi geçirmek değildir.

## Öncelikli iş paketleri

| ID | İş | Değişiklik ve kabul koşulu | Şimdiki durum |
|---|---|---|---|
| H01 | Native ingress fail-closed | Tam bir authenticated loopback ingress; eksik/fazla/yanlış listener reddi; port/tip/account kontrolü; noauth ve HTTP fallback yok | Yama ve regression testleri yazıldı; çalıştırma bekliyor |
| H02 | Kotlin CI | `:flutter_vless_android:testDebugUnitTest` gerçek CI adımı; bağımlılık doğrulamasını gevşetmeden sonuç XML'inde testlerin yürüdüğünü doğrula | Workflow'a eklendi; CI sonucu bekliyor |
| H03 | Native dead code | Bridge/repo çağrısı olmayan delay subsystem'i ve kendi geçici config yazıcısını kaldır; dış platform sözleşmesinde aktif karşılığı olmadığını kontrol et | Kaynak çağrı taraması yapıldı; kaldırıldı; derleme bekliyor |
| H04 | Network event doğruluğu | Yanlış tipli reason/transport/timestamp için güvenli varsayılan; geçerli native event aynen korunmalı | Yama ve iki Dart testi yazıldı; yürütme bekliyor |
| H05 | Session config diski | Xray'ın sabitlenen sürümünde stdin/FD kabulünü kaynak ve binary ile doğrula; pipe/FD aktarımı, writer timeout, EOF ve süreç temizliği; tüm başlangıç/hata/kapanış yollarında secret dosyası olmamalı | AÇIK; aktif config.json yazıcısı hâlâ mevcut |
| H06 | Ephemeral port TOCTOU | Gerçek listener sahipliği: Xray'ın bind(0)/FD devralma yeteneğini doğrula; destek yoksa runtime entegrasyonu gereklidir. Retry/rastgele port tek başına atomiklik değildir | AÇIK; Dart bind-close-Xray bind penceresi mevcut |
| H07 | Stop/adoption sözleşmesi | Native durumu/token'ı doğrulayarak stop; token'sız success aktif runtime yokluğunu kanıtlamaz. Yeni generation'ı durdurmadan stop ack, timeout, geç event, engine yeniden oluşturma senaryoları | AÇIK; yalnız koşullu kaynak bulgusu, cihazda yeniden üretim yapılmadı |
| H08 | Core version sorgusu | Bounded bekleme/çıktı, stream/process finally cleanup, executor yaşam döngüsü, Dart init deadline; eski Android API uyumluluğu | AÇIK; readLine beklemesi kaynakta sınırsız |
| H09 | Error/timer lifecycle | UI hata durumunu göstermeli; cleanup hatası ile ilk hatayı ayır; geç disconnected event ve çift timer start için sıralama testleri | AÇIK; errorMessage UI tüketicisi bulunmadı, diğer zincirler henüz doğrulanmadı |
| H10 | Always-on / lockdown | Aşağıdaki ayrı mimari paketi ve cihaz kabul koşulları; yalnız manifest flag değişikliği yeterli değil | AÇIK; desteksiz flag olduğu gibi korundu |
| H11 | APK provenance | İmzalı APK digest'i, signing cert fingerprint, source SHA, config digest, Flutter/JDK/Gradle/NDK sürümleri, native artifact digests ve workflow run identity bağlanmalı; tüketici doğrulaması yapılmalı | AÇIK; mevcut release digest'i tek başına kaynak bağı değildir |
| H12 | UDP/DNS/IPv6 | TUN ve proxy-only ayrı kabul; controlled UDP roundtrip, DNS/Private DNS, IPv6 ve ağ değişimi; TCP readiness UDP kanıtı sayılmaz | AÇIK; cihaz yok |
| H13 | Control-plane sözleşmesi | HTTPS/origin ve status/revoke protokolü backend gerçekliğiyle eşleştir; AdMob'a dokunmadan bağımsız planla | AÇIK; server-side yetkilendirme kanıtlanmadı |
| H14 | Doküman ve ürün doğruluğu | Mode, restart, memory-only, privacy ve readiness ifadelerini mevcut dağıtım kanıtına bağla; bilinmeyen retention değeri uydurma | Bu plan önceki raporları ayırıyor; ürün doküman güncellemesi bekliyor |

## Always-on / kill-switch tasarım paketi

- AlarmManager oturum sonlandırması, tünel gidince trafiği engelleyen lockdown değildir.
- Android tarafından başlatılan servisi (komut/config extra yok) ele al. Mevcut servis bunun için güvenli restore akışına sahip değil.
- Oturum bitmiş/yetkisizken eski VLESS kimliğini yeniden etkinleştirme. Bağlantı kurulamadığında sistem lockdown durumunu kullanıcıya doğru göster.
- Xray outbound'unu `VpnService.protect` ile döngü dışında tutan tasarım ile uygulama paketinin bütünüyle exclude edilmesini karşılaştır. Lockdown altında excluded uygulamanın bootstrap API erişimi ayrıca çözülmeli.
- Proxy-only, cihaz geneli lockdown vaadi vermemeli. Mod değişimi sırasında kullanıcı onayı/OS VPN ayarı korunmalı.
- Reboot, UI process ölümü, servis process ölümü, permission revoke, ağ değişimi, quota expiry ve internet yokluğu cihazda sınanmalı.
- Ürün gereksinimi ve güvenli restore tamamlanmadan SUPPORTS_ALWAYS_ON=true yapma.

## Release provenance kabulü

v3.3.5 GitHub release'inde `app-release.apk` için görülen digest:
`sha256:d2af7002659fe7dc406b5e24029e1f7a17450693ed3bf78f89b0423476b3a623`.
Bu API metadata'sıdır; APK bu oturumda indirilip hash/signature karşılaştırması yapılmadı.

1. Üretim build'i temiz ve sabit SHA'dan yapılmalı; production app_config hash kontrolü korunmalı.
2. Debug/R8 smoke APK release ürünü sayılmamalı; signing certificate kimliği ayrıca doğrulanmalı.
3. Native AAR/SO digest ve toolchain sürümleri build manifest'inde bulunmalı.
4. Güvenilir workflow kimliğine bağlı attestation ile tam APK digest'i ilişkilendirilmeli.
5. Ayrı doğrulayıcı APK'nın digest, sertifika, kaynak SHA ve workflow kimliğini kontrol etmeli.
6. Bir hash dosyası veya başarılı CI geçmişte yayımlanmış APK'yı geriye dönük kanıtlamaz.
7. İmza/secret erişimi olmayan bu branch'te üretim release'i yapılmaz.

## On ayrı kontrol kapısı

Kullanıcının "en az 10 defa" talebi aşağıdaki bağımsız kapılarla izlenir. **On tam denetim tamamlandı denmiyor.** Her düzeltme için bu kapıların geçerli olanları gerçek kanıtla kapanır; tekrar aynı grep'i çalıştırmak yeni kontrol sayılmaz.

| Kapı | Kontrol | Bu oturum |
|---|---|---|
| K01 | SHA/tag/branch ve temiz başlangıç | Yapıldı: üstteki sabitler |
| K02 | PR/issue/CI çatışması ve başka çalışan branch | Yapıldı; başka branch CI'sı görüldü, yeniden tetiklenmedi |
| K03 | Rapor iddiasını hedef kaynakta bul | H01/H02/H05/H06/H08 ve mode ayrımı için yapıldı |
| K04 | Çağıran/ulaşılabilirlik ve test sözleşmesi | Native delay ve ingress için yapıldı; bütün uygulama henüz değil |
| K05 | Tehdit önkoşulu/yanlış pozitif ayrımı | CLAIM_REVIEW.md'de kayıtlı; tam madde eşlemesi bekliyor |
| K06 | Yama diff'i / AdMob ve scope koruma | Bu commit öncesi kontrol edildi |
| K07 | Olumlu ve olumsuz regression | Testler yazıldı; çalıştırılmadı |
| K08 | Kotlin/Dart analyze, test, Android lint/build | Yerel ortam engelli; CI bekliyor |
| K09 | Gerçek cihaz runtime/UDP/DNS/IPv6/kill-switch | BAŞLAMADI |
| K10 | İmzalı APK/provenance ve bağımsız son diff/kanıt kabulü | BAŞLAMADI |

## Devam sırası ve commit düzeni

1. Önce bu branch'in mevcut SHA ve aktif CI run ID'sini oku. Aynı SHA/workflow/input için ikinci run oluşturma.
2. H01–H04 test/build sonuçlarını doğrula. Başarısız test varsa sebebi düzelt; assertion'ı kaldırarak yeşil elde etme.
3. Aktif diğer hardening branch ile güncel diff'i karşılaştır. Eşdeğer düzeltmeyi ikinci kez taşıma. Geçmişi force-push ile silme.
4. H05 ve H06 için sabitlenmiş Xray runtime capability incelemesi ve ayrı mimari değişiklikler.
5. H07–H09 lifecycle/initialization için küçük commit'ler ve davranış testleri.
6. H10 ayrı sistem entegrasyonu; H12 cihaz doğrulaması ile birlikte.
7. H11 build/release sorumlusu kanıtı ve H13 gerçek backend kontratı.
8. H14 ürün dokümanı, tam iddia matrisi, son scope diff ve kullanıcı incelemesi.
9. Her tamamlanan paket PLAN/CLAIM_REVIEW/VALIDATION durumunu günceller. PR açmak ayrıca kullanıcı tarafından istenene kadar yasak.

## Teknik başvuru kaynakları

- Android VPN/always-on/lockdown: https://developer.android.com/develop/connectivity/vpn
- Dart isolate/event loop: https://dart.dev/language/concurrency
- GitHub build provenance: https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds
