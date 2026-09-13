#!/usr/bin/env python3
from pathlib import Path

# This patch runs AFTER patch_serienstream_interactive.py.
# It keeps the verification manual, but makes the visible SerienStream flow finishable
# and reliably returns provider redirects to the module without letting the WebView leave s.to.

network_path = Path("Shirox/Services/NetworkFetch.swift")
text = network_path.read_text(encoding="utf-8")

section_marker = "// MARK: - NetworkFetchManager"
if section_marker not in text:
    raise SystemExit("v3: NetworkFetchManager marker not found")
head, tail = text.split(section_marker, 1)

# 1) After showing the exact episode page, press only the selected provider button.
#    This does NOT click or solve any CAPTCHA/Turnstile UI.
old = '''            webView.load(request)
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
new = '''            webView.load(request)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if self?.interactiveSerienStream == true {
                    self?.armSerienStreamProviderButton()
                } else {
                    self?.performCustomInteractions()
                }
                if self?.options?.returnCookies == true {
                    self?.captureCookies {}
                }
            }
        }'''
if old not in tail:
    raise SystemExit("v3: interaction block not found in NetworkFetchMonitor")
tail = tail.replace(old, new, 1)

marker = '''    private func setupWebView() {
        let config = WKWebViewConfiguration()'''
method = '''    private func armSerienStreamProviderButton() {
        guard interactiveSerienStream, let webView else { return }
        let target = originalUrlString
            .replacingOccurrences(of: "\\\\", with: "\\\\\\\\")
            .replacingOccurrences(of: "'", with: "\\\\'")

        let js = """
        (function() {
            const target = '\\(target)';
            let attempts = 0;
            const timer = setInterval(function() {
                attempts++;
                const challengeVisible = !!document.querySelector('iframe[src*="challenges.cloudflare.com"], iframe[src*="turnstile"], .cf-turnstile');
                const nodes = Array.from(document.querySelectorAll('[data-play-url],[data-playurl],a[href]'));
                const hit = nodes.find(function(el) {
                    const raw = el.getAttribute('data-play-url') || el.getAttribute('data-playurl') || el.getAttribute('href') || '';
                    if (!raw) return false;
                    try { return new URL(raw, location.origin).href === target; } catch(e) { return false; }
                });
                if (hit && !challengeVisible) {
                    try { hit.click(); } catch(e) {}
                }
                if (attempts >= 180) clearInterval(timer);
            }, 500);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()'''
if marker not in tail:
    raise SystemExit("v3: setupWebView marker not found in NetworkFetchMonitor")
tail = tail.replace(marker, method, 1)

# 2) Stronger ad cleanup while explicitly preserving the Cloudflare frame.
needle = '''                document.querySelectorAll('.adsbygoogle,.advertisement,.ad-container,[data-ad],[id^="ad-"] ,[class^="ad-"]').forEach(function(el) {
                    try { el.remove(); } catch(e) {}
                });
            };'''
replacement = '''                document.querySelectorAll('.adsbygoogle,.advertisement,.ad-container,[data-ad],[data-ad-slot],[id^="ad-"],[class^="ad-"],.popup-ad,.banner-ad').forEach(function(el) {
                    try { el.remove(); } catch(e) {}
                });

                const phrases = ['VPN Recommended', 'Download is ready', 'Tap to Install and Continue Watching', 'Tap to proceed'];
                document.querySelectorAll('body *').forEach(function(el) {
                    const t = (el.innerText || '').trim();
                    if (!t || t.length > 240) return;
                    if (!phrases.some(function(p) { return t.indexOf(p) !== -1; })) return;
                    let box = el;
                    for (let i = 0; i < 5 && box && box.parentElement; i++) {
                        const r = box.getBoundingClientRect();
                        if (r.width > window.innerWidth * 0.55 && r.height < 220) break;
                        box = box.parentElement;
                    }
                    try { if (box && box !== document.body) box.remove(); } catch(e) {}
                });
            };'''
if needle not in tail:
    raise SystemExit("v3: ad clean block not found in NetworkFetchMonitor")
tail = tail.replace(needle, replacement, 1)

# 3) The old popup blocker discarded external provider URLs before native WebKit could see them.
#    Log them first, then block the visible navigation. addRequest() can now trigger the existing cutoff.
old = '''            const nativeOpen = window.open;
            window.open = function(url) {
                try {
                    const u = new URL(url, location.href);
                    if (allowedHost(u.hostname)) location.href = u.href;
                } catch(e) {}
                return null;
            };'''
new = '''            const nativeOpen = window.open;
            window.open = function(url) {
                try {
                    const u = new URL(url, location.href);
                    if (allowedHost(u.hostname)) {
                        location.href = u.href;
                    } else {
                        window.webkit.messageHandlers.networkLogger.postMessage({ type: 'serienstream-external', url: u.href });
                    }
                } catch(e) {}
                return null;
            };'''
if old not in tail:
    raise SystemExit("v3: window.open blocker not found")
tail = tail.replace(old, new, 1)

old = '''                    if (!allowedHost(u.hostname)) {
                        e.preventDefault();
                        e.stopImmediatePropagation();
                    }'''
new = '''                    if (!allowedHost(u.hostname)) {
                        try { window.webkit.messageHandlers.networkLogger.postMessage({ type: 'serienstream-external-link', url: u.href }); } catch(logErr) {}
                        e.preventDefault();
                        e.stopImmediatePropagation();
                    }'''
if old not in tail:
    raise SystemExit("v3: external link blocker not found")
tail = tail.replace(old, new, 1)

# 4) Prefer the dedicated episode header added by module v1.8.3. Fall back to Referer for older modules.
old = '''        var visibleURL = url
        if interactiveSerienStream,
           let refererEntry = headers.first(where: { $0.key.lowercased() == "referer" }),
           let refererURL = URL(string: refererEntry.value),
           isSerienStreamHost(refererURL.host),
           refererURL.path.hasPrefix("/serie/") {
            visibleURL = refererURL
        }

        var request = URLRequest(url: visibleURL)'''
new = '''        var visibleURL = url
        if interactiveSerienStream {
            let explicitEpisode = headers.first(where: { $0.key.lowercased() == "x-shirox-serienstream-episode" })?.value
            let refererEpisode = headers.first(where: { $0.key.lowercased() == "referer" })?.value
            let episodeCandidate = explicitEpisode ?? refererEpisode
            if let episodeCandidate,
               let episodeURL = URL(string: episodeCandidate),
               isSerienStreamHost(episodeURL.host),
               episodeURL.path.hasPrefix("/serie/") {
                visibleURL = episodeURL
            }
        }

        var request = URLRequest(url: visibleURL)'''
if old not in tail:
    raise SystemExit("v3: visible episode URL block not found")
tail = tail.replace(old, new, 1)

# Do not send our private routing header to SerienStream itself.
old = '''            } else {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        if request.value(forHTTPHeaderField: "Referer") == nil {'''
new = '''            } else if key.lowercased() != "x-shirox-serienstream-episode" {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        if request.value(forHTTPHeaderField: "Referer") == nil {'''
if old not in tail:
    raise SystemExit("v3: request header loop not found")
tail = tail.replace(old, new, 1)

# 5) Wire the visible sheet's "Fertig" button to stop this exact networkFetch immediately.
old = '''                CloudflareBypassManager.shared.activeBypassWebView = webView
            }
            #endif'''
new = '''                CloudflareBypassManager.shared.activeBypassWebView = webView
                CloudflareBypassManager.shared.setActiveBypassFinishHandler { [weak self] in
                    self?.stopMonitoring(reason: "user-finished")
                }
            }
            #endif'''
if old not in tail:
    raise SystemExit("v3: active bypass WebView assignment not found")
tail = tail.replace(old, new, 1)

old = '''            CloudflareBypassManager.shared.activeBypassWebView = nil
        }
        #endif'''
new = '''            CloudflareBypassManager.shared.activeBypassWebView = nil
            CloudflareBypassManager.shared.setActiveBypassFinishHandler(nil)
        }
        #endif'''
if old not in tail:
    raise SystemExit("v3: bypass cleanup block not found")
tail = tail.replace(old, new, 1)

network_path.write_text(head + section_marker + tail, encoding="utf-8")

# 6) Add a user-controlled finish action to the existing Security Check window.
manager_path = Path("Shirox/Services/CloudflareBypassManager.swift")
manager = manager_path.read_text(encoding="utf-8")

old = '''    /// Non-nil while a Turnstile challenge is in progress — drives the bypass sheet.
    @Published var activeBypassWebView: WKWebView? = nil

    /// Set when a fetch hits a Turnstile wall but we have no cookie yet.'''
new = '''    /// Non-nil while a Turnstile challenge is in progress — drives the bypass sheet.
    @Published var activeBypassWebView: WKWebView? = nil

    /// SerienStream can expose a manual "Fertig" action that returns control to the resolver.
    @Published private(set) var canFinishActiveBypass = false
    private var activeBypassFinishHandler: (() -> Void)? = nil

    func setActiveBypassFinishHandler(_ handler: (() -> Void)?) {
        activeBypassFinishHandler = handler
        canFinishActiveBypass = handler != nil
    }

    func finishActiveBypass() {
        let handler = activeBypassFinishHandler
        activeBypassFinishHandler = nil
        canFinishActiveBypass = false
        activeBypassWebView = nil
        handler?()
    }

    /// Set when a fetch hits a Turnstile wall but we have no cookie yet.'''
if old not in manager:
    raise SystemExit("v3: manager activeBypass property block not found")
manager = manager.replace(old, new, 1)

old = '''        activeBypassWebView = webView
        defer { activeBypassWebView = nil }'''
new = '''        setActiveBypassFinishHandler(nil)
        activeBypassWebView = webView
        defer { activeBypassWebView = nil }'''
if old not in manager:
    raise SystemExit("v3: generic triggerBypass assignment not found")
manager = manager.replace(old, new, 1)

old = '''    func cancelActiveBypass() {
        activeBypassWebView = nil
    }'''
new = '''    func cancelActiveBypass() {
        activeBypassFinishHandler = nil
        canFinishActiveBypass = false
        activeBypassWebView = nil
    }'''
if old not in manager:
    raise SystemExit("v3: cancelActiveBypass block not found")
manager = manager.replace(old, new, 1)
manager_path.write_text(manager, encoding="utf-8")

view_path = Path("Shirox/Views/Shared/CloudflareBypassSheetView.swift")
view = view_path.read_text(encoding="utf-8")
old = '''            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { manager.cancelActiveBypass() }
                }
            }'''
new = '''            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { manager.cancelActiveBypass() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if manager.canFinishActiveBypass {
                        Button("Fertig") { manager.finishActiveBypass() }
                            .fontWeight(.semibold)
                    }
                }
            }'''
if old not in view:
    raise SystemExit("v3: Security Check toolbar block not found")
view = view.replace(old, new, 1)
view_path.write_text(view, encoding="utf-8")

print("Applied SerienStream v4: exact episode, provider capture, adblock and manual finish button")
