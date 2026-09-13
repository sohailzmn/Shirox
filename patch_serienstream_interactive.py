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

    private func isSerienStreamHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "serienstream.to" || host == "www.serienstream.to" || host == "s.to"
    }

    @Published private(set) var networkRequests: [String] = []'''
if old not in tail:
    raise SystemExit("interactive property insertion point not found")
tail = tail.replace(old, new, 1)

old = '''        self.options = options
        originalUrlString = urlString
        completionHandler = completion'''
new = '''        self.options = options
        originalUrlString = urlString
        if let candidate = URL(string: urlString) {
            interactiveSerienStream = isSerienStreamHost(candidate.host) && candidate.path == "/r"
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

        let effectiveTimeout = interactiveSerienStream ? max(options.timeoutSeconds, 120) : options.timeoutSeconds
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

        // Lightweight ad/popup blocker for the visible verification browser. We intentionally
        // keep Cloudflare challenge frames intact, because the user must complete Turnstile.
        let adBlockJS = """
        (function() {
            const allowedHost = function(host) {
                host = (host || '').toLowerCase();
                return host === 'serienstream.to' || host === 'www.serienstream.to' || host === 's.to';
            };
            const allowedFrameHost = function(host) {
                host = (host || '').toLowerCase();
                return allowedHost(host) || host === 'challenges.cloudflare.com' || host.endsWith('.cloudflare.com');
            };
            const clean = function() {
                document.querySelectorAll('iframe[src]').forEach(function(frame) {
                    try {
                        const u = new URL(frame.src, location.href);
                        if (!allowedFrameHost(u.hostname)) frame.remove();
                    } catch(e) {}
                });
                document.querySelectorAll('.adsbygoogle,.advertisement,.ad-container,[data-ad],[id^="ad-"] ,[class^="ad-"]').forEach(function(el) {
                    try { el.remove(); } catch(e) {}
                });
            };
            const nativeOpen = window.open;
            window.open = function(url) {
                try {
                    const u = new URL(url, location.href);
                    if (allowedHost(u.hostname)) location.href = u.href;
                } catch(e) {}
                return null;
            };
            document.addEventListener('click', function(e) {
                const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
                if (!a) return;
                try {
                    const u = new URL(a.href, location.href);
                    if (!allowedHost(u.hostname)) {
                        e.preventDefault();
                        e.stopImmediatePropagation();
                    }
                } catch(err) {}
            }, true);
            new MutationObserver(clean).observe(document.documentElement, {childList:true, subtree:true});
            if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', clean);
            else clean();
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: adBlockJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
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

# When the module passes the current episode as Referer, show that exact episode in the visible
# browser instead of the SerienStream homepage/provider bridge. The pending /r?t= URL remains the
# resolver's logical request and is still used for request tracking/cutoff.
old = '''    private func loadURL(url: URL, headers: [String: String]) {
        guard let webView = webView, options != nil else { return }
        addRequest(url.absoluteString)
        var request = URLRequest(url: url)'''
new = '''    private func loadURL(url: URL, headers: [String: String]) {
        guard let webView = webView, options != nil else { return }
        addRequest(url.absoluteString)

        var visibleURL = url
        if interactiveSerienStream,
           let refererEntry = headers.first(where: { $0.key.lowercased() == "referer" }),
           let refererURL = URL(string: refererEntry.value),
           isSerienStreamHost(refererURL.host),
           refererURL.path.hasPrefix("/serie/") {
            visibleURL = refererURL
        }

        var request = URLRequest(url: visibleURL)'''
if old not in tail:
    raise SystemExit("loadURL start insertion point not found")
tail = tail.replace(old, new, 1)

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

# Keep the visible verification WebView on serienstream.to. External provider/ad navigations are
# still recorded so the resolver can capture the provider URL, but the browser never leaves site.
old = '''    @available(iOS 15.0, macOS 13.0, *)
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if let url = navigationAction.request.url {
            if HostBlocklist.shared.isBlocked(url) { return .cancel }
            addRequest(url.absoluteString)
        }
        return .allow
    }'''
new = '''    @available(iOS 15.0, macOS 13.0, *)
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if let url = navigationAction.request.url {
            if HostBlocklist.shared.isBlocked(url) { return .cancel }
            addRequest(url.absoluteString)

            if interactiveSerienStream {
                // Only constrain top-level/new-window navigation. Cloudflare Turnstile is allowed
                // to load in a subframe, while ads/provider redirects cannot replace the page.
                let isTopLevel = navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == true
                if isTopLevel && !isSerienStreamHost(url.host) {
                    return .cancel
                }
            }
        }
        return .allow
    }'''
if old not in tail:
    raise SystemExit("navigation policy insertion point not found")
tail = tail.replace(old, new, 1)

# target=_blank popups are only allowed for internal SerienStream links. External destinations are
# recorded (so provider resolution still works) and then blocked from opening in the visible UI.
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
        if isSerienStreamHost(url.host) {
            webView.load(navigationAction.request)
        }
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
print("Applied SerienStream episode-focused verification/adblock patch to NetworkFetch.swift")
