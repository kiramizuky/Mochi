# Rencana Perbaikan dan Pengembangan Windows

Dokumen ini adalah rencana untuk mematangkan aplikasi Windows di `windows/`.
Targetnya adalah aplikasi Coucou/Mochi dapat dibangun, diuji, dipasang, dan
didistribusikan dengan aman pada Windows 10/11, kemudian berkembang menuju
paritas fitur macOS secara bertahap.

## Status implementasi (26 Oktober 2026)

| Fase | Status | Catatan |
|---|---|---|
| 0 — Baseline build | Selesai untuk build/CLI | `npm ci`, `cargo test --workspace`, `npm run build`, `npm run smoke:hook`, dan `npm run pack` lulus di mesin dev Windows. GUI dijalankan lewat smoke test aplikasi; belum ada UAT pada mesin bersih. Versi toolchain dicatat di `windows/README.md`. |
| 1 — Aset dan hardening | Selesai | 28 WAV orisinal ada di `shared/sounds/`, build gagal bila ada yang hilang, `msSmartScreenProtection` dihapus, CSP ditinjau, relay di-bundle dan di-smoke-test, uninstall hanya membersihkan data disposable. |
| 2 — Test dan CI Windows | Selesai kecuali run CI pertama | 37 test TypeScript + 68 test Rust lulus. Smoke test aplikasi (9 pemeriksaan: island, geometri panel/wake strip + always-on-top, IPC frontend, Settings, frontend Settings + kartu Welcome, tray, relay, file drop Unicode) berjalan lokal pada build debug dan release. Workflow `.github/workflows/windows.yml` menjalankan seluruh test, smoke aplikasi, dan mengunggah installer + SHA-256. UAT instalasi otomatis tersedia dan lulus lokal. Belum: run pertama di GitHub Actions dan verifikasi pada mesin Windows 10/11 bersih. |
| 3 — Signing dan distribusi | Sebagian | Pipeline signing selesai dan tervalidasi dengan sertifikat self-signed sementara (PFX + thumbprint + timestamp RFC 3161), termasuk verifikasi `signtool /pa /all`. Urutan rilis kini benar: build tanpa bundle, signing binary, bundling dengan `--no-binary-patching`, signing installer, lalu menandatangani ulang installer final untuk updater dan menulis `latest.json`. Belum: sertifikat Authenticode nyata, secret `WINDOWS_SIGNING_PFX_BASE64`/`WINDOWS_SIGNING_PFX_PASSWORD` serta `TAURI_SIGNING_PRIVATE_KEY`/`TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, artefak signed dari CI, publikasi GitHub Release, dan UAT Windows 10/11 tanpa toolchain. Installer lokal tetap unsigned. |
| 4 — Paritas fitur inti | Selesai secara lokal | 4.1 selesai: registry Anthropic/OpenAI/Gemini/Groq/lokal, key per provider di Credential Manager, model selector dinamis dengan fallback statis, dan endpoint lokal tervalidasi. 4.2 selesai: status kesehatan integrasi di Settings, log disanitasi dengan rotasi 1 MB, ekspor log aman, dan crash report lokal yang disanitasi (tanpa upload). 4.4 selesai: kartu onboarding pertama kali serta pemilihan editor/terminal dengan deteksi otomatis dan peluncur tervalidasi. 4.3 selesai untuk infrastruktur: `tauri-plugin-updater`, manifest GitHub Releases bertanda tangan minisign, cek manual dan otomatis di Settings, progress instalasi, serta feed lokal khusus debug. Kanal stabil tetap ditahan sampai Authenticode dan UAT tersedia. |
| 5 — Fitur lanjutan/otonom | Fondasi 5.0 + Sentinel & Memory Selesai | RFC 5.0 (`0001`) selesai diimplementasikan: gate policy default-deny (`policy.rs`, `gate.rs`), normalisasi scope Windows, consent timeout 30s (`consent.rs`), audit trail lokal berantai HMAC-SHA-256 (`audit.rs`), hard stop kill switch persisten (`killswitch.rs`). Ditambahkan Paket 5 Network Sentinel & Security Audit (`sentinel.rs`), serta JARVIS Long-Term Memory (`memory.rs`). 82 test Rust lulus. |

Perintah verifikasi cepat dari `windows/`:

```powershell
npm ci
npm run verify            # versi, typecheck, 37 test TS, 28 WAV
cargo test --workspace    # 82 test Rust (78 lib + 3 hook + 1 cek signature rilis)
npm run build             # typecheck + bundle front end + hook release
npm run smoke:hook        # relay aman saat Mochi ditutup
npm run smoke:app         # 9 pemeriksaan runtime pada build release
npm run sign:smoke        # pipeline signing dengan sertifikat sementara
npm run uat:install       # install, launch, smoke, uninstall, cleanup
npm run pack              # installer NSIS + file .sha256 (Mochi-Windows-<versi>-setup.exe)
npm run feed:updater      # latest.json dari installer + signature final
npm run feed:serve        # feed lokal untuk menguji cek update (debug)
```

`npm run smoke:app` memerlukan `cargo build --release -p mochi --features custom-protocol`
karena `cargo build` biasa menghasilkan build dev Tauri. `npm run pack` menghasilkan
`windows/release/Mochi-Windows-<versi>-setup.exe` beserta sidecar `.sha256`.
Package identifier Windows diset ke `id.pcstudio.mochi` dengan nama produk `Mochi`.
Installer dari build lokal belum ditandatangani Authenticode, jadi SmartScreen
akan menampilkan peringatan sampai rilis signed dari CI tersedia.

Target platform rilis: **Windows 10 versi 1809 (build 17763) atau lebih baru,
atau Windows 11; x86_64; WebView2 Runtime 110.0.1587.0 atau lebih baru.**
Installer memakai `downloadBootstrapper` senyap dan akan memperbarui WebView2
bila versinya lebih lama, sehingga instalasi pertama pada mesin tanpa WebView2
memerlukan koneksi internet.

## Temuan audit awal (sebelum perbaikan)

Daftar ini adalah kondisi saat audit pertama dan disimpan sebagai jejak. Temuan
build, aset audio, CI, SmartScreen, pipeline signing, onboarding, health
integrasi, serta editor/terminal sudah diselesaikan; sisa gap yang masih terbuka
tercatat pada tabel status dan checklist UAT di bawah.

- Build belum dapat dijalankan pada mesin audit karena `rustc` dan `cargo` belum
  tersedia pada `PATH`.
- Dependency frontend belum diinstal; `npm ls` melaporkan seluruh dependency
  sebagai `UNMET DEPENDENCY`.
- Tidak ada aset audio WAV dalam repository, sedangkan `windows/vite.config.ts`
  mengharapkan `NotchBuddy/Resources/sounds`. Build akan tetap selesai tetapi
  aplikasi tidak memiliki efek suara.
- Belum ada workflow CI Windows yang terlacak, dan belum ada test TypeScript,
  test UI, atau test installer end-to-end.
- Jalur rilis Windows belum memiliki code signing. Hal ini selaras dengan
  dokumentasi bahwa installer unsigned pernah diperingatkan Microsoft Defender.
- `additionalBrowserArgs` saat ini menonaktifkan `msSmartScreenProtection`.
  Opsi tersebut tidak boleh dipakai dalam build rilis.
- Port Windows tertinggal dari pengembangan macOS: fitur otonom, health/status
  integrasi, voice, MCP, memory/RAG, audit/policy, Telegram, updater, onboarding,
  serta otomasi layar belum tersedia.

## Prinsip implementasi

- Tidak boleh memblokir Claude Code. Jika app, named pipe, atau UI tidak siap,
  `coucou-hook.exe` harus keluar sukses tanpa memperlambat sesi pengguna.
- Secret hanya berada di Windows Credential Manager; jangan memasukkan API key
  ke `settings.json`, log, bundle, atau test fixture.
- Perubahan `%USERPROFILE%\\.claude\\settings.json` harus tetap memakai preview,
  fingerprint, backup bertanggal, dan merge tanpa merusak hook milik pengguna.
- Semua perilaku khusus Windows harus diuji pada DPI tinggi, multi-monitor, dan
  terminal PowerShell, Windows Terminal, Git Bash, serta VS Code.
- Fitur berisiko (kontrol aplikasi, file write, shell, screen capture, agent
  otonom) hanya dipindahkan bersama policy, audit log, dan consent UI yang jelas.

## Fase 0 — Menyiapkan baseline build

Tujuan: setiap pengembang Windows dapat membangun dan menjalankan aplikasi dari
checkout bersih.

1. Instal dan dokumentasikan prasyarat:
   - Windows 10/11 64-bit dan WebView2 Runtime.
   - Node.js 20 LTS atau lebih baru.
   - Rust stable dengan target `x86_64-pc-windows-msvc`.
   - Visual Studio Build Tools dengan workload **Desktop development with C++**
     dan Windows SDK.
2. Dari direktori `windows/`, jalankan `npm ci` agar versi dependency sesuai
   `package-lock.json`.
3. Jalankan `cargo test --workspace`, `npm run build`, dan `npm run tauri dev`.
4. Catat versi Node, npm, Rust, Cargo, MSVC, dan Windows SDK yang lulus dalam
   README atau dokumen developer setup.
5. Perbaiki setiap error kompilasi sebelum pekerjaan fitur baru dimulai.

Kriteria selesai:

- `npm ci` berhasil pada checkout bersih.
- `cargo test --workspace` dan `npm run build` lulus.
- `npm run tauri dev` membuka island dan Settings tanpa console error.

## Fase 1 — Memperbaiki aset dan hardening runtime

Tujuan: build produksi berisi semua aset yang dibutuhkan dan tidak melemahkan
proteksi Windows.

1. Putuskan lokasi aset audio lintas-platform, disarankan `shared/sounds/`.
   Pindahkan atau tambahkan 28 WAV dengan lisensi yang sesuai, lalu ubah
   `SOUNDS_DIR` di `windows/vite.config.ts` dan referensi build macOS bila perlu.
2. Tambahkan validasi build yang gagal bila jumlah atau nama WAV tidak sesuai
   `SOUND_NAMES` di `windows/src/core/sound.ts`.
3. Hapus `--disable-features=msSmartScreenProtection` dari konfigurasi Tauri.
   Pertahankan hanya argumen WebView yang benar-benar diperlukan dan terdokumentasi.
4. Verifikasi CSP untuk koneksi Tauri, API Anthropic, dan integrasi. Jangan
   membuka wildcard origin atau mengizinkan navigasi URL tanpa validasi.
5. Uji `coucou-hook.exe` pada build dev, executable release langsung, dan build
   NSIS. Pastikan `ensure_hook_exe` selalu menemukan resource yang dibundel.
6. Pastikan uninstall hanya membersihkan data aplikasi yang memang disposable
   (`bin`, inbox, log beserta rotasi/ekspor, dan crash report), tidak mengubah
   hooks Claude milik pengguna, dan tidak
   menghapus Credential Manager tanpa persetujuan pengguna.

Kriteria selesai:

- Audio tersedia di `dist/sounds` dan berfungsi pada installer yang dipasang.
- Tidak ada argumen yang menonaktifkan SmartScreen pada build production.
- Hook dapat dipasang, menerima event, dan fallback aman saat aplikasi ditutup.

## Fase 2 — Pengujian dan CI Windows

Tujuan: regresi utama terdeteksi sebelum artefak sampai ke pengguna.

1. Perluas Rust unit test untuk:
   - merge/uninstall hooks dan backup `settings.json`;
   - named-pipe timeout, denial, dan isolasi SID;
   - pemrosesan file drop serta pembersihan inbox;
   - penyimpanan settings, secrets, URL validation, dan response API.
2. Tambahkan test TypeScript untuk FSM island, layout, state, bridge, render
   settings, dan event hooks. Gunakan runner yang kompatibel dengan Vite.
3. Tambahkan smoke test Tauri untuk boot, tray, Settings, hook relay, dan file
   drop. Test visual dapat memakai screenshot baseline pada resolusi/DPI tetap.
4. Tambahkan workflow CI Windows dengan tahap:
   - checkout;
   - setup Node dan Rust MSVC;
   - `npm ci`;
   - lint/typecheck dan test frontend;
   - `cargo test --workspace`;
   - `npm run build`;
   - `npm run pack` pada workflow manual atau tag.
5. Simpan installer dan checksum sebagai artifact CI. Jangan menyimpan sertifikat
   signing dalam artifact atau log.

Kriteria selesai:

- Pull request menjalankan build dan seluruh test Windows secara otomatis.
- Build gagal jika audio hilang, typecheck gagal, unit test gagal, atau bundle
  hook tidak dapat ditemukan.
- Artifact installer dapat diunduh dari workflow manual untuk UAT internal.

Catatan status (26 Oktober 2026): langkah 1–3 dan 5 selesai. Smoke test Tauri
berjalan di dalam aplikasi (`COUCOU_SMOKE_TEST=1`) dan memeriksa island, geometri
panel/wake strip pada DPI nyata, IPC frontend, Settings, frontend Settings dengan
kartu Welcome pertama kali (profil `%APPDATA%` bersih), tray, relay, serta file
drop; baseline screenshot visual belum dibuat. Langkah 4 selesai di repository,
tetapi workflow belum pernah berjalan di GitHub Actions. UAT instalasi otomatis
lulus pada mesin dev; UAT Windows 10/11 bersih masih menjadi prasyarat rilis.

## Fase 3 — Packaging, signing, dan distribusi

Tujuan: installer dapat dipasang tanpa peringatan keamanan yang tidak perlu dan
punya jejak rilis yang dapat diaudit.

1. Buat proses release Windows terpisah dari `scripts/release.sh` yang khusus
   macOS. Implementasikan dengan PowerShell atau workflow CI Windows.
2. Gunakan sertifikat Authenticode terpercaya dan timestamp server untuk:
   - `coucou.exe`;
   - `coucou-hook.exe`;
   - installer NSIS `Coucou-Windows-<versi>-setup.exe`.
3. Verifikasi signature menggunakan `signtool verify /pa /all` dan publikasikan
   SHA-256 installer.
4. Tambahkan metadata release: versi semantik yang sama pada `package.json`,
   `tauri.conf.json`, dan Cargo workspace; release notes; arsitektur; minimum OS.
5. Lakukan UAT pada Windows 10 dan Windows 11 tanpa toolchain developer.
6. Bila Defender masih memberi false positive, submit binary signed melalui kanal
   Microsoft dan rekam hasilnya pada issue/release internal.

Kriteria selesai:

- Semua executable dan installer valid Authenticode serta timestamped.
- Installer dapat install, launch, update/uninstall pada akun user biasa.
- Rilis memiliki checksum, changelog, dan artifact yang berasal dari CI.

Catatan status (26 Oktober 2026): langkah 1–4 selesai di repository. Skrip
`sign.ps1`, `verify-signature.ps1`, `sign-smoke.ps1`, dan `uat-install.ps1`
tervalidasi lokal, termasuk PFX, thumbprint, timestamp, dan pembersihan
sertifikat sementara. Workflow `.github/workflows/windows-release.yml` memakai
urutan yang tidak membatalkan signature: build `--no-bundle`, signing
`coucou.exe`/`coucou-hook.exe`, bundling dengan `--no-binary-patching`, signing
installer, lalu menandatangani ulang installer final dengan kunci updater
(`tauri signer sign --app-version`), menulis `latest.json`, dan memverifikasi
Authenticode serta signature updater sebelum publikasi. Langkah 5–6 belum dapat
diselesaikan tanpa sertifikat Authenticode nyata, secret repository, kunci
updater produksi, serta mesin Windows 10/11 bersih.

## Fase 4 — Paritas fitur inti macOS

Tujuan: fitur yang paling terlihat dan paling berguna konsisten antar-platform.

Urutan prioritas:

1. Sinkronisasi model dan provider AI:
   - registry untuk Anthropic, OpenAI, Gemini, Groq, dan provider lokal;
   - model selector dinamis dan fallback yang aman;
   - rotasi key/rate-limit bila memang diperlukan oleh versi macOS.
2. Settings dan observability:
   - status kesehatan integrasi;
   - crash report lokal yang tidak mengirim data tanpa consent;
   - log yang disanitasi, dibatasi ukurannya, dan mudah diekspor pengguna.
3. Auto-update Windows:
   - cek update dari kanal rilis yang ditandatangani;
   - verifikasi signature/hash sebelum instal;
   - tampilkan consent dan rollback/error state yang jelas.
4. Fitur pengalaman pengguna:
   - onboarding Windows;
   - pemilihan editor/terminal yang lebih lengkap;
   - penyempurnaan multi-monitor, DPI, suspend/resume, dan accessibility keyboard.

Kriteria selesai:

- Fitur inti yang dipilih memiliki setting, test, log aman, dan dokumentasi.
- Perbedaan dari macOS dicatat eksplisit dalam `windows/README.md`.

Catatan status (26 Oktober 2026): langkah 1 selesai. Anthropic, OpenAI, Gemini,
Groq, dan endpoint lokal OpenAI-compatible tersedia dari satu chat. Setiap
provider punya slot key sendiri di Credential Manager (`anthropic-api-key`,
`openai-api-key`, `gemini-api-key`, `groq-api-key`, `local-api-key`), dan
`settings.json` tidak pernah memuat secret. Daftar model diambil dari API provider
bila memungkinkan, lalu jatuh ke katalog statis bila key, jaringan, atau respons
tidak tersedia. Endpoint lokal hanya menerima URL `http`/`https` absolut.

Langkah 2 selesai. Settings menampilkan status per integrasi (off, butuh key,
menunggu poll pertama, sehat dengan waktu cek terakhir, atau error yang sudah
disanitasi). Log lokal dibatasi 1 MB dengan satu file rotasi, setiap baris
disanitasi (token dan header otorisasi diredaksi, control character dihilangkan,
panjang baris dibatasi), dan tombol **Export log** menulis salinan bersih
maksimal 512 KB yang bisa dibuka lewat **Open log folder**. Panic Rust juga
ditulis ke `%LOCALAPPDATA%\Coucou\crashes\reports.json` (maksimal 50 laporan,
setiap field disanitasi, tidak pernah dikirim); Settings menampilkan tiga laporan
terbaru dengan tombol **Open crash folder** dan **Clear crash reports**.
Navigasi antarmuka Settings kini mengadopsi arsitektur Multi-Tab (General, AI & Models, Integrations, Security & Sentinel, Memory, System & Logs) dengan navigasi keyboard (ArrowLeft/ArrowRight), ikon visual, dan persistensi tab aktif via localStorage, menghilangkan scroll vertikal panjang.

Langkah 4 selesai untuk onboarding dan pemilihan editor/terminal. Pada
peluncuran pertama Settings terbuka dengan kartu
**Welcome** tiga langkah (key provider, hooks Claude Code, editor/terminal), dan
kartu itu bisa diselesaikan atau dilewati. Bagian **Editor & terminal** memilih
editor (Visual Studio Code, Cursor, Windsurf, Antigravity, atau auto-detect) dan
terminal (Windows Terminal, Windows PowerShell, PowerShell 7, Git Bash, Command
Prompt, atau auto-detect). Deteksi memakai lokasi instalasi umum dan `PATH`;
hanya executable dari katalog tetap yang bisa dijalankan, dan folder sesi
divalidasi sebagai direktori absolut yang ada sebelum diteruskan sebagai argumen
terpisah (tanpa `cmd /C`). Bila editor tidak ditemukan, folder dibuka di
Explorer. Render kartu Welcome dan bagian editor/terminal ikut diperiksa smoke
test; peluncuran editor/terminal nyata serta penyempurnaan DPI, multi-monitor,
suspend/resume, dan accessibility keyboard masih menunggu UAT manual.

Langkah 3 (auto-update) selesai pada tingkat infrastruktur. `tauri-plugin-updater`
membaca manifest `latest.json` dari
`https://github.com/kiramizuky/Mochi/releases/latest/download/latest.json`,
memverifikasi installer dengan kunci minisign yang tertanam di
`tauri.conf.json`, dan memasangnya lewat NSIS `passive` hanya setelah klik
**Install** di Settings. `requireSignedVersion` mengikat signature ke versi yang
diumumkan, sehingga manifest yang menukar nomor versi ditolak. Cek otomatis
berjalan saat Settings dibuka (bukan saat boot, dan tidak sama sekali pada smoke
mode); cek manual selalu tersedia. Build lokal tetap tanpa kunci updater karena
`createUpdaterArtifacts` hanya diaktifkan oleh `tauri.release.conf.json`.
Endpoint hanya bisa dioverride oleh build debug lewat `COUCOU_UPDATER_ENDPOINT`
(HTTPS atau loopback HTTP); build release mengabaikannya. Feed lokal dapat diuji
dengan `npm run feed:serve` + `npm run tauri dev`. Kanal stabil tetap ditahan
sampai Authenticode, kunci updater produksi, dan UAT tersedia.

