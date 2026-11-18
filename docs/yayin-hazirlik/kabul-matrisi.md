# PanelLight yayın kabul matrisi — 2026-10-24

Aday: 0.2.2 (13), taban 4102038. Kanal: GitHub Releases / doğrudan indirme. Karar: ERTELE.
Hazır = belgelenmiş hazırlık veya gerekçeli uygulanmaz; cihazda yayın kabulü anlamına gelmez. Canlı GitHub durumu sorgulanmadı.

1. **hazır** — Uygulamanın vaadi, hedef kullanıcısı ve ilk kullanım akışı tek cümlede açık.
   Kanıt / sınır: README.md giriş ve Download; Apple Silicon hedefi açık.

2. **engel** — Temel işlev gerçek Mac'te baştan sona çalışıyor; desteklenen en eski macOS ve işlemci türü belirtilmiş.
   Kanıt / sınır: README.md macOS 12/arm64 diyor; bu adayda gerçek cihaz ve en eski macOS kabulü yok.

3. **engel** — Açılış, izin isteme, izin reddi, çevrimdışı durum, hata ve yeniden başlatma akışları anlaşılır.
   Kanıt / sınır: MonitorModel.swift hata yolları mevcut; izin reddi/yeniden başlatma gece denenmedi.

4. **engel** — Menü çubuğu/pencere/çentik davranışı, çoklu ekran, uyku-uyanma ve kapatma gerçek cihazda denendiği ölçüde kaydedilmiş.
   Kanıt / sınır: PanelLight.md açık madde 4; hotplug/uyku/çoklu ekran ve Link kapalı hover kabulü eksik.

5. **engel** — Erişilebilirlik: klavye, VoiceOver etiketleri, odak, kontrast ve metin ölçeği gözden geçirildi.
   Kanıt / sınır: QuickPanel.swift isBrightness=false kontrast etiketi mevcut; VoiceOver/odak/metin ölçeği cihaz testi yok.

6. **engel** — Kullanıcı verisi ve ayarlar güncelleme, kaldırma ve yeniden kurma sırasında beklenen biçimde korunuyor veya siliniyor.
   Kanıt / sınır: Info.plist bundle kimliği korunmuş; güncelleme/kaldırma/yeniden kurma veri testi yok.

7. **hazır** — Seçilen her dağıtım kanalının güncelleme yolu tanımlı; kullanıcı hangi kanaldan kurduğunu ve nasıl güncelleyeceğini biliyor.
   Kanıt / sınır: README.md Download ve AppInfo.swift SupportLinks.latestRelease; elle güncelleme yolu.

8. **engel** — Önceki yayımlanmış sürümden yenisine gerçek yükseltme denendi; imza, veri taşıma ve yeniden açılış doğrulandı.
   Kanıt / sınır: 0.2.0 → 0.2.2 gerçek yükseltme bu koşuda denenmedi.

9. **engel** — Güncelleme kaynağı, imza/sertifika yenileme ve erişim kaybı için sahip/yedek planı kayıtlı.
   Kanıt / sınır: build-app.sh SIGN_IDENTITY mevcut; sertifika yenileme/erişim kaybı yedeği kayıtlı değil.

10. **engel** — Uygulama içinden hata bildirimi ve öneri gönderme yolu çalışıyor; kullanıcı neyin gönderileceğini görüyor.
   Kanıt / sınır: AppInfo.swift sabit issue URL’leri ve şablonlar var; canlı link/forma gitme testi yok.

11. **engel** — Destek e-postası veya destek sayfası çalışıyor; gelen bildirimlerin sahibi ve yanıt akışı belli.
   Kanıt / sınır: README.md GitHub Issues yolu; bildirim sahibi ve yanıt süresi teyit edilmedi.

12. **hazır** — Çökme tanısı/log paylaşımı rızaya bağlı; hassas veri temizliği ve kullanıcıya kapatma seçeneği var.
   Kanıt / sınır: PRIVACY.md otomatik tanı/telemetri gönderilmediğini, isteğe bağlı GitHub bağlantısını anlatır; otomatik log paylaşımı kullanılmıyor (kaynak incelemesi).

13. **engel** — Toplanan veri, üçüncü taraf servisler ve saklama/silme davranışı gerçeğe uygun gizlilik metninde yazıyor.
   Kanıt / sınır: PRIVACY.md yerel ayarları anlatıyor; saklama/silme süresi açık değil, içerik teyidi gerekli.

