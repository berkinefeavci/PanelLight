# Yayın öncesi cihaz kabulü — çalıştırılmadı

Her satır için cihaz/macOS, beklenen/gerçek sonuç ve ekran kaydı yazılmalı. Başarısızlıkta yayın durur.

1. 0.2.0 ayarlarıyla yükselt: bundle ID aynı, renk/Link/başlangıç ayarları korunmalı; uygulama yeniden açılmalı.
2. Harici DDC ekranı çıkar/tak: satır kaybolup gelmeli, kontroller donmamalı; yanıt vermeyen ekran yazılıma düşmeli.
3. Uyut/uyandır: doğru ekranlar dönmeli, parlaklık/kontrast eski okumayla ezilmemeli.
4. Mac + harici + Sidecar: ayrı barlar ve Link birlikte çalışmalı; sanal ekran DDC’ye gitmemeli.
5. Hover Link kapalı: farenin bulunduğu ekran hedeflenmeli; Link açık: tüm ekranlar; tıklama tam panel açmalı. Alan dışına çıkınca kapanmalı.
6. Klavye/VoiceOver: açma, odak, bar değerleri, kontrast etiketi; açık/koyu görünüm ve metin ölçeği.
7. Girişte açma: macOS 13+ onay/ret/hata; macOS 12’de uygulanmaz açıklaması; yeniden başlatma.
8. Çıkış/yeniden açılış/çökme sonrası: yazılım katmanı ve kontrast eğrisi geri yüklenmeli.
9. macOS 12 Apple Silicon temiz cihazda ZIP kur; indirilen karantinalı dosyada Gatekeeper; yeniden kurulum ve kaldırma veri davranışı.
10. İkinci oturumda indirme, issue, gizlilik, güncelleme bağlantıları; yeni ekran görüntüsü ve son SHA-256 doğrulaması.

Intel desteklenmiyor; Intel testi kabul kapısı değil. Fiziksel testler ve Swift testleri tamamlanmadan aday yayınlanmaz.
