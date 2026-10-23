# Onay bekleyen — çalıştırılmamış komut taslakları

Yayın kararı: ERTELE. Kabul matrisindeki kritik engeller kapanmadan bu komutlar çalıştırılmamalı.
`v0.2.2` öneridir; uzaktaki etiket varlığı bu gece teyit edilmedi. Geçmiş v0.2.0 tekrar yayımlanmaz.

## Kaynak incelemesi

- `display-settings.patch`: doğru ekran ayarları düğmesi metni ve Türkçe karşılığı; hover kaynağına uyarlanmış, `git apply --check` geçti. Uygulanmadı. İnceleme sonrası `git apply docs/yayin-hazirlik/display-settings.patch`; ardından derleme/çeviri kontrolü ve yeni commit gerekir.
- `ddc-fixes-reference.patch`: 579bd0e referansı; aday kaynağa **uygulanmıyor**. Son bilinen DDC durumu/clearErrors farkları elle karşılaştırılmalı; doğrudan uygulamayın. Kontrast VoiceOver ve sürüm gösterimi adayda zaten var.
- Homebrew/Sparkle: isteğe bağlı ayrı iş; mevcut elle güncelleme yoluyla yayınlanabilir.
- Website değişikliği dosya sahipliği dışında; Apple Silicon/özellik/son sürüm ve yeni hover görseli ayrı işte doğrulanmalı.

## Gündüz, yerel derleme ve paket (bu gece çalıştırılmadı)

Sertifika kimliği kurulu uygulamada görüldü; `cellkeep-notary` profilinin kullanılabilirliği teyit edilmedi. Final kaynak sabitlendikten sonra sürüm/yapı yeniden kontrol edilmeli. Aşağıdaki örnek 0.2.2 (13) içindir.

```sh
cd /Users/berkinefeavci/Desktop/second-brain/Aktif/AI-Calisma/Claude/gece-vardiya/2026-10-24-kredi-codex/wt/panellight-yayin-hazirlik
swift test
SIGN_IDENTITY='Developer ID Application: BERKIN EFE AVCI (A7V9NP35W2)' ./scripts/build-app.sh
codesign --verify --deep --strict dist/PanelLight.app
codesign -dv --verbose=4 dist/PanelLight.app
mkdir -p release
ditto -c -k --sequesterRsrc --keepParent dist/PanelLight.app release/PanelLight-0.2.2-notary.zip
```

## Apple'a gönderim — ayrıca onay gerekli

```sh
xcrun notarytool submit release/PanelLight-0.2.2-notary.zip --keychain-profile cellkeep-notary --wait
# Yalnız sonuç Accepted ise devam:
xcrun stapler staple dist/PanelLight.app
xcrun stapler validate dist/PanelLight.app
spctl --assess --type execute --verbose=4 dist/PanelLight.app
ditto -c -k --sequesterRsrc --keepParent dist/PanelLight.app release/PanelLight-0.2.2.zip
(cd release && shasum -a 256 PanelLight-0.2.2.zip > PanelLight-0.2.2.zip.sha256 && shasum -a 256 -c PanelLight-0.2.2.zip.sha256)
```

Temiz/önceki kurulum ve indirilen karantinalı dosyada Gatekeeper ayrıca denenmeli. Yerel spctl sonucu indirilen dosya kabulü yerine geçmez. Eski release klasöründeki 0.2.0 ZIP yeni aday değildir.

## Push / GitHub release — ayrıca onay gerekli

İnceleme, final commit, Swift testleri, fiziksel kabul, imza/noter ve paket checksum kanıtı tamamlandıktan sonra. Yeni commit varsa aşağıdaki RELEASE_COMMIT final kaynak commit'i olmalı. Dalın yayın tabanı olarak kullanılması ayrıca onaylanmalı; bu taslak main'e birleştirme yapmaz.

```sh
git status --short
RELEASE_COMMIT=$(git rev-parse HEAD)
git push https://github.com/berkinefeavci/PanelLight.git gece/panellight-yayin-hazirlik
# Önce uzakta v0.2.2 var mı kontrol et; varsa dur, üzerine yazma.
gh release view v0.2.2 --repo berkinefeavci/PanelLight
# Üstteki komutun yalnız etiket yokluğu nedeniyle başarısız olduğu teyit edilirse:
gh release create v0.2.2 release/PanelLight-0.2.2.zip release/PanelLight-0.2.2.zip.sha256 --repo berkinefeavci/PanelLight --target "$RELEASE_COMMIT" --title 'PanelLight 0.2.2' --notes-file docs/yayin-hazirlik/release-notes-draft.md --draft
# Taslak dosyaları/etiket/indirme checksum'u kontrol edilip yayın onayı verildikten sonra:
gh release edit v0.2.2 --repo berkinefeavci/PanelLight --draft=false
```

Remote origin hâlâ MonitorBar URL'sini kullanıyor; değiştirilmedi. Komutlar açık PanelLight URL'sini kullanır. Yetki ve GitHub canlı durumu teyit edilmedi.

Yayın sonrası öneri: Berkin ilk 30 dakika içinde ikinci cihazda indir/kur, SHA-256, Issues ve güncelleme bağlantısını kontrol etsin. Bu sahip/zaman önerisi henüz onaylanmadı.