14. **engel** — İzin açıklamaları gerçek kullanımla eşleşiyor; gereksiz izin istenmiyor.
   Kanıt / sınır: Info.plist izin açıklaması yok; özel macOS arayüzleri README’de; gereksiz izin/ret akışı cihazda doğrulanmadı.

15. **engel** — Kod, görsel, font, ses, SDK ve marka hakları dağıtıma uygun; lisans bildirimleri tamam.
   Kanıt / sınır: LICENSE MIT ve README Source research mevcut; tüm varlık hakları bağımsız teyit edilmedi.

16. **hazır** — Hesap/abonelik/lisans varsa aktivasyon, cihaz değiştirme, iptal, iade ve destek akışı denendi.
   Kanıt / sınır: Uygulanmaz: bu adayda hesap/ödeme/abonelik akışı yok; Package.swift dış bağımlılık yok, README ücretsiz kaynak/MIT.

17. **engel** — Ücret, deneme süresi ve özellik sınırları sitede, uygulamada ve ödeme adımında tutarlı.
   Kanıt / sınır: Bu adayda ödeme yok; dış site ve gelecek Pro sınırlarının tutarlılığı teyit edilmedi.

18. **engel** — Sürüm/yapı numarası, uygulama adı, Bundle ID, simge ve yayın varlıkları tutarlı.
   Kanıt / sınır: kontroller.txt plist 0.2.2 (13), bundle adı/ID doğrulandı; nihai yayın varlıkları henüz yok.

19. **engel** — DMG/PKG/ZIP ya da mağaza yapısı temiz Mac'te kuruldu; eski kurulumun üstüne kurulum denendi.
   Kanıt / sınır: Yeni ZIP üretilmedi; temiz Mac ve üzerine kurulum denenmedi.

20. **hazır** — App Store Connect sürümü/yapısı, App Review bilgileri ve yayın zamanı ayarlandı.
   Kanıt / sınır: Uygulanmaz: PanelLight.md dağıtım kararı GitHub Releases, Mac App Store kapsam dışı.

21. **hazır** — Mağaza metni, güncel ekran görüntüleri, destek bağlantısı, gizlilik URL'si ve veri beyanı tamam.
   Kanıt / sınır: Uygulanmaz: Mac App Store seçilmedi.

22. **hazır** — Mağaza üzerinden kurulum ve önceki mağaza sürümünden güncelleme denendi; güncelleme sorumluluğu mağaza akışında.
   Kanıt / sınır: Uygulanmaz: Mac App Store seçilmedi.

23. **engel** — Kurulabilir paket Developer ID ile imzalı, Hardened Runtime açık, noter onaylı; indirilen dosyada Gatekeeper açılışı denendi.
   Kanıt / sınır: kontroller.txt kurulu 0.2.2 arm64 Developer ID/runtime imzası doğrulandı; bu kaynağın dağıtım ZIP’i, noter onayı ve indirilen dosyada Gatekeeper yok.

24. **engel** — GitHub Release etiketi, sürüm notu, doğru DMG/PKG/ZIP dosyası, indirme bağlantısı ve checksum doğrulandı.
   Kanıt / sınır: release-notes-draft.md hazır; etiket/nihai ZIP/checksum ve canlı indirme eşleşmesi yok.

25. **hazır** — Uygulama içi güncelleme kullanılacaksa yeni sürüm bildirimi, elle denetle, güvenli indir/kur, erteleme ve önceki sürümden yükseltme denendi. Kullanılmayacaksa kullanıcıya elle güncelleme yolu gösterildi.
   Kanıt / sınır: Otomatik güncelleme kullanılmıyor; README ve AppInfo.swift elle GitHub Releases yolu mevcut.

26. **hazır** — Cask sürümü, URL, SHA-256, uygulama adı ve ana sayfa yayımlanan paketle eşleşiyor.
   Kanıt / sınır: Uygulanmaz: Homebrew bu yayın için seçilmedi; sonraki isteğe bağlı kanal.

27. **hazır** — `brew install --cask` ve `brew upgrade --cask` temiz/önceki kurulumda denendi; kaldırma davranışı açık.
   Kanıt / sınır: Uygulanmaz: Homebrew seçilmedi; kurulum/upgrade çalıştırılmadı.

28. **engel** — Lisans, README, kurulum/derleme adımları ve katkı/issue yolu açık; depoda sır veya dağıtım hakkı olmayan varlık yok.
   Kanıt / sınır: README/LICENSE/issue şablonları hazır; tüm tarihçede sır ve varlık hakları taraması yapılmadı; yalnız kaynak kanalı seçilmedi.