Belum: rotasi multi-key/rate-limit otomatis per provider; UAT auto-update pada
Windows 10/11 dan publikasi rilis beta bertanda tangan.

## Fase 5 — Fitur lanjutan dan otonom

Tujuan: memindahkan fitur macOS yang kompleks tanpa menurunkan keamanan.

Fitur berikut tidak boleh dipindahkan sekaligus. Buat RFC singkat dan threat
model untuk masing-masing sebelum implementasi:

- policy engine dan audit log;
- MCP client/server;
- vector memory/RAG;
- voice input, TTS, dan duplex conversation;
- Telegram gateway;
- filesystem/clipboard watcher;
- autonomous workflow, dynamic tools, dan multi-agent orchestration;
- screen capture, visual grounding, serta kontrol aplikasi Windows.

Urutan yang disepakati: **fondasi (policy, audit, consent, kill switch) → MCP
client → clipboard/filesystem watcher → voice/TTS → memory/RAG → Telegram →
autonomous/dynamic tools → screen/app automation.** RFC 5.0
([`rfc/0001`](rfc/0001-phase5-foundation-policy-audit-consent-killswitch.md))
dan threat model-nya
([`threat-models/0001`](threat-models/0001-phase5-foundation-policy-audit-consent-killswitch.md))
berstatus `Implemented` (fondasi 5.0 telah selesai diimplementasikan). Template RFC berikutnya ada di
[`rfc/0000-template.md`](rfc/0000-template.md) dan
[`threat-models/0000-template.md`](threat-models/0000-template.md). Fitur Phase 5 berikutnya (mulai dari MCP client) dapat dikembangkan di atas fondasi ini.

