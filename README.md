# MacTTY

PuTTY'nin macOS için yerel (Cocoa) sürümü. Bağlantı, terminal ve ayar
mantığı PuTTY 0.85'in kendi kodudur; yalnızca pencere ve diyalog katmanı
AppKit ile yeniden yazılmıştır. Bu yüzden davranış, ayar seçenekleri ve
kayıtlı oturum biçimi PuTTY ile birebir aynıdır.

## Neler var

- **Bağlantı türleri:** SSH (SSH-2 ve SSH-1, tüm şifre/kex/host key
  seçenekleri, PPK anahtarları — OpenSSH anahtarı paketteki `puttygen` ile
  çevrilir —, sertifikalar, ssh-agent/Pageant, agent forwarding, port
  yönlendirme, X11, bağlantı paylaşımı, proxy), Telnet, Rlogin, SUPDUP,
  Raw, Seri hat (`/dev/cu.*`).
- **PuTTY Configuration penceresi:** solda kategori ağacı, sağda paneller,
  altta About / Open / Cancel. Paneller PuTTY'nin `config.c` tanımlarından
  çizildiği için tüm kategoriler ve seçenekler PuTTY'deki gibidir. Oturum
  sırasında "Change Settings" aynı kutuyu "Apply" ile açar.
- **Terminal:** PuTTY'nin terminal emülatörü (xterm/VT100), 16/256/24-bit
  renk, kalın/altı çizili/ters/üstü çizili/soluk metin, Unicode, CJK geniş
  karakterler, birleşik karakterler, çift genişlik ve çift yükseklik
  satırları, kaydırma geçmişi, fare raporlama, yeniden boyutlandırma.
- **Oturum menüsü:** PuTTY'nin sistem menüsü (Event Log, Special Command,
  New/Duplicate/Restart Session, Saved Sessions, Change Settings, Copy All
  to Clipboard, Clear Scrollback, Reset Terminal, Full Screen) hem menü
  çubuğunda hem terminalde Ctrl+tıkla açılan menüde.
- **Güvenlik uyarıları:** host key, zayıf şifre ve log dosyası soruları
  PuTTY'nin kendi metinleriyle.
- **Komut satırı araçları:** `plink`, `pscp`, `psftp`, `puttygen`,
  `pageant` uygulama paketinin içinde: `MacTTY.app/Contents/Resources/bin`.

## Derleme

Gerekenler: Xcode (komut satırı araçlarıyla), CMake, Ninja
(`brew install cmake ninja`).

```bash
./build.sh
```

Çıktı `build/MacTTY.app`. Hata ayıklama derlemesi için `./build.sh debug`.

## Kullanım

Uygulama PuTTY gibi önce ayar penceresiyle açılır. Komut satırından
PuTTY'nin seçenekleri geçer:

```bash
build/MacTTY.app/Contents/MacOS/MacTTY -ssh -l kullanici -P 22 sunucu.example.com
```

```bash
build/MacTTY.app/Contents/MacOS/MacTTY -load "Kayıtlı oturum"
```

Kayıtlı oturumlar `~/.putty/sessions`, bilinen host anahtarları
`~/.putty/sshhostkeys` altında tutulur; paketteki `plink`/`pscp`/`psftp`
aynı oturumları kullanır.

**Mac klavyesinde PuTTY tuşları**

| PuTTY (Windows) | MacTTY |
|---|---|
| Alt (Meta) | Option ("Option key acts as Meta", varsayılan açık) |
| Insert | Help tuşu (Shift+Help yapıştırır, Ctrl+Help kopyalar) |
| Ctrl+Break | Ctrl+F15 |
| Num Lock | Sayısal tuş takımındaki Clear |
| Alt+Enter (tam ekran) | Option+Return ("Full screen on Option-Return") |
| Alt+F4 | Command+W ("Window closes on Command-W") |
| Sistem menüsü | Ctrl+tık; "macOS" fare kipinde sağ tık |

Seçim PuTTY'deki gibi otomatik olarak panoya kopyalanır, sağ tık
yapıştırır. Command+C / Command+V de çalışır.

## Yapı

```
putty/      PuTTY 0.85 kaynağı (sha512 doğrulanmış resmi sürüm)
macos/      Cocoa ön yüzü
  inject.cmake     PuTTY'nin CMake'ine kendi hedefimizi ekler
  targets.cmake    MacTTY.app hedefi
  eventloop.m      uxsel / zamanlayıcı / toplevel callback → CFRunLoop
  TerminalView.m   CoreText çizimi, klavye ve fare çevirisi
  Session.m        TermWin, Seat, LogPolicy; oturum yaşam döngüsü
  ConfigDialog.m   dialog.h kontrol kutusu çizici ve dlg_* API
  Dialogs.m        güvenlik uyarıları, Event Log, About
  config-mac.c     Mac'e özgü ayar seçenekleri (windows/config.c karşılığı)
  platform-mac.m   platform varsayılanları, seri port listesi
  AppDelegate.m    menü çubuğu, açılış, komut satırı
```

PuTTY kaynağında tek değişiklik vardır: `putty/unix/platform.h` içinde
`MACTTY` profili (pano anlamı ve OS X Meta tuşu ayarı). PuTTY'nin yeni
sürümüne geçmek için `putty/` klasörünü yenisiyle değiştirip bu yamayı
yeniden uygulamak yeterlidir (`git log -p putty/unix/platform.h`).

## Henüz olmayanlar

- PuTTYgen ve Pageant'ın grafik arayüzleri (komut satırı sürümleri pakette).
- "When window is resized: Change the size of the font" seçeneği
  (satır/sütun değiştirme çalışıyor).
- Uzaktan yazdırma denenmedi.

## Lisans

PuTTY MIT lisanslıdır (`putty/LICENCE`); MacTTY de aynı lisansla
dağıtılır. PuTTY, copyright 1997-2026 Simon Tatham ve katkıda bulunanlar.