29. **engel** — Tek bir resmî sayfa var: uygulama ne yapar, kim içindir, sistem gereği, güncel indirme/mağaza bağlantısı.
   Kanıt / sınır: README resmî indirme/sistem gereksinimini içeriyor; dış sitenin güncel durumu teyit edilmedi.

30. **engel** — Sitede destek, gizlilik, fiyat (varsa), sürüm notları ve iletişim yolları bulunuyor; bağlantılar çalışıyor.
   Kanıt / sınır: README/PRIVACY/AppInfo yerel bağlantıları var; canlı destek/gizlilik/sürüm bağlantıları denenmedi.

31. **engel** — Ekran görüntüleri/video mevcut sürümü gösteriyor; örnek veri ve iddialar yanıltıcı değil.
   Kanıt / sınır: docs/images/panel.png mevcut; 0.2.2 hover arayüzünü temsil ettiği görsel olarak teyit edilmedi.

32. **hazır** — İsteğe bağlı: SSS, kısa başlangıç rehberi, demo video, basın kiti, yol haritası, topluluk.
   Kanıt / sınır: İsteğe bağlı, kapsam dışı: README kısa kurulum rehberi var; basın kiti/video yapılmadı.

33. **hazır** — İsteğe bağlı: kısa kullanıcı anketi veya geri bildirim panosu. Anket amacı, soruların sahibi ve sonuçların işlenme yolu belli.
   Kanıt / sınır: İsteğe bağlı, kapsam dışı: anket açılmadı; issue şablonları mevcut.

34. **engel** — Ortak ve seçilen kanal maddelerinin tümü tamam veya gerekçeli “uygulanmaz”; açık kusurlar ve sınırları yazıldı.
   Kanıt / sınır: Bu matris açık kritik eksikler içeriyor; yayın kararı ERTELE.

35. **engel** — Son paket, site, ödeme ve güncelleme bağlantıları başka bir cihaz/oturumdan tıklandı.
   Kanıt / sınır: Başka cihaz/oturum testi ve tarayıcı açılışı gece yasak; yapılmadı.

36. **engel** — Yayın sonrası ilk kontrolün sahibi ve zamanı belli: indirme, kurulum, çökme, destek kutusu, güncelleme beslemesi.
   Kanıt / sınır: Öneri: Berkin yayın sonrası ilk 30 dakikada indirme/kurulum/Issues kontrolü; sahip/zaman henüz onaylanmadı.

## Proje notundaki açık maddeler, sıra ile

- 4 — engel: fiziksel hotplug/uyku/çoklu ekran/yükseltme test planı `cihaz-test-plani.md`; Intel desteği README’de açıkça dışlandı.
- 7 — hazır (yerel kaynak/commit): 4102038 hover dalı ve önceki temizlik commit’leri aday dalında. Push, yeni paket ve noter onayı engel/onay bekliyor.
- 15 — engel: notun eski açık maddesi; 2026-10-16 kaydı PR #2 ve v0.2.0 yayımlandı diyor, yerel origin/main df6eeee bunu destekliyor. Canlı durum teyit edilmedi; aynı v0.2.0 yeniden yayımlanmayacak. Yeni aday v0.2.2 için paket yok.
- 16 — hazır (ertelenmiş/isteğe bağlı): Homebrew ve Sparkle bu yayın kapsamı dışında; elle güncelleme hazır.

## Dal farkları

Ana depodaki kirli dosyalar alınmadı. Kullanıcının komutuyla HEAD=473382e tabanında oluşturulan temiz gece dalı, kendi worktree’sinde 4102038’e taşındı; başka dal değiştirilmedi. `git merge --ff-only` başarısız oldu, dosya değiştirmedi.

fix/broken-functions dalı körlemesine birleştirilmedi: girişte açma hatası/sürüm bilgisi/DDC tekrarları/kontrast VoiceOver etiketi hover dalında farklı uygulamalarla zaten var. DDC son bilinen değer/hata sıfırlama farkları hâlâ davranış incelemesi ister. `ddc-fixes-reference.patch` referans yamasıdır, uygulanabilirlik çıktısı kontroller.txt içinde; otomatik uygulama önerilmez.

README’deki üç yanlış iddia 80475b9 kaynağından düzeltildi. `display-settings.patch` ekran ayarları düğmesinin doğru adını taşıyan uygulanmamış taslak; `git apply --check` sonucu kontroller.txt içinde. Uygulanırsa derleme/çeviri kontrolü gerekir. Kaynak kod davranışı bu koşuda değiştirilmedi.
