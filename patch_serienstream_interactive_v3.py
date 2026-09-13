#!/usr/bin/env python3
from pathlib import Path

path = Path("Shirox/Services/NetworkFetch.swift")
text = path.read_text(encoding="utf-8")

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
if old not in text:
    raise SystemExit("v3: interaction block not found")
text = text.replace(old, new, 1)

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
                const nodes = Array.from(document.querySelectorAll('[data-play-url],[data-playurl],a[href]'));
                const hit = nodes.find(function(el) {
                    const raw = el.getAttribute('data-play-url') || el.getAttribute('data-playurl') || el.getAttribute('href') || '';
                    if (!raw) return false;
                    try { return new URL(raw, location.origin).href === target; } catch(e) { return false; }
                });
                if (hit) {
                    clearInterval(timer);
                    try { hit.click(); } catch(e) {}
                } else if (attempts >= 30) {
                    clearInterval(timer);
                }
            }, 350);
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()'''
if marker not in text:
    raise SystemExit("v3: setupWebView marker not found")
text = text.replace(marker, method, 1)

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
if needle not in text:
    raise SystemExit("v3: ad clean block not found")
text = text.replace(needle, replacement, 1)

# 3) Keep external provider redirects blocked from display, but because addRequest() runs first,
#    the existing cutoff logic still captures the provider URL and closes the resolver when found.

path.write_text(text, encoding="utf-8")
print("Applied SerienStream v3 provider-trigger + stronger adblock patch")