Untuk setiap fitur, definisikan:

1. API Windows yang dipakai dan dukungan minimum OS.
2. Izin/consent yang ditampilkan kepada pengguna.
3. Hard safety floor yang tidak boleh diabaikan.
4. Audit event lokal tanpa secret atau konten sensitif.
5. Tombol pause/kill switch dan perilaku ketika app crash.
6. Unit test, integration test, dan skenario abuse/failure.

## Matriks paritas yang perlu dipelihara

| Area | Windows saat ini | Rencana |
|---|---|---|
| Island, tray, animasi | Ada | Uji DPI, multi-monitor, dan accessibility. |
| Claude Code hooks | Ada | Tambah test end-to-end untuk tiap terminal. |
| Chat multi-provider | Ada (Anthropic, OpenAI, Gemini, Groq, lokal) | Tambah rotasi key/rate-limit dan health per provider. |
| Secrets | Credential Manager | Tambah coverage test dan UX pemulihan error. |
| File drop | Ada | Uji file besar, nama Unicode, locked file, dan cleanup. |
| Integrasi dasar | Ada | Health/status sudah tersedia; tinggal paritas konfigurasi terpilih. |
| Editor/terminal | Ada (VS Code, Cursor, Windsurf, Antigravity; Windows Terminal, PowerShell, pwsh, Git Bash, cmd) | Uji manual pada mesin dengan beberapa editor terpasang. |
| Onboarding | Ada (kartu tiga langkah saat pertama kali) | Render profil bersih dicakup smoke test; uji alur upgrade manual. |
| Audio | Ada (28 WAV CC0) | Pertahankan validasi build dan smoke test. |
| Auto-update | Ada (beta; manifest GitHub + minisign, cek/consent manual) | Kanal stabil setelah Authenticode, kunci produksi, dan UAT. |
| Policy/audit/consent/kill switch | Ada (Fondasi 5.0 selesai) | Siap menjadi gerbang otorisasi untuk konsumen Phase 5 berikutnya (MCP, watcher, dll.). |
| Network Sentinel & Security Audit | Ada (Paket 5 Blueprint) | Audit Windows Defender, Firewall, BitLocker, UAC, port listening, LAN discovery, dan diagnostik latensi/DNS. |
| Memory (JARVIS Long-Term Memory) | Ada (Phase 5) | Penyimpanan fakta pengguna terdesentralisasi di `%APPDATA%\Mochi\memory.json`, disuntikkan ke AI prompt. |
| Webcam & Persepsi Visual | Ada (Paket 6 & 7) | Modul `camera.rs` berbasis Windows MediaCapture API: deteksi webcam, penangkapan frame instan (<1s), proteksi privasi hardware (sensor dilepas seketika), kartu preview di Settings, dan integrasi Multimodal Vision VLM di chat. |
| Diagnostik Sistem PC | Ada (Paket 5/Status) | Monitoring performa real-time Windows (Beban CPU, RAM, Disk C:, status baterai, dan uptime) dengan visual progress bar. |
| Voice | Belum ada | RFC dan implementasi lintas API Windows. |
| MCP, autonomous tools | Belum ada | Port bertahap setelah policy/audit tersedia. |
| Screen/app automation | Belum ada | Implementasi terakhir, dengan consent dan kill switch. |

