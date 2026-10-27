# Changelog

## Unreleased

### Windows

- **Fondasi build Windows (Tauri 2)**: Baseline build kini dapat direproduksi dengan Rust 1.99.1 MSVC, Node 22.12+, dan Visual Studio 2026. `npm ci`, `cargo test --workspace`, `npm run build`, `npm run smoke:hook`, dan `npm run pack` lulus di mesin dev; versi toolchain dicatat di `windows/README.md`.
- **Aset audio orisinal lintas platform**: 28 isyarat WAV CC0 dibuat deterministik di `shared/sounds/` (menggantikan aset macOS yang proprietary). `windows/src/core/sound-names.ts` menjadi satu-satunya daftar nama cue, dan build Vite gagal bila ada cue yang hilang atau berlebih.
- **Hardening WebView2 dan CSP**: Argumen `--disable-features=msSmartScreenProtection` dihapus dari konfigurasi maupun pembuatan window Settings. CSP ditinjau ulang, dan `scripts/check-browser-args.mjs` memastikan argumen kedua window identik serta tidak pernah melemahkan SmartScreen.
- **Relay Claude Code yang tidak pernah memblokir**: `coucou-hook.exe` dibundel sebagai resource, disalin ke `%LOCALAPPDATA%\Coucou\bin`, dan diuji dengan 12 event plus JSON rusak saat Coucou tertutup — selalu exit 0 tanpa output. Build release gagal bila relay tidak ditemukan; build debug/test menyuntikkan resource hanya saat tersedia.
- **Suite pengujian Windows**: 37 test TypeScript (FSM island, layout, state, bridge, katalog suara) dan 64 test Rust (hooks/backup/fingerprint, timeout dan isolasi pipe, file drop Unicode, settings, secrets allowlist, validasi URL, parsing error API, ACK ganda, registry provider dan bentuk request/response AI, deteksi dan keamanan peluncur editor/terminal, geometri island untuk DPI/monitor, crash report).
- **Chat multi-provider**: Chat Windows kini mendukung Anthropic, OpenAI, Google Gemini, Groq, dan server lokal OpenAI-compatible (Ollama/LM Studio/MLX). Registry `providers_catalog` menyediakan nama, model default, dan katalog statis; `provider_models` mengambil daftar model live dari API provider dan jatuh ke katalog statis bila key/jaringan/respons tidak tersedia. Setiap provider punya slot key sendiri di Credential Manager (`anthropic-api-key`, `openai-api-key`, `gemini-api-key`, `groq-api-key`, `local-api-key`), dan `settings.json` tidak pernah memuat secret. Endpoint lokal hanya menerima URL `http`/`https` absolut dan default ke `http://127.0.0.1:11434/v1`. Lampiran PDF dikirim inline ke Anthropic/Gemini; provider chat-completions lain menerima catatan eksplisit karena API-nya tidak mendukung PDF.
- **Health integrasi dan ekspor log aman**: Settings → Integrations kini menampilkan status per integrasi (off, butuh key, menunggu poll pertama, sehat dengan waktu cek terakhir, atau error). Registry health in-memory mencatat hasil poll terakhir dan tidak pernah menyimpan isi respons. Log lokal menulis setiap baris lewat sanitizer (token `sk-`/`gsk_`/`AIza`/`ghp_`/`Bearer`, assignment `token=`/`password=` diredaksi, control character dibuang, baris dibatasi 2000 karakter), berputar pada 1 MB, dan **Export log** menulis salinan bersih maksimal 512 KB ke `coucou-log-export.txt`.
- **Crash report lokal**: Panic Rust ditangkap hook dan ditulis ke `%LOCALAPPDATA%\Coucou\crashes\reports.json` (maksimal 50 laporan, terbaru dulu) dengan timestamp, pesan, lokasi, thread, dan versi. Setiap field disanitasi sebelum disimpan dan dibaca; tidak ada laporan yang dikirim ke jaringan. Settings → **Crash reports** menampilkan tiga laporan terbaru, membuka folder, dan menghapus laporan. Pesan panic juga dicatat sebagai satu baris di log utama. Uninstaller membersihkan folder `crashes`, rotasi log, dan salinan ekspor bersama data disposable lainnya.
- **Onboarding dan pemilihan editor/terminal**: Peluncuran pertama membuka Settings dengan kartu **Welcome** tiga langkah (key provider, hooks Claude Code, editor/terminal) yang bisa diselesaikan atau dilewati; status onboarding disimpan di `settings.json`. Bagian **Editor & terminal** memilih editor (Visual Studio Code, Cursor, Windsurf, Antigravity, auto-detect) dan terminal (Windows Terminal, Windows PowerShell, PowerShell 7, Git Bash, Command Prompt, auto-detect), dengan deteksi lokasi instalasi umum dan `PATH`. Hanya id dari katalog tetap yang dapat dijalankan; folder sesi divalidasi sebagai direktori absolut yang ada dan diteruskan sebagai argumen terpisah tanpa shell, sehingga nama folder berisi `&`, `^`, atau `%` tetap aman. **Open in editor** memakai pilihan editor dan jatuh ke Explorer bila tidak ada editor; **Open terminal** membuka terminal pilihan di folder sesi.
- **CI Windows**: Workflow `.github/workflows/windows.yml` menjalankan pemeriksaan versi, WebView2 args, aset suara, typecheck, test, clippy, build, verifikasi aset, smoke relay, smoke aplikasi release, dan penjagaan SmartScreen. Installer NSIS beserta SHA-256 diunggah sebagai artifact untuk manual dispatch/tag.
- **Installer NSIS dan checksum**: `npm run pack` menghasilkan `Coucou-Windows-<versi>-setup.exe`, nama rolling `Coucou-Windows-setup.exe`, dan sidecar `.sha256`. Installer dari build lokal belum ditandatangani Authenticode; SmartScreen akan memperingatkan sampai rilis signed dari CI tersedia.
- **Smoke test runtime aplikasi**: `COUCOU_SMOKE_TEST=1` menjalankan sembilan pemeriksaan nyata di dalam aplikasi - island terlihat, geometri panel dan wake strip berada di atas-tengah monitor yang benar sesuai DPI serta tetap always-on-top, JavaScript frontend memanggil `ui_ready` lewat IPC, window Settings dapat dibuka, frontend Settings benar-benar merender dan menampilkan kartu Welcome pertama kali (dijalankan dengan `%APPDATA%` bersih), tray terdaftar, relay berhasil di-stage, permission request bolak-balik lewat named pipe sampai `allow`, dan file drop bernama Unicode tersalin ke inbox. Hasil ditulis sebagai JSON, `npm run smoke:app` mengatur timeout dan laporan, dan tidak ada settings, hook Claude, credential, atau data pengguna yang diubah.
- **Perbaikan ACK ganda pada relay**: ACK kedua dari island di fase keputusan sebelumnya jatuh ke cabang `_`, langsung dianggap timeout, dan membuang keputusan pengguna. Sekarang fase keputusan berulang sampai batas waktu absolut, dengan regression test `a_duplicate_ack_does_not_end_the_wait`.
- **Pipeline signing Authenticode**: `scripts/sign.ps1` mendukung PFX atau thumbprint sertifikat, SHA-256, timestamp RFC 3161, dan `-RequireSignature` untuk rilis. `scripts/verify-signature.ps1` menjalankan `signtool verify /pa /all` dan memeriksa timestamp. `scripts/sign-smoke.ps1` memvalidasi seluruh pipeline dengan sertifikat self-signed sementara (PFX + thumbprint) lalu membersihkan certificate store dan file sementara.
- **Workflow rilis bertanda tangan**: `.github/workflows/windows-release.yml` berjalan pada tag `v*` atau manual, mengimpor PFX ke `Cert:\CurrentUser\My`, menandatangani `coucou-hook.exe` dan `coucou.exe` sebelum bundling, menandatangani installer, memverifikasi semua signature, menulis checksum, mengunggah artifact, dan membuat GitHub Release. Password PFX tidak pernah masuk argumen command line, dan certificate/pfx dibersihkan pada langkah `always()`.
- **UAT installer per-user**: `npm run uat:install` memasang installer secara senyap tanpa admin, memeriksa entri registry dan versi, menjalankan smoke test terhadap binary terpasang, memastikan relay di-stage, lalu uninstall dan memverifikasi bahwa `%APPDATA%\Coucou\settings.json` serta `%USERPROFILE%\.claude\settings.json` tidak berubah dan data disposable (`bin`, `inbox`, log beserta rotasi/ekspor, crash report) hilang.
- **Metadata platform dan WebView2**: `tauri.conf.json` kini menetapkan `minimumWebview2Version` 110.0.1587.0 dan `webviewInstallMode` `downloadBootstrapper` senyap. Target rilis didokumentasikan sebagai Windows 10 1809+/Windows 11, x86_64; WebView2 yang lebih lama akan diperbarui otomatis saat instalasi.
- **Auto-update bertanda tangan (4.3)**: `tauri-plugin-updater` ditambahkan dengan manifest `latest.json` dari `https://github.com/kiramizuky/Mochi/releases/latest/download/latest.json`, kunci minisign publik di `tauri.conf.json`, `windows.installMode: "passive"`, dan `requireSignedVersion` sehingga manifest tidak bisa menukar nomor versi pada installer lama. Settings → **Updates** menampilkan versi baru dan catatan rilis, mengunduh hanya setelah klik **Install**, serta menampilkan progress; cek otomatis berjalan saat Settings dibuka (bukan saat boot) dan dilewati pada smoke mode. Override endpoint hanya berlaku di build debug dan hanya untuk HTTPS atau loopback HTTP; build release selalu memakai endpoint tetap. Build lokal tetap tanpa kunci updater karena `bundle.createUpdaterArtifacts` hanya diaktifkan lewat `tauri.release.conf.json`.
- **Urutan rilis yang tidak membatalkan signature**: Workflow rilis kini membangun dengan `--no-bundle`, menandatangani `coucou.exe`/`coucou-hook.exe`, membundel dengan `--no-binary-patching` agar binary yang sudah ditandatangani tidak dipatch ulang, menandatangani installer dengan Authenticode, lalu menandatangani ulang installer final dengan `tauri signer sign --app-version <versi>`. Ini penting karena Authenticode mengubah byte installer dan signature updater lama tidak lagi cocok. Workflow menulis `latest.json` lewat `scripts/updater-feed.mjs`, memverifikasi konsistensi manifest, memverifikasi Authenticode/timestamp, dan menjalankan test `updater_signature` yang memeriksa installer terhadap kunci minisign di `tauri.conf.json`. `scripts/pack.mjs` hanya menyalin signature yang lebih baru dari installer dan terikat ke versi yang sama; signature lama dari bundling sebelumnya dihapus, sehingga rebuild tidak pernah menerbitkan `.sig` yang tidak cocok. Secret baru: `TAURI_SIGNING_PRIVATE_KEY` dan `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`; kunci ini terpisah dari sertifikat Authenticode dan harus dibackup offline.
- **Feed updater lokal untuk pengujian**: `npm run feed:updater` membuat `latest.json` dari installer + `.sig`, sedangkan `npm run feed:serve` menyajikan `windows/release/` di loopback. Debug build dapat diarahkan lewat `COUCOU_UPDATER_ENDPOINT`; release build mengabaikannya. Kunci updater pengembangan (`coucou-updater-dev.key`) hanya untuk beta/lokal, bukan rilis stabil.
- **Tata kelola RFC dan threat model Phase 5**: `docs/rfc/` dan `docs/threat-models/` kini berisi template, indeks, dan RFC 5.0 `0001` beserta threat model-nya. RFC tersebut menetapkan fondasi default-deny: satu gate `security::gate::authorize` dengan `ActionGrant` opaque, policy `security.json` berversi, consent card 30 detik dengan token sekali pakai dan scope terstruktur, audit JSONL lokal dengan field allowlist + rantai HMAC, serta kill switch yang persisten melewati restart. Tidak ada fitur Phase 5 berisiko yang diimplementasikan sebelum RFC terkait berstatus `Accepted`; urutan yang disepakati adalah fondasi → MCP → watcher → voice → memory/RAG → Telegram → autonomous → screen automation.
- **68 test Rust**: Tiga unit test untuk endpoint updater ditambahkan, plus satu integration test `updater_signature` yang hanya berjalan saat artefak rilis tersedia dan memverifikasi installer final terhadap `latest.json` serta kunci publik di `tauri.conf.json`.

