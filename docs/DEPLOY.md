# Deployment — Coucou / NotchBuddy

Panduan build, code signing, notarization, dan distribusi aplikasi Coucou untuk macOS.

## Persyaratan

- macOS dengan Xcode 15+ dan XcodeGen (`brew install xcodegen`).
- Sertifikat **Developer ID Application** dan **Developer ID Installer** (dari Apple Developer Portal).
- Notarization: Apple ID dengan App-Specific Password, atau keychain profile (`coucou-notary`).

## Build

```bash
cd NotchBuddy
xcodegen
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme NotchBuddy -configuration Debug build
```

Build Debug tidak memerlukan code signing. Untuk rilis, gunakan `scripts/release.sh`.

## Rilis (Release)

```bash
./scripts/release.sh 1.2.3
```

Alur `scripts/release.sh`:

1. Mencari identitas **Developer ID Application** di keychain.
2. `xcodegen` + build `Release` dengan code signing.
3. Zip aplikasi → `notarytool submit` → stapel (`stapler staple`).
4. Buat DMG (opsional, jika `create-dmg` tersedia).
5. Generate checksum **SHA-256** (digunakan untuk verifikasi auto-update).
6. Buat git tag `v1.2.3`, push, dan buat GitHub Release dengan zip sebagai asset.

Checksum SHA-256 dicetak ke terminal dan dimasukkan ke `appcast`/metadata update agar `AutoUpdate` dapat memverifikasi integritas DMG setelah diunduh.

## Auto-update

Coucou mengecek `https://api.github.com/repos/louisraille/coucou/releases/latest` (atau repo yang dikonfigurasi) saat pengguna menekan **Cek pembaruan** di Settings → Enterprise.

Alur update:

1. Ambil rilis terbaru, bandingkan versi dengan `CFBundleShortVersionString`.
2. Jika ada versi baru: unduh `.dmg` aset, verifikasi **SHA-256** terhadap nilai yang terdaftar di aset release.
3. Jika cocok: salin `Coucou.app` ke `/Applications`, lalu restart aplikasi.

Secret/API key tidak terlibat di sini — GitHub API publik tidak memerlukan autentikasi untuk release publik (rate-limited).

## Crash reporter

Semua exception tak tertangkap ditangkap oleh `CrashReporter` dan ditulis ke:

```
~/Library/Application Support/NotchBuddy/crashes/reports.json
```

Laporan dapat dilihat/dihapus di Settings → Enterprise / Produksi. Laporan tidak dikirim ke server mana pun (tidak ada telemetry).

## Konsent & Kebijakan (PolicyEngine)

Mode konsent tersimpan di UserDefaults (`autopilotEnabled`). Default: **autopilot** (shell, email, network berjalan otomatis; file write dan app control tanya sekali per sesi).

**Hard floor** — tidak dapat di-override, tidak ada autopilot yang boleh melampaui:
- `sudo`
- `rm -rf` ke `/`, `~`, atau `$HOME`
- `diskutil erase*`
- pipe download ke shell (`curl|sh`)
- tulis `~/.claude/settings.json` (kecuali alur backup + diff + konfirmasi)

Semua eksekusi alat dicatat ke `<Application Support>/NotchBuddy/audit.jsonl`.

## Signing & Notarization (ringkas)

- Kode ditandatangani dengan **Developer ID Application**.
- Aplikasi di-notarize melalui Apple Notary Service (`notarytool`) dan di-stapel (`stapler`).
- Gatekeeper (`spctl -a -vv`) harus lolos sebelum rilis dirilis.

## Struktur direktori rilis

```
Coucou-$VERSION.dmg   (opsional, drag-and-drop ke /Applications)
Coucou.zip            (aset GitHub Release, disertai SHA-256)
```

## Build dari sumber (pengembang)

```bash
brew install xcodegen
git clone https://github.com/louisraille/coucou.git
cd coucou/NotchBuddy
xcodegen && open NotchBuddy.xcodeproj
```

Build Debug tidak memerlukan sertifikat signing. Untuk arsip rilis, sertifikat Developer ID wajib.