## Checklist UAT rilis

Status per 26 Oktober 2026. `[x]` berarti sudah dijalankan pada mesin dev
(Windows 11) atau dicakup otomatis; item yang menyebut Windows 10/11 bersih tetap
terbuka sampai diuji pada mesin tanpa toolchain.

- [x] Install dan uninstall per-user tanpa admin pada mesin dev, termasuk launch
  pertama, staging relay, smoke test, dan pembersihan data disposable
  (`npm run uat:install`).
- [ ] Install yang sama pada Windows 10 dan Windows 11 bersih tanpa toolchain.
- [x] Island, Settings, tray, relay, dan file drop Unicode diperiksa smoke test
  aplikasi otomatis (9 pemeriksaan), termasuk geometri panel/wake strip pada DPI
  mesin ini dan flag always-on-top.
- [ ] Autostart, pause, quit, dan interaksi tray diperiksa manual.
- [ ] DPI 100%, 125%, 150%, 200%; satu dan beberapa monitor. Geometri pada DPI
  mesin dev sudah dicakup smoke; variasi DPI dan monitor lain tetap manual.
- [ ] Wake strip, click-through, drag/drop, keyboard Esc, dan screen change.
  Ukuran/posisi wake strip sudah dicakup smoke; interaksi dan perpindahan
  monitor tetap manual.