### macOS

- **Perbaikan Bug Timeout Kamera Webcam (FaceTime HD / USB Camera)**:
  - 📷 **Retensi Kuat Delegasi Kamera (`AVCaptureVideoDataOutputSampleBufferDelegate`)**:
    - Memperbaiki akar penyebab timeout kamera (*"waktu response kamera habis"*) saat pendaftaran wajah pemilik di menu Settings maupun saat capture foto/video.
    - `AVCaptureVideoDataOutput.setSampleBufferDelegate(_:queue:)` hanya menyimpan *weak reference* ke delegate. Mengimplementasikan pattern *self-retaining* (`selfRetain = self` & `releaseSelf()`) pada `SingleFrameGrabber` dan `VideoRecorderSession`, serta retensi eksplisit di `WebcamCaptureService.shared` (`activeDelegate` dan `activeSession`) sehingga delegate tidak ter-deallocate prematur oleh ARC.
    - Mengurangi ambang frame stabilisasi dari 4 frame menjadi 2 frame (`framesReceived >= 2`) untuk respon tangkapan foto instan (~150–300 ms).
    - Menjadwalkan penghentian sesi kamera (`session.stopRunning()`) secara asinkron di background thread agar tidak memblokir antrean delegate.

- **Peningkatan Respons Telegram: Format MarkdownV2 & Estetika Style Telegram**:
  - 🎨 **Format Jawaban MarkdownV2 Telegram (`TelegramFormatter.toMarkdownV2`)**:
    - Seluruh pesan teks balasan dari Mochi ke Telegram kini otomatis dikonversikan dan di-escape secara presisi ke format `MarkdownV2` Telegram (menjaga reserved characters `_`, `*`, `[`, `]`, `(`, `)`, `~`, `` ` ``, `>`, `#`, `+`, `-`, `=`, `|`, `{`, `}`, `.`, `!`).
    - Dilengkapi mekanisme *smart fallback*: bila `MarkdownV2` ditolak oleh Telegram Bot API karena karakter entitas, pesan otomatis dikirim ulang sebagai plain text bersih sehingga tidak ada pesan yang pernah hilang.
  - 🧠 **Format Laporan Sistem Singkat & Padat (`SystemMetrics` & `/status`)**:
    - Menghadirkan metrik RAM (digunakan, total, persentase) secara native via `Darwin.host_statistics64` (`HOST_VM_INFO64`), CPU Load (`HOST_CPU_LOAD_INFO`), dan sisa penyimpanan Disk secara instan tanpa child process bising.
    - Dilengkapi visual progress bar ringkas bergaya Telegram: `[■■■■■□□□] 69%`.
    - Laporan `/status` kini tampil elegan, terstruktur, dan langsung ke inti (tidak ditulis mentah atau apa adanya).
  - 🎯 **Peringkasan Hasil Tugas Otonom (`TelegramFormatter.formatTaskSummary`)**:
    - Hasil instruksi otonom diformat padat dengan status emoji (`✅` / `⚠️`), target instruksi monospace `` `...` ``, dan ekstraksi intisari output tanpa dump log berlebihan.


- **Perbaikan Bug Force Close / Crash Perintah Telegram & Thread-Safety Autonomous Agent**:
  - 🛡️ **Pencegahan Crash `_dispatch_assert_queue_fail` pada `AutonomousAgent.enabled`**:
    - Memperbaiki akar penyebab *crash* seketika (*SIGILL / Illegal Instruction 4*) saat perintah diterima via Telegram background cooperative pool. Sebelumnya `AutonomousAgent.enabled` memanggil `MainActor.assumeIsolated` tanpa memeriksa apakah thread saat itu adalah main thread.
    - Mengganti akses property `enabled` dengan pengecekan thread-safe: jika berada di main thread menggunakan `MainActor.assumeIsolated`, dan jika di background thread membaca langsung `UserDefaults.standard` (`autonomousEnabled`), sehingga 100% aman dan tidak pernah memicu kegagalan antrean.
  - 📸 **Toleransi Perintah Screenshot & Tangkapan Layar Telegram**:
    - Mendukung variasi dan toleransi salah ketik pengguna pada perintah tangkapan layar Telegram: `/screenshot`, `/screenshoot` (dengan double 'o'), `/ss`, `/capture`, dan `/screen`.
    - Mengintegrasikan pengiriman file gambar via `sendPhoto` terpusat dengan MIME type yang tepat (`image/png`).
  - 📷 **Perintah Baru Telegram untuk Kamera Webcam (`/camera`, `/photo`, `/webcam`)**:
    - Menambahkan perintah remote langsung di Telegram untuk mengambil foto webcam FaceTime MacBook (`/camera`, `/photo`, `/webcam`) dan mengirim foto resolusi tinggi ke obrolan Telegram.
  - ⚡ **Optimasi Diagnostik Sistem `collectMacStatus`**:
    - Memindahkan pemanggilan proses shell pembacaan status baterai `pmset -g batt` keluar dari `MainActor.run` agar tidak memblokir antarmuka pengguna (UI thread).

- **Perbaikan Total Webcam Capture, Perekaman Video FaceTime HD & Pendaftaran Wajah Pemilik (Face Enrollment)**:
  - 📸 **Pipeline Capture Frame Instan via `AVCaptureVideoDataOutput`**:
    - Memperbaiki akar masalah kegagalan pengambilan foto di macOS FaceTime HD Camera di mana `AVCapturePhotoOutput` sebelumnya hang tanpa batas waktu (*infinite timeout*) akibat pelepasan memori (*weak reference deallocation*) pada delegate lokal di macOS.
    - Mengganti pipeline capture menggunakan `AVCaptureVideoDataOutput` berkecepatan tinggi dengan warm-up sensor kamera 3-4 frame (auto-exposure & white balance otomatis stabil), memproduksi gambar JPEG berkualitas tinggi dalam waktu < 500ms.
    - Menambahkan pengaman timeout 6 detik dengan `CompletionGate` thread-safe murni yang patuh standar Swift 6 Strict Concurrency.
  - 🎥 **Fitur Perekaman Video Webcam Native (H.264 MP4)**:
    - Menghadirkan fungsi `recordVideo(durationSeconds:)` pada `WebcamCaptureService` menggunakan pipeline `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`.
    - Merekam video 24 fps terkompresi H.264 ke file container `.mp4` dengan durasi fleksibel (1 hingga 60 detik).
    - Otomatis mempublikasikan artefak video ke Canvas (`CanvasArtifact` tipe `.media`), memungkinkan pemutaran langsung dengan kontrol scrubber dan visualizer audio.
  - 👤 **Perbaikan & Optimalisasi Pendaftaran Wajah Pemilik (`FaceRecognitionService` & `SettingsView`)**:
    - Memperbaiki tombol "Daftarkan Wajah" pada menu Pengaturan (Settings) yang sebelumnya macet di status "Mengambil Foto...".
    - Meningkatkan presisi perhitungan skor kualitas biometrik menggunakan `VNDetectFaceCaptureQualityRequest` dan ekstraksi sidik wajah `VNGenerateImageFeaturePrintRequest`.
    - Pesan diagnostik yang jelas dan solutif jika wajah belum terlihat atau terhalang pencahayaan.
    - Menyediakan tombol uji coba langsung di menu Pengaturan: **"Ambil Foto Webcam"** dan **"Rekam Video (3s)"** dengan status visual real-time dan preview instan di Canvas.
  - 🛠️ **Tool Baru & Alias Gemini API (`camera_record_video`)**:
    - Tool baru `camera_record_video` (dengan parameter `duration_seconds: Double`) kini terdaftar resmi di `ToolExecutor` (total 99 tools sistem yang patuh validasi skema Gemini OpenAPI).
    - Sinonim alias lengkap: `webcam_record`, `take_video`, `record_video`, `camera_video`.
  - 🧪 **Unit Test Suite Lengkap (`tests/WebcamFullTests.swift`)**:
    - Pengujian end-to-end hardware kamera, ekstraksi JPEG sample buffer, otorisasi privasi, dan pipeline Vision lulus 100%.

- **Perbaikan Visualisasi Pairing Telegram Mobile Gateway di Notch Island**:
  - 🔑 **Kartu Dialog Otentikasi Telegram (`IslandView.telegramPairing`, `TelegramPairingView`)**:
    - Memperbaiki masalah di mana perintah `/start` dari smartphone tidak memunculkan kartu 6-digit PIN di Notch Island.
    - Menghadirkan tampilan kartu khusus di Notch Island (tinggi 185px) beraksen biru Telegram (`#0088CC` / `.cyan`) saat ada permintaan koneksi dari smartphone baru.
    - Tampilan kode PIN 6-digit besar berformat monospace monokrom kontras tinggi: masing-masing karakter ditempatkan di dalam kotak individual berborder tebal dengan spasi tengah pemisah 3-3.
    - Dilengkapi tombol 1-klik **Salin PIN** ke clipboard dan tombol **Batal / Tutup**.
  - ✈️ **Notch Compact Resting Pill (`NotchCompactTelegramPill`)**:
    - Ketika ada proses pairing yang sedang menunggu verifikasi, mode compact/resting Notch Island menampilkan pill biru interaktif `✈️ PIN: [6-digit]` di sebelah kanan notch, sehingga pengguna tetap dapat melihat kode PIN secara instan tanpa harus membuka mode expanded.
    - Mengetuk atau mengklik pill ini langsung memperluas (*expand*) Notch Island ke kartu otentikasi penuh.
  - 🔄 **Otomatisasi FSM & Sinkronisasi Lifecycle (`TelegramGatewayService.swift`)**:
    - Mengintegrasikan sinyal `.hookExpand` yang secara otomatis membuka Notch Island dari keadaan tersembunyi/compact ke kartu `.telegramPairing` begitu pesan `/start` masuk.
    - Saat verifikasi PIN berhasil di Telegram, Notch Island secara otomatis menampilkan status sukses `✅ Telegram HP Terhubung`, membunyikan nada selesai, dan kembali ke mode normal secara anggun.


- **Dynamic Island Media Studio & Multi-Format Player (Paket 14 - Selesai Penuh: Tahap A, B, C, D)**:
  - 🎵 **Dynamic Media Pill (Resting / Compact Mode) (`IslandRootView.swift`, `AudioWaveformEngine.swift`)**:
    - Notch Island melakukan *fluid morphing* saat media audio/video berputar di latar belakang, memanjang secara anggun ke lebar 248px.
    - Menampilkan mini cover art atau animated music note di sebelah kiri notch.
    - **Live Equalizer Wavebars**: 4 batang frekuensi audio dinamis berukuran 2.5px yang bergerak memantul mulus (3px s.d. 14px) mengikuti irama lagu dengan warna aksen adaptif.
    - Interaktivitas klik: 1 ketukan pada Media Pill langsung membuka kartu expanded *Media Studio*.
  - 🎛️ **Expanded Notch Media Studio Card (`IslandView.media`, `NotchMediaStudioView.swift`)**:
    - Kartu UI interaktif berukuran tinggi 195px dengan 3 tab media: Musik, Video, dan Foto/Screenshot.
    - **Music Player Card**: Cover art dengan ambient blur glow memancarkan warna album, judul lagu & artis *running text (marquee)*, timeline scrubber interaktif dengan timecode, kontrol lengkap (Play/Pause, Skip, Previous, Shuffle, Repeat), dan 16-bar expanded visualizer spectrum.
    - **Video Player Card**: Embedded native player (`AVPlayer`) untuk review rekaman layar, klip video lokal, atau rekaman CCTV dengan overlay tombol kontrol dan loop scrubber.
    - **Image Viewer & Screenshot Card**: Penampil tangkapan layar/foto resolusi tinggi dengan badge metadata (dimensi piksel, ukuran file, format), tombol salin ke clipboard macOS, dan horizontal thumbnail carousel strip.
  - ⚙️ **Media Manager Core & Audio Playback Service (`MediaManagerService.swift`, `AudioPlaybackService.swift`)**:
    - Deteksi otomatis track yang sedang diputar di Spotify & Apple Music via background AppleScript polling tanpa memblokir render frame 60 FPS.
    - Scanner otomatis berkas tangkapan layar terbaru dari `~/Desktop` dan `~/Pictures/Screenshots`.
    - Engine pemutar file audio lokal mandiri via `AVAudioPlayer` dengan dukungan seek, volume, dan progress timer.
  - 🎨 **Integrasi Canvas Studio 2.0 (`CanvasArtifact.swift`, `CanvasView.swift`) (Tahap C)**:
    - Penambahan dua tipe artefak baru: `.media` ("Media Studio", icon `play.rectangle.fill`) dan `.gallery` ("Galeri Media", icon `photo.on.rectangle.angled`).
    - **Pemutar Layar Lebar**: Player video native (`AVPlayerView`) beresolusi tinggi di Canvas dan player audio mewah dengan ambient glow blur, 24-bar live equalizer spectrum, kontrol scrubbing slider, volume, dan tombol "Putar di Notch".
    - **Galeri Foto Multi-Kolom**: Grid galeri responsif untuk foto/screenshots dengan pencarian instan live (`gallerySearch`), filter counter, dan **Modal Lightbox Dialog** terintegrasi (preview besar, tombol salin ke clipboard, reveal di Finder, dan transfer langsung ke Notch Island).
  - 🛠️ **4 Tools LLM Baru & Apple Shortcuts URL Routing (`ToolExecutor.swift`, `AppleShortcutsService.swift`) (Tahap D)**:
    - `media_player_control`: Mengontrol pemutar musik/media (play, pause, toggle, next, previous, seek, volume).
    - `media_inspect_file`: Menganalisis metadata file lokal (resolusi, ukuran, durasi) dan menampilkan kartu interaktifnya di Notch Island atau Canvas Studio.
    - `media_present_gallery`: Menampilkan galeri foto/screenshot ke Canvas Studio dengan tata letak kisi-kisi dan lightbox.
    - `media_list_recent`: Menemukan daftar tangkapan layar atau rekaman layar terbaru.
    - 10 Alias Sinonim: `player_control`, `play_music`, `pause_music`, `inspect_image`, `inspect_media`, `open_gallery`, `show_gallery`, `play_video`, `recent_screenshots`, `recent_media`.
    - Total tools bertambah dari 94 menjadi **98 tools**, 100% patuh validasi skema Gemini OpenAPI.
    - Routing skema URL Siri / Shortcuts: `coucou://media` dan `coucou://player` untuk kontrol pemutaran instan.



- **Real-Time Full-Duplex Voice 2.0 (Conversational Live Stream) (Paket 12)**:
  - 🎙️ **Streaming Suara Dua Arah Sub-Detik (`RealtimeVoiceStreamService.swift`, `VoiceDuplexEngine.swift`)**:
    - Arsitektur live stream continuous full-duplex dengan VAD (Voice Activity Detection) dinamis dan adaptive silence window (~380ms) untuk mengeliminasi jeda "tunggu berpikir".
    - Latensi respon audio percakapan sub-detik terverifikasi (< 400ms, rata-rata ~320ms).
    - Interupsi alami instan (*Ultra-Fast Barge-In < 50ms*): Begitu pengguna mulai bersuara saat asisten sedang berbicara, playback audio seketika diputus, buffer di-flush, dan asisten langsung mendengarkan tanpa memotong kata pertama pengguna.
  - 🎭 **Emotion & Context-Adaptive Vocalization (`VocalPersonaStyle`, `VocalAudioProfile`)**:
    - Modulasi otomatis parameter vokal akustik (kecepatan bicara, tinggi nada pitch, volume) dan panduan kepribadian LLM:
      - `adaptive_auto`: Menyesuaikan dinamis (larut malam berbisik, pagi hari ceria, insiden sistem siaga tegas).
      - `whisper_night`: Nada lembut, tenang, volume rendah (0.65x) untuk penggunaan larut malam (22:00 - 06:00).
      - `urgent_alert`: Nada tegas, cepat (1.15x), dan volume penuh untuk peringatan insiden/keamanan.
      - `cheerful_morning`: Nada hangat, ceria, dan bersemangat menyambut aktivitas harian.
      - `thoughtful_analyst`: Nada tenang, terukur, dan fokus untuk diskusi kode/data.
      - `natural_friendly`: Nada ramah dan santai default.
  - ⚙️ **Panel Pengaturan Suara di Settings (`SettingsView.swift`)**:
    - Menu kontrol Full-Duplex Voice 2.0, pemilih Persona Vokal Adaptif, indikator latensi live stream, dan slider sensitivitas VAD (-42 dB s.d. -16 dB).
  - 🛠️ **2 Tools LLM Baru & 4 Aliases di `ToolExecutor.swift`**:
    - `voice_set_mode`: Mengonfigurasi mode streaming duplex, gaya persona vokal, dan ambang VAD.
    - `voice_status`: Membaca metrik latensi streaming (ms), status live stream, persona aktif, dan total interupsi barge-in.
    - Aliases: `set_voice_mode`, `voice_mode`, `duplex_voice`, `voice_info`.
    - Total tools bertambah dari 92 menjadi **94 tools**, 100% patuh validasi skema Gemini OpenAPI.

- **Interactive Canvas Studio 2.0 & Apple Ecosystem (Siri & Shortcuts) (Paket 13)**:
  - 🎨 **Interactive Widgets & WebKit Sandbox di Canvas (`CanvasView.swift`, `CanvasArtifact.swift`)**:
    - Dukungan tipe artefak baru: `.html` ("Web Sandbox", icon `globe.americas.fill`) via WebKit native `WKWebView` dengan background transparan, dan `.form` ("Form Interaktif", icon `slider.horizontal.3`) untuk input dinamis (teks, number, menu pilihan, toggle) dan aksi instan dengan umpan balik langsung.
    - Filter pencarian instan live (`searchText`) pada tabel data Canvas dengan counter baris live, serta penyortiran kolom interaktif (ascending/descending numerik dan alfabetis) saat mengklik header tabel.
  - 📌 **Pin-to-Desktop & Canvas Floating HUD (`CanvasManager.swift`, `CanvasWindowController.swift`)**:
    - Jendela Canvas kini dapat disematkan selalu di atas semua aplikasi (`.floating` window level & `.canJoinAllSpaces`) dengan tombol Pin di header bar.
    - Kontrol transparansi kaca dinamis (Solid 100%, Kaca Lembut 85%, Kaca Transparan 70%) untuk mode multitasking tanpa menghalangi ruang kerja.
    - Pilihan posisi docking 4 sudut layar monitor: Bawah Notch, Kanan Atas, Kanan Bawah, atau Tengah Layar dengan transisi posisi halus.
  - ⚡ **Apple Shortcuts & Siri Deep Integration (`AppleShortcutsService.swift`, `AppDelegate.swift`)**:
    - Eksekusi native Apple Shortcuts via CLI macOS `/usr/bin/shortcuts list` dan `shortcuts run <name> -i <input>` (`shortcuts_list_shortcuts`, `shortcuts_run_shortcut`).
    - Penanganan URL Scheme dua arah (`coucou://` & `mochi://`) untuk instruksi instan dari Siri Shortcuts dan widget macOS: `ask` (buka prompt dengan teks), `run`/`goal` (jalankan tugas otonom), `canvas` (tampilkan widget), `sentry` (aktifkan/nonaktifkan penjaga Away), dan `autoheal` (audit kesehatan).
  - 🛠️ **3 Tools LLM Baru & 6 Aliases di `ToolExecutor.swift`**:
    - `shortcuts_list_shortcuts`, `shortcuts_run_shortcut`, `canvas_present_widget`.
    - Aliases: `apple_shortcuts`, `list_shortcuts`, `run_shortcut`, `execute_shortcut`, `show_canvas`, `open_canvas`.
    - Total tools bertambah dari 89 menjadi **92 tools**, 100% patuh validasi skema Gemini OpenAPI.

- **Proactive Sentry & Autonomous Health Watchers (Paket 11)**:
  - 🛡️ **Physical Intruder & Anti-Theft Guard (Away Sentry Mode - `ProactiveSentryService`)**: Penjaga fisik mandiri saat MacBook ditinggalkan di tempat umum atau kafe. Mendeteksi status lock screen macOS (`com.apple.screenIsLocked`) atau pengaktifan manual (`sentry_enable_away_mode` / `away_sentry`). Jika terdeteksi orang asing menatap layar via `FaceRecognitionService`, asisten memotret senyap dan mengirimkan peringatan darurat ke Telegram pemilik lengkap dengan foto, timestamp, dan nama Wi-Fi aktif.
  - 📡 **LAN New-Device Sentry (Wi-Fi Watcher Daemon)**: Pemantau pasif jaringan Wi-Fi lokal berbasis perbedaan (diff delta) perangkat ARP (`sentry_scan_wifi_intruders` / `wifi_sentry`). Menampilkan proactive alert chip di Notch Island seketika bila ada perangkat asing baru terhubung ke Wi-Fi, dengan opsi verifikasi perangkat terpercaya (`sentry_trust_device` / `trust_device`).
  - 🩺 **Container & Server Crash Auto-Healer**: Pemantauan otonom berkala terhadap Docker container dan server SSH terdaftar (`sentry_autoheal_check` / `auto_heal`). Mengidentifikasi container dengan status `exited` atau exit code abnormal dan memulihkannya secara mandiri via restart otonom, serta melaporkan service yang gagal pulih ke Notch Island dan Telegram.
  - ⚙️ **Panel Pengaturan Sentry di Settings (`SettingsView.swift`)**: Kartu konfigurasi terpadu di tab *Otonom & Sensor* untuk mengaktifkan Away Sentry, Wi-Fi Watcher, dan Auto-Healer beserta tombol audit kesehatan seketika.

- **DevOps, Cloud & Database Command Center Suite (Paket 10)**:
  - ☸️ **Kubernetes Cluster Sentinel (`KubernetesIntegrationService`)**: Pemantauan status pod dan deployment cluster per-namespace secara real-time (`k8s_get_pods` / `kubectl_pods`), inspeksi mendalam event crash/OOMKilled pod (`k8s_describe_pod` / `kubectl_describe`), dan pembacaan log runtime (`k8s_pod_logs` / `pod_logs`). Visualisasi otomatis disajikan dalam tabel interaktif di Canvas Studio.
  - 🗄️ **Database Safe Explorer & Query Engine (`DatabaseIntegrationService`)**: Mendukung PostgreSQL, MySQL, Redis, dan SQLite lokal dengan proteksi mutlak **Read-Only Guardrail**. Memblokir seluruh instruksi modifikasi atau destruktif (`DROP`, `DELETE`, `UPDATE`, `INSERT`, `TRUNCATE`, `ALTER`, `FLUSHALL`) secara otonom sebelum query dieksekusi. Menyajikan skema DDL relasi tabel (`db_inspect_schema`) dan hasil eksekusi query analitik `SELECT` (`db_execute_safe_query`) ke dalam spreadsheet Canvas yang dapat disortir dan dicari.
  - 💻 **Developer Environment & Smart Git Supercharger (`DeveloperEnvironmentService`)**:
    - Navigasi file dan baris error instan (`editor_goto_file_line` / `goto_line`): Melompat langsung ke baris dan kolom kode yang error di Cursor, VS Code, Windsurf, atau Xcode (`editor -g path:line:col`).
    - Usulan commit konvensional cerdas (`git_smart_commit` / `smart_commit`): Menganalisis diff perubahan staged/unstaged dan menyusun pesan Conventional Commit (`feat`, `fix`, `docs`, `chore`, `test`) secara otomatis.
    - Review Pull Request visual (`gh_pr_review_summary` / `review_pr`): Mengambil status PR GitHub aktif atau 5 commit terakhir dan menampilkannya di Canvas.
  - ⚙️ **Panel Pengaturan Kubernetes & Database di Settings (`SettingsView.swift`)**: Menampilkan indikator status cluster Kubernetes aktif dengan tombol 1-klik "Periksa Pods di Canvas", serta status ketersediaan klien database lokal (SQLite, PostgreSQL, MySQL, Redis).

- **Application, Server & DevOps Orchestration Suite**:
  - 🐳 **Docker & Container Engine Integration (`DockerIntegrationService`)**: Mendeteksi Docker daemon lokal secara non-blocking (`isDockerAvailable`), membaca status container (Up/Down, image, ports, ID) dengan visualisasi tabel interaktif otomatis di Canvas Studio (`docker_list_containers` / alias `docker_ps`), mengambil baris log output container terakhir (`docker_get_logs` / `docker_logs`), serta me-restart container secara aman (`docker_restart_container`).
  - 🖥️ **Remote Server SSH Gateway & Diagnostics (`SSHServerGatewayService`)**: Gateway pemantauan server Linux / Cloud jarak jauh via koneksi SSH terenkripsi (`ssh_list_servers`, `ssh_server_health`, `ssh_run_command`, `ssh_tail_log`). Secara otomatis melakukan audit kesehatan server (uptime, load average, kapasitas RAM, penggunaan disk `df -h /`, status layanan systemd) dan menghasilkan kartu diagnostik elegan di Canvas.
  - 🍎 **Apple Ecosystem & Desktop Productivity Integration (`AppleAppsIntegrationService`)**: Kontrol aplikasi bawaan macOS via AppleScript bridge tanpa overhead:
    - 📅 **Apple Calendar (`calendar_list_events` / `calendar`)**: Membaca jadwal agenda rapat dan event hari ini atau beberapa hari ke depan.
    - 📝 **Apple Reminders (`reminder_add_task` / `add_reminder`)**: Menambahkan to-do item langsung ke daftar pengingat macOS.
    - 📋 **Apple Notes (`notes_create_note` / `create_note`)**: Menyimpan catatan atau laporan riset ke folder Apple Notes.
    - 🎵 **Media Controller (`media_control` / `music_control` / `spotify_control`)**: Mengontrol playback lagu, pause, toggle, next track, dan membaca metadata lagu yang sedang diputar di Spotify & Apple Music.
  - 🖥️ **Panel Pengaturan Integrasi & MCP (`SettingsView.swift`)**:
    - Kartu status Docker Daemon real-time dengan penghitung container aktif dan tombol "Lihat di Canvas".
    - Formulir registrasi Remote Server SSH (label, host/IP, port, username, key path) dengan aksi audit instan dan manajemen daftar server.
  - 📏 **Chat View Clipping & Height Fix**: Memperluas tinggi panel `IslandPanel` hingga 520 pt dan menambahkan `.layoutPriority(1)` pada container input chat di `IslandViewContent.swift`, memastikan riwayat chat yang panjang tidak pernah memotong area input teks, mikrofon, atau tombol kirim.
  - 🖼️ **Webcam & Media Delivery to Canvas**: Setiap foto tangkapan kamera webcam dan snapshot CCTV kini otomatis disematkan ke dalam `CanvasArtifact` dan menampilkan tombol interaktif `[ Buka Canvas ]` di Notch Island.

- **Visual Perception, Biometric Face Recognition, CCTV Gateway & Network Sentinel Suite**:
  - 📷 **Webcam Visual Perception (`WebcamCaptureService`)**: Mengintegrasikan penangkapan visual on-demand menggunakan `AVFoundation` (`AVCaptureSession` & `AVCapturePhotoOutput`) dengan jaminan privasi mutlak macOS (zero background recording, sesi capture langsung ditutup seketika untuk mematikan LED hijau kamera hardware). Mochi mampu memotret lingkungan sekitar dan menganalisis objek fisik melalui VLM multimodal atau Apple Vision on-device (`camera_capture_photo`, `camera_analyze`).
  - 👤 **On-Device Biometric Face Recognition & Presence Guard (`FaceRecognitionService`)**: Sistem pengenalan wajah 100% lokal dipercepat oleh Apple Neural Engine (ANE) via Apple `Vision.framework`. Fitur registrasi wajah pemilik (`face_enroll_owner`) dan verifikasi kehadiran (`face_verify_presence`). Dilengkapi sistem **Peeking / Intruder Guard** yang otomatis mendeteksi dan memberi peringatan di Notch saat ada lebih dari 1 orang menatap layar MacBook di tempat umum.
  - 📹 **CCTV RTSP & IoT Streamer (`CCTVGatewayService`)**: Gateway pemantauan kamera keamanan IP/CCTV rumah atau kantor berbasis protokol RTSP dan direct HTTP/MJPEG snapshot poller (`cctv_list_cameras`, `cctv_get_snapshot`, `cctv_add_camera`). Snapshot kamera otomatis dipresentasikan ke jendela Canvas Mochi secara interaktif.
  - 🛡️ **Network Sentinel & Laptop Security Suite (`NetworkSecurityService`)**: Audit keamanan macOS menyeluruh (`laptop_security_audit`) mencakup status Firewall (`socketfilterfw`), enkripsi FileVault (XTS-AES 128), integritas SIP (`csrutil`), Gatekeeper (`spctl`), dan deteksi listening ports yang mencurigakan dengan kalkulasi skor kesehatan keamanan (0-100%). Dilengkapi pemindai LAN (`network_scan_lan`) berbasis tabel ARP & inferensi tipe perangkat (Router, Apple, IoT, Smart TV, CCTV) dan diagnostik latensi ping/DNS/Public IP (`network_diagnostics`).
  - 🛠️ **Resilient Tool Calling & Self-Healing Aliasing Framework**:
    - **Defensive OpenAPI Schema Sanitizer (`GeminiProvider`)**: Memperbaiki secara otomatis skema deklarasi fungsi OpenAPI untuk Google Gemini API yang memerlukan atribut `items` pada array (`items: { type: "string" }`), menghilangkan sepenuhnya bug HTTP 400 `missing field items`.
    - **Self-Healing Fuzzy Alias Resolution (`ToolExecutor`)**: Kamus alias sinonim otomatis untuk memetakan nama tool natural (seperti `check_security`, `scan_wifi`, `take_photo`, `verify_face`, `cctv_snapshot`) ke fungsi resmi internal secara transparan tanpa melempar error "Unknown tool".
  - ⚙️ **Kontrol Pengaturan Visual & CCTV**: Bagian baru pada Pengaturan tab **Otonom & Sensor** untuk mendaftarkan/mereset wajah pemilik serta mengelola daftar kamera CCTV.

- **Modern Tabbed Settings Experience & Comprehensive Feature Control**: Merombak tampilan menu pengaturan (`SettingsView.swift`) dari antarmuka vertikal panjang menjadi sistem tab navigasi modern bernuansa native macOS dengan SF Symbols, animasi transisi halus, dan pengelompokan logis per kategori:
  - ⚙️ **Umum**: Pengaturan waktu auto-close, hide absence, ambang sapaan, shortcut keyboard global, toggle peluncuran saat startup, tombol buka ulang Setup Wizard Onboarding, dan cek pembaruan otomatis.
  - 🎭 **Persona & Suara**: Uji reaksi ekspresi wajah Mochi secara langsung (Thinking, Question, Working, Searching, Sleeping, Dizzy, Reset Normal), konfigurasi TTS (OpenAI, ElevenLabs, Groq Orpheus, macOS System), voice duplexing alami (barge-in), intonasi emosi, volume, dan uji bunyi efek UI.
  - 🧠 **AI & Model**: Pemilihan AI Provider, manajemen Primary API Key & Multi-Key Pool dengan indikator cooldown 429 dan last-used timestamp, selector model, toggle Smart Intent Router (Edge vs Cloud Hybrid), dan verifikasi endpoint on-device SLM / Ollama.
  - ⚡ **Otonom & Sensor**: Kontrol Mode Otonom Penuh, Mode Otopilot (JARVIS) dengan guardrail PolicyEngine, batas langkah per permintaan, toggle pemantau sensorik (📁 File System Watcher & 📋 Smart Clipboard Watcher), status izin Aksesibilitas macOS & Panic Guardrail reset, pemicu manual Autonomous Night-Shift, dan peluncuran Structured Playbooks (SOPs).
  - 🛠️ **Dynamic Tools (JIT)**: Antarmuka pengelolaan Metacognitive JIT Tool Synthesizer, menampilkan daftar alat dinamis ciptaan asisten beserta bahasa (Bash, Python, Swift, JS), penghitung eksekusi, tombol uji eksekusi instan di sandbox terisolasi, tombol hapus alat, form pembuatan alat baru secara manual, dan rincian batas keamanan sandbox.
  - 📱 **Mobile & Telegram**: Panel kontrol Telegram Encrypted Gateway dengan status real-time (Running/Stopped), penyimpanan aman bot token, visualisasi status pairing smartphone (Allowed Chat ID), tombol putuskan pairing (unlink), dan ringkasan perintah kendali jarak jauh.
  - 🔌 **Integrasi & MCP**: Pengaturan Preferred Coding Editor & Claude Code Hooks, pemilih 4 slot integrasi aktif di Notch Island, manajemen kredensial layanan eksternal (Resend, n8n, Vercel, GitHub, Stripe, Cal.com, Notion), dan konfigurasi server/klien MCP.

- **Metacognitive Tool Maker & Dynamic Skill Sandbox**: Asisten kini mampu mengarang, memvalidasi keamanan, mengompilasi JIT (Just-In-Time), dan menjalankan alat/skill baru secara mandiri saat menghadapi kebutuhan unik pengguna. Didukung oleh `DynamicSkillSandbox` (eksekusi terisolasi dengan batas waktu dan proteksi mutlak `PolicyEngine` terhadap perintah destruktif) serta `DynamicToolSynthesizer` yang secara otomatis mendaftarkan alat dinamis (Bash, Python, Swift, JavaScript) ke `ToolExecutor.allTools` sebagai *first-class native tools*.
- **Telegram Encrypted Gateway & Remote Mobile Control**: Gateway komunikasi asinkron aman untuk mengontrol MacBook secara otonom dari smartphone di mana saja melalui Telegram Bot API. Dilengkapi protokol *Pairing Handshake* kode PIN 6-digit visual di Notch untuk mencegah akses tidak sah, perintah remote (`/status`, `/screenshot`, `/canvas`, `/cancel`), eksekusi tugas otonom langsung dari chat (`/run` atau teks bebas), dan jembatan notifikasi proaktif saat terjadi event kritis pada Mac.
- **Multi-Agent Swarm & Interactive Canvas Artifacts**: Orkestrasi tim agen spesialis otonom (`AgentOrchestrator`) dengan dekomposisi dinamis via LLM (`decomposeWithLLM`) membagi sasaran kompleks ke dalam sub-tugas untuk `researcher`, `analyst`, `coder`, `writer`, dan `operator`. Dilengkapi pelaporan status progres live di notch (`activePlaybookProgress`), deteksi otomatis format artefak (`.table`, `.chart`, `.code`, `.document`), serta auto-presentation ke antarmuka interaktif `CanvasManager` (Canvas Studio) lengkap dengan opsi ekspor 1-klik ke Word dan Excel. `AutonomousAgent` kini otomatis mendelegasikan tugas riset/analisis/laporan mendalam ke Swarm.
- **Smart Clipboard Watcher & Sensory Event Hub**: Pemantau pasteboard pasif berbasis `changeCount` (0% CPU) dengan filter keamanan mutlak terhadap data password/secret (`ConcealedType`/1Password/Bitwarden). Mengklasifikasikan secara otomatis error terminal/kompiler, tautan URL (YouTube, GitHub, Web), JSON mentah, cuplikan kode, dan query SQL. Terintegrasi ke `SensoryEventHub` yang mengelola prioritas Proactive Chips di notch (error berprioritas tinggi di urutan teratas) dengan pembatasan maksimal 5 chip dan deduplikasi dinamis.
- **Closed-Loop Vision-Language-Action (VLA) CUA**: `VisualGroundingEngine` diperluas dengan `executeClosedLoopAction()` yang menjalankan siklus *Look -> Plan -> Act -> Verify -> Self-Heal* pada antarmuka macOS. Dilengkapi auto-recovery via Accessibility API, deteksi pergerakan mouse fisik (panic guardrail), dan dukungan multi-action (`click`, `doubleClick`, `rightClick`, `typeText`, `pressKey`, `scroll`). Terintegrasi penuh ke `gui_locate_and_click` di `ToolExecutor`.
- **Full-Duplex Expressive Persona**: Integrasi mendalam antara `VoiceDuplexEngine` dan karakter Mochi pada `BotCanvasView`. Mochi kini mengartikulasikan mulutnya secara alami sesuai gelombang audio saat berbicara (`speech viseme`), menatap lurus dan mendongak dengan penuh perhatian saat mendengarkan pengguna (`pttStatus == .listening`), dan memicu reaksi kaget (*surprised emote*) instan saat terjadi interupsi alami (*barge-in*).
- **Semantic Vector RAG On-the-Fly**: Integrasi semantik `VectorMemoryStore` ke dalam `ClaudeService.systemPrompt(for:)`. Mengambil preferensi pengguna dan memori jangka panjang dengan relevansi cosinus tertinggi secara dinamis sesuai query percakapan aktif. Menyinkronkan aksi `memory_save` langsung ke indeks vektor.
- **File System Watcher Daemon**: Pemantau sistem berkas otonom berbasis `DispatchSource` pada direktori `~/Downloads` dan `~/Desktop` dengan 0% CPU saat diam. Secara otomatis mendeteksi berkas baru (faktur/invoice, spreadsheet data, tangkapan layar, arsip, kode), menyaring berkas sementara, dan memicu rekomendasi proaktif (*Proactive Chips*) di Notch beserta reaksi emot Mochi.
- **Smart Intent Router & Edge/Cloud Hybrid Routing**: Terintegrasi langsung dengan `ClaudeService.chat()`. Query lokal dan cepat otomatis diarahkan ke on-device Edge SLM (`local_mlx`/Ollama) untuk latensi ultra-rendah dan privasi, dengan mekanisme silent fallback otomatis ke Cloud LLM jika model lokal belum aktif.
- **LLM Dynamic DAG Workflow Planner**: `WorkflowEngine` ditingkatkan dengan `planAutonomous()`, merencanakan alur kerja multi-langkah menggunakan LLM terstruktur berbasis daftar alat `ToolExecutor`, terhubung dengan mekanisme `SelfCorrection` dan pelaporan status per-langkah secara real-time pada `AutonomousAgent`.
- **Chat Mode Auto-Close Guard**: Island/notch will no longer prematurely collapse or hide while the AI is generating, streaming responses, executing tools, or speaking via TTS. Added FSM protection (`canCollapseHome`) and activity state tracking (`isGenerating`).
- **Visual Step-by-Step AI Responses**: Assistant chat responses now automatically parse and render procedural steps (`1. ...`, `Langkah X: ...`, `Step X: ...`) into a sleek timeline card with glowing numbered circle badges and connected vertical tracks.
- **Agent Tool Execution Badges**: Shell executions and tool operations are now displayed with live running indicators and status pills instead of raw text.
- **Enhanced Code Blocks**: Added syntax containers with language tags and 1-click clipboard copy buttons.
- **Extended Chat Island Height**: Chat prompt mode now expands up to 420px height to comfortably read multi-step answers.
- **Multi-Editor & Terminal Coding Support**: Removed hardcoded VS Code restriction in `HookServer`. Added support for Antigravity, Cursor, Windsurf, Codex, Claude Desktop, iTerm2, Warp, Ghostty, and Terminal.app with configurable preferred editor and toggle in Settings.
- **Settings UI Enhancement**: Added dedicated "Editor & Coding Agents" card and renamed "Active pills" to "Slot Integrasi Aplikasi Aktif (Active Slots)" with clear descriptions.
- **Groq AI Provider & Multi-Key Pool**: Added full support for Groq AI (`openai/gpt-oss-120b`, `qwen/qwen3.8-27b`, etc.) with streaming SSE and automatic multi-key rotation on HTTP 429 rate limits.
- **Groq Orpheus TTS with Auto-Rotation**: Added ultra-fast text-to-speech using Canopy Labs Orpheus models (`canopylabs/orpheus-v1-english`, `canopylabs/orpheus-arabic-saudi`) with multi-key failover and selectable voice personas (`troy`, `orla`, `autumn`, `austin`, `shelby`).
- Compact island on screens without a notch (#22) — thanks @Kamasoutra
- Only web links (http/https) open from the notch; other kinds of links from Claude or integrations are ignored (#16) — thanks @Cris1670
- Hook socket limited to your own user account, with size and time limits; logs no longer keep commands, n8n data or full URLs, and stay under 1 MB (#16) — thanks @Cris1670 and @Vignesh-Thangamariappan
- The island always reopens after folding, and Settings opens below it, resizable — thanks @rouderz
- Choose the Claude model for the chat in Settings; the list comes from your Anthropic account, and Claude Sonnet 4.6 stays the default — thanks @rouderz
- Windows build artifacts are now downloadable from a manual CI run — thanks @MysJofR
