#!/usr/bin/env python3
from pathlib import Path

# Keep the generic Cloudflare verification flow unchanged for other hosts, but for
# SerienStream load the exact /serie/... URL that triggered verification instead of
# forcing the browser to the domain homepage.
path = Path("Shirox/Services/CloudflareBypassManager.swift")
text = path.read_text(encoding="utf-8")

old = '''        let webView = makeBypassWebView()
        let rootUrl = URL(string: "\\(url.scheme ?? \"https\")://\\(host)/") ?? url
        Logger.shared.log("[CFBypass] Loading \\(rootUrl) for host \\(host)", type: "Debug")
        webView.load(URLRequest(url: rootUrl))'''

new = '''        let webView = makeBypassWebView()
        let lowerHost = host.lowercased()
        let isSerienStream = lowerHost == "serienstream.to" || lowerHost == "www.serienstream.to" || lowerHost == "s.to"

        // SerienStream verification only makes sense in the context of the exact show/episode.
        // The old generic behavior intentionally loaded only the host root, which is why the
        // user kept seeing the SerienStream homepage even though the pending verification URL
        // already pointed at /serie/<slug>/staffel-X/episode-Y.
        let verificationURL: URL
        if isSerienStream && url.path.hasPrefix("/serie/") {
            verificationURL = url
        } else if isSerienStream,
                  let pending = pendingVerificationURL,
                  pending.host?.lowercased() == lowerHost,
                  pending.path.hasPrefix("/serie/") {
            verificationURL = pending
        } else {
            verificationURL = URL(string: "\\(url.scheme ?? \"https\")://\\(host)/") ?? url
        }

        Logger.shared.log("[CFBypass] Loading \\(verificationURL) for host \\(host)", type: "Debug")
        webView.load(URLRequest(url: verificationURL))'''

if old not in text:
    raise SystemExit("v6: Cloudflare verification root URL block not found")

text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
print("Applied SerienStream v6: Cloudflare verification opens exact episode URL")
