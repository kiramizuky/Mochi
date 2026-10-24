import SwiftUI
import AppKit

// MARK: - Onboarding (first launch — API key, izin, mode autopilot)

/// Alur singkat saat pertama kali meluncurkan Coucou:
/// 1. Pilih provider + masukkan API key.
/// 2. Izin mikrofon / Accessibility / tangkap layar (penjelasan saja; izin
///    sebenarnya diatur macOS System Settings).
/// 3. Mode konsent (autopilot default) → selesai.
struct OnboardingView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var voice = VoiceManager.shared

    @State private var step: Int = 0
    @State private var selectedProviderId: String = ProviderRegistry.shared.activeProviderId
    @State private var apiKey: String = KeychainStore.shared.get(
        ProviderRegistry.shared.activeProviderId + "-api-key") ?? ""
    @State private var statusMessage: String = ""

    private var providers: [(id: String, name: String)] {
        ProviderRegistry.shared.available.map { ($0.id, $0.displayName) }
    }
    private var keyPlaceholder: String {
        switch selectedProviderId {
        case "openai": return "API key (sk-…)"
        case "gemini": return "API key (AIza…)"
        default:       return "API key (sk-ant-…)"
        }
    }

    private let totalSteps = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Selamat datang di Coucou")
                    .font(.system(size: 22, weight: .bold))
                Text("Siapkan asisten Mochi di notch dalam 3 langkah cepat.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#9398A1"))
            }
            .padding(.top, 30).padding(.horizontal, 24)

            // Progress
            HStack(spacing: 8) {
                ForEach(1...totalSteps, id: \.self) { i in
                    Circle()
                        .fill(i <= step + 1 ? Color(hex: "#2F6BFF") : Color(hex: "#D1D4DA"))
                        .frame(width: 8, height: 8)
                }
                Spacer()
                Text("Langkah \(step + 1) dari \(totalSteps)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#9398A1"))
            }
            .padding(.horizontal, 24).padding(.top, 10)

            Divider().padding(.vertical, 16)

            // Steps
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if step == 0 { stepAPIKey }
                    else if step == 1 { stepPermissions }
                    else { stepMode }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Footer navigation
            VStack(spacing: 10) {
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundColor(statusMessage.hasPrefix("✓") ? Color(hex: "#34D399") : Color(hex: "#F4505E"))
                }
                HStack(spacing: 12) {
                    if step > 0 {
                        Button("Sebelumnya") { withAnimation { step -= 1 } }
                            .buttonStyle(.bordered)
                            .font(.system(size: 12))
                    }
                    Spacer()
                    Button(nextButtonTitle) { next() }
                        .buttonStyle(.borderedProminent)
                        .font(.system(size: 12, weight: .semibold))
                        .disabled(!nextButtonEnabled)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(width: 460, height: 560)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Steps

    private var stepAPIKey: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1 · API key").font(.system(size: 15, weight: .semibold))
            Text("Masukkan API key LLM agar Mochi bisa menjawab perintah Anda. Key disimpan aman di Keychain, tidak pernah keluar dari Mac ini.")
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: "#9398A1"))

            Picker("Provider", selection: $selectedProviderId) {
                ForEach(providers, id: \.id) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)

            SecureField(keyPlaceholder, text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)

            HStack(spacing: 8) {
                Button("Simpan") {
                    KeychainStore.shared.set("\(selectedProviderId)-api-key", value: apiKey)
                    ProviderRegistry.shared.setActiveProvider(id: selectedProviderId)
                    statusMessage = "✓ Key disimpan."
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty)

                Button("Coba koneksi") { testConnection() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var stepPermissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("2 · Izin sistem").font(.system(size: 15, weight: .semibold))
            Text("Beberapa fitur perlu izin macOS. Izin diberikan di  → System Settings → Privacy & Security.")
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: "#9398A1"))

            permissionRow(icon: "mic.fill", title: "Mikrofon", detail: "Push-to-talk dan wake word «Mochi».")
            permissionRow(icon: "applelogo", title: "Accessibility", detail: "Membaca & mengendalikan UI aplikasi lain (ax_read / ax_act).")
            permissionRow(icon: "viewfinder", title: "Tangkap layar", detail: "Cuplik jendela aplikasi agar Mochi bisa melihatnya.")

            Divider().padding(.vertical, 4)
            Text("Izin dapat diatur kembali kapan saja di Settings. Tanpa izin, fitur terkait akan dibatasi namun chat tetap berjalan.")
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: "#9398A1"))
                .italic()
        }
    }

    private var stepMode: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("3 · Mode konsent").font(.system(size: 15, weight: .semibold))
            Text("Mode default adalah autopilot: perintah non-kritis (shell, email, web) dijalankan otomatis sesuai policy, tanpa klik konfirmasi.")
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: "#9398A1"))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(hex: "#22C55E"))
                    Text("Autopilot (default)")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Jalan otomatis").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Text("Hard floor selalu aktif: sudo, rm -rf, pipe-to-shell, dan penulihan ~/.claude/settings.json diblokir, tidak dapat di-override.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#9398A1"))
            }
            .padding(10)
            .background(Color(hex: "#F5F6F8").opacity(0.5))
            .cornerRadius(8)

            Divider().padding(.vertical, 4)
            Text("Setelah selesai, island akan muncul di notch. Tekan ⌘⇧N untuk membuka chat, atau gunakan wake word jika diaktifkan di Settings.")
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: "#9398A1"))
        }
    }

    private func permissionRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "#2F6BFF"))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundColor(Color(hex: "#9398A1"))
            }
            Spacer()
            Text("System Settings").font(.system(size: 11))
                .foregroundColor(Color(hex: "#2F6BFF"))
        }
        .padding(8)
        .background(Color(hex: "#F5F6F8").opacity(0.3))
        .cornerRadius(6)
    }

    // MARK: - Navigation

    private var nextButtonTitle: String {
        step == totalSteps - 1 ? "Selesai & Mulai" : "Berikutnya"
    }

    private var nextButtonEnabled: Bool {
        if step == 0 { return !apiKey.isEmpty }
        return true
    }

    private func next() {
        if step == totalSteps - 1 {
            finish()
        } else {
            withAnimation { step += 1 }
        }
    }

    private func finish() {
        state.hasOnboarded = true
        statusMessage = "✓ Siap digunakan."
        // Buka island ke prompt setelah jeda singkat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            state.view = .prompt
            state.mode = .expanded
        }
    }

    private func testConnection() {
        Task {
            _ = await ProviderRegistry.shared.activeProvider.listModels()
            await MainActor.run { statusMessage = "✓ Koneksi OK." }
        }
    }
}

extension Notification.Name {
    static let onboardingComplete = Notification.Name("onboardingComplete")
}
