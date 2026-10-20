import AppKit
import KpubCore
import SwiftUI
import WebKit

/// Вход: через страницу логина зеркала (cookie сессии сайта годятся для /v1 на зеркале),
/// либо по коду устройства (нужен доступ к api.service-kp.com), либо вручную по токену.
struct LoginView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showWebLogin = false
    @State private var showAlternatives = false
    @State private var device: DeviceCode?
    @State private var deviceFlowActive = false
    @State private var errorText: String?
    @State private var accessToken = ""
    @State private var refreshToken = ""
    @State private var isTokenLogin = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                Text("Kpub для Mac")
                    .font(.largeTitle.bold())

                TextField("Адрес вашего зеркала (https://…)", text: $model.siteURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 460)
                if !model.siteURL.isEmpty && model.mirrorURL == nil {
                    Text("Введите HTTPS-адрес зеркала без логина и пароля в URL")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task {
                        await model.prepareWebsiteLogin()
                        showWebLogin = true
                    }
                } label: {
                    Label("Войти через своё зеркало", systemImage: "person.crop.circle")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .disabled(model.mirrorURL == nil)
                Text("Откроется обычная страница входа кинопаба. Приложение работает через то же зеркало, что и веб-версия.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                Button("Открыть загрузки") { openWindow(id: "downloads") }

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }

                DisclosureGroup("Другие способы входа и адреса", isExpanded: $showAlternatives) {
                    VStack(alignment: .leading, spacing: 14) {
                        deviceCodeBlock
                        Divider()
                        Form {
                            TextField("API (/v1)", text: $model.apiBaseURL)
                            TextField("OAuth (/oauth2)", text: $model.oauthBaseURL)
                            TextField("Access token", text: $accessToken)
                            TextField("Refresh token (необязательно)", text: $refreshToken)
                            HStack {
                                Button("Войти с токеном") { Task { await loginWithToken() } }
                                    .disabled(accessToken.nonEmptyTrimmed == nil || isTokenLogin)
                                if isTokenLogin { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .disclosureGroupStyle(WholeRowDisclosureStyle())
                .frame(maxWidth: 520)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showWebLogin) {
            WebLoginSheet()
        }
        .task(id: deviceFlowActive) {
            if deviceFlowActive { await runDeviceFlow() }
        }
    }

    @ViewBuilder
    private var deviceCodeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Вход по коду устройства").font(.headline)
            Text("Нужен доступ к api.service-kp.com — у многих провайдеров он заблокирован. Токен при этом обновляется раз в час через тот же адрес.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let device {
                HStack(spacing: 12) {
                    Text(device.userCode)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    if let url = model.deviceActivationURL {
                        Button("Открыть \(url.host() ?? "")/device") { NSWorkspace.shared.open(url) }
                    }
                    ProgressView().controlSize(.small)
                }
            } else {
                Button(deviceFlowActive ? "Получаем код…" : "Получить код") {
                    errorText = nil
                    deviceFlowActive = true
                }
                .disabled(deviceFlowActive)
            }
        }
    }

    private func runDeviceFlow() async {
        defer {
            deviceFlowActive = false
            device = nil
        }
        while !Task.isCancelled {
            let code: DeviceCode
            do {
                code = try await model.api.requestDeviceCode()
            } catch {
                errorText = "Не удалось получить код: \(error.localizedDescription)"
                return
            }
            device = code
            let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(max(code.interval, 3)))
                if Task.isCancelled { return }
                if case .authorized = try? await model.api.pollDeviceToken(code: code.code) {
                    await model.didLogin()
                    return
                }
            }
        }
    }

    private func loginWithToken() async {
        guard let access = accessToken.nonEmptyTrimmed else { return }
        isTokenLogin = true
        defer { isTokenLogin = false }
        do {
            try await model.loginWithToken(access: access, refresh: refreshToken)
        } catch {
            errorText = "Токен не подошёл: \(error.localizedDescription)"
        }
    }
}

/// Окно со страницей входа зеркала. После каждой загрузки страницы пробуем API с cookie сайта.
struct WebLoginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Войдите в свой аккаунт кинопаба"
    @State private var checking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(status).foregroundStyle(.secondary)
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            if let url = loginURL {
                LoginWebView(url: url) { cookies, pageURL in
                    // На самой странице логина сессии ещё нет — не дёргаем API зря.
                    guard pageURL?.path().contains("/user/login") != true else { return }
                    Task { await tryLogin(cookies) }
                }
            }
        }
        .frame(width: 760, height: 640)
    }

    private var loginURL: URL? {
        model.mirrorURL?.appendingPathComponent("user/login")
    }

    private func tryLogin(_ cookies: [HTTPCookie]) async {
        guard !checking else { return }
        checking = true
        status = "Проверяем вход…"
        defer { checking = false }
        do {
            try await model.loginWithWebSession(cookies)
            dismiss()
        } catch {
            status = "Не получилось войти: \(error.localizedDescription)"
        }
    }
}

struct LoginWebView: NSViewRepresentable {
    let url: URL
    let onPageLoaded: ([HTTPCookie], URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPageLoaded: onPageLoaded) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onPageLoaded: ([HTTPCookie], URL?) -> Void

        init(onPageLoaded: @escaping ([HTTPCookie], URL?) -> Void) {
            self.onPageLoaded = onPageLoaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let pageURL = webView.url
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [onPageLoaded] cookies in
                DispatchQueue.main.async { onPageLoaded(cookies, pageURL) }
            }
        }
    }
}
