#!/usr/bin/env python3
from pathlib import Path

path = Path("Shirox/Services/NetworkFetch.swift")
text = path.read_text(encoding="utf-8")

# NetworkFetch.swift contains an earlier Simple monitor with similarly named methods.
# Only patch the full NetworkFetchMonitor section after this marker so helper methods
# land in the class that owns interactiveSerienStream/originalUrlString.
section_marker = "// MARK: - NetworkFetchManager"
if section_marker not in text:
    raise SystemExit("v3: NetworkFetchManager marker not found")
head, tail = text.split(section_marker, 1)

# 1) After showing the exact episode page, automatically press the matching provider button
#    (NOT the CAPTCHA). This triggers SerienStream's own Turnstile modal on the episode page.
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

# Insert the helper into NetworkFetchMonitor, never into NetworkFetchSimpleMonitor.
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

# 2) Strengthen the visible ad blocker without touching Cloudflare's challenge frame.
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

# 3) External provider redirects remain blocked from the visible WebView by the first patch.
#    addRequest() still sees them first, so the existing cutoff logic can return the provider URL.

path.write_text(head + section_marker + tail, encoding="utf-8")
print("Applied SerienStream v3 provider-trigger + stronger adblock patch (NetworkFetchMonitor only)")
