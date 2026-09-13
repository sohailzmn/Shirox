#!/usr/bin/env python3
from pathlib import Path

path = Path("Shirox/Services/NetworkFetch.swift")
text = path.read_text(encoding="utf-8")
marker = "// MARK: - NetworkFetchManager"
if marker not in text:
    raise SystemExit("NetworkFetchManager marker not found")
head, tail = text.split(marker, 1)

# Keep the patch scoped to the full NetworkFetchMonitor, not the earlier Simple monitor.
old = '    private var originalUrlString: String = ""\n\n    @Published private(set) var networkRequests: [String] = []'
new = '''    private var originalUrlString: String = ""
    /// SerienStream's /r?t= provider bridge can show an in-page Turnstile modal.
    /// For that one flow we surface the same WKWebView so the user can verify manually.
    private var interactiveSerienStream = false

    @Published private(set) var networkRequests: [String] = []'''
if old not in tail:
    raise SystemExit("interactive property insertion point not found")
tail = tail.replace(old, new, 1)

old = '''        self.options = options
        originalUrlString = urlString
        completionHandler = completion'''
new = '''        self.options = options
        originalUrlString = urlString
        if let candidate = URL(string: urlString),
           let host = candidate.host?.lowercased() {
            interactiveSerienStream = (host == "serienstream.to" || host == "www.serienstream.to" || host == "s.to")
                && candidate.path == "/r"
        } else {
            interactiveSerienStream = false
        }
        completionHandler = completion'''
if old not in tail:
    raise SystemExit("startMonitoring insertion point not found")
tail = tail.replace(old, new, 1)

old = '''            setupWebView()
            loadURL(url: url, headers: options.headers)
        }

        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(options.timeoutSeconds), repeats: false) { [weak self] _ in'''
new = '''            if interactiveSerienStream {
                setupInteractiveSerienStreamWebView()
            } else {
                setupWebView()
            }
            loadURL(url: url, headers: options.headers)
            #if os(iOS)
            if interactiveSerienStream, let webView {
                // Reuse Shirox's existing high-level verification window. The page is fully
                // user-controlled: no CAPTCHA/Turnstile click is automated.
                CloudflareBypassManager.shared.activeBypassWebView = webView
            }
            #endif
        }

        let effectiveTimeout = interactiveSerienStream ? max(options.timeoutSeconds, 90) : options.timeoutSeconds
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(effectiveTimeout), repeats: false) { [weak self] _ in'''
if old not in tail:
    raise SystemExit("interactive setup/timer insertion point not found")
tail = tail.replace(old, new, 1)

# Insert a clean, user-visible WebView variant immediately before the regular hidden/automated one.
needle = '''    private func setupWebView() {
        let config = WKWebViewConfiguration()'''
interactive_method = '''    private func setupInteractiveSerienStreamWebView() {
        #if !os(tvOS)
        let config = WKWebViewConfiguration()
        // Use the shared store so login/session cookies from earlier networkFetch calls survive.
        config.websiteDataStore = .default()
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        config.mediaTypesRequiringUserActionForPlayback = []

        // Deliberately no navigator spoofing, no auto-click script and no custom UA here.
        // Turnstile sees a normal WKWebView and the user completes it manually.
        config.userContentController.add(self, name: "networkLogger")

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        webView = wv
        #else
        setupWebView()
        #endif
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()'''
if needle not in tail:
    raise SystemExit("setupWebView insertion point not found")
tail = tail.replace(needle, interactive_method, 1)

# The normal hidden resolver deliberately simulates clicks after two seconds. Never do that for
# the visible SerienStream verification browser; only the user should interact with the challenge.
old = '''            webView.load(request)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.performCustomInteractions()
                if self?.options?.returnCookies == true {
                    self?.captureCookies {}
                }
            }
        }'''
new = '''            webView.load(request)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self?.interactiveSerienStream != true {
                    self?.performCustomInteractions()
                }
                if self?.options?.returnCookies == true {
                    self?.captureCookies {}
                }
            }
        }'''
if old not in tail:
    raise SystemExit("doLoad interaction insertion point not found")
tail = tail.replace(old, new, 1)

old = '''        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "networkLogger")

        let originalUrl = options?.htmlContent != nil'''
new = '''        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "networkLogger")
        #if os(iOS)
        if interactiveSerienStream,
           let visible = CloudflareBypassManager.shared.activeBypassWebView,
           visible === webView {
            CloudflareBypassManager.shared.activeBypassWebView = nil
        }
        #endif

        let originalUrl = options?.htmlContent != nil'''
if old not in tail:
    raise SystemExit("stopMonitoring insertion point not found")
tail = tail.replace(old, new, 1)

# target=_blank/provider popups are loaded into the same visible WebView so the existing request
# tracker and provider cutoff can observe the destination and return it to the module.
append_marker = '''#if !os(tvOS)
extension NetworkFetchMonitor: WKScriptMessageHandler {'''
ui_delegate = '''#if !os(tvOS)
extension NetworkFetchMonitor: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard interactiveSerienStream, let url = navigationAction.request.url else { return nil }
        addRequest(url.absoluteString)
        webView.load(navigationAction.request)
        return nil
    }
}
#endif

#if !os(tvOS)
extension NetworkFetchMonitor: WKScriptMessageHandler {'''
if append_marker not in tail:
    raise SystemExit("WKScriptMessageHandler insertion point not found")
tail = tail.replace(append_marker, ui_delegate, 1)

path.write_text(head + marker + tail, encoding="utf-8")
print("Applied SerienStream interactive verification patch to NetworkFetch.swift")