- [ ] Hook install/uninstall serta event dari PowerShell, Windows Terminal, Git
  Bash, dan VS Code.
- [x] App mati atau named pipe gagal: relay exit 0 tanpa output, termasuk JSON
  rusak dan event PermissionRequest (`npm run smoke:hook`).
- [ ] Credential Manager menyimpan dan menghapus secret dengan benar.
- [ ] Kartu onboarding pada alur upgrade, peluncuran editor/terminal nyata, dan
  tombol **Open in editor** / **Open terminal** diperiksa manual pada mesin
  dengan beberapa editor dan terminal terpasang. Render kartu pada profil bersih
  sudah dicakup smoke test.
- [x] Pipeline signature lolos dengan sertifikat self-signed sementara: PFX,
  thumbprint, timestamp RFC 3161, dan `signtool verify /pa /all`
  (`npm run sign:smoke`).
- [x] Urutan rilis tidak membatalkan signature: binary ditandatangani sebelum
  bundling (`--no-binary-patching`), installer final ditandatangani Authenticode
  lalu ditandatangani ulang untuk updater dengan `--app-version`, dan
  `latest.json` diverifikasi terhadap kunci publik di `tauri.conf.json`
  (`cargo test --test updater_signature`).
- [ ] Installer dan executable signed nyata dari CI lolos verifikasi signature.
- [ ] Cek update dari feed beta bertanda tangan: Settings menampilkan versi baru,
  **Install** memverifikasi signature sebelum menjalankan installer, aplikasi
  restart, dan versi terpasang berubah. Versi/signature yang dimanipulasi di
  manifest harus ditolak.
- [ ] Cek otomatis hanya berjalan saat Settings dibuka (bukan saat boot), dan
  smoke mode tidak melakukan request jaringan.
- [x] Uninstall tidak mengubah `%APPDATA%\Coucou\settings.json` maupun
  `%USERPROFILE%\.claude\settings.json` (hash sebelum/sesudah di UAT).
- [ ] Tidak ada secret, command penuh, atau konten file sensitif dalam log
  maupun crash report.

## Definisi selesai untuk rilis Windows publik

Rilis Windows boleh dipublikasikan apabila Fase 0 sampai 3 selesai, seluruh
checklist UAT lulus, CI menghasilkan installer signed yang dapat dilacak, dan
perbedaan fitur terhadap macOS dijelaskan di README. Fase 4 dan 5 dapat berjalan
sebagai rilis minor setelah fondasi distribusi tersebut stabil.
