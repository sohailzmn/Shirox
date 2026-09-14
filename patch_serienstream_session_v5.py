#!/usr/bin/env python3
from pathlib import Path

# Runs after patch_serienstream_interactive.py and patch_serienstream_interactive_v3.py.
# Goal: verification is exceptional, not per-episode. We reuse the persistent WKWebView
# cookie/session store and first try each provider flow invisibly. Only if that fast path
# cannot reach the provider do we surface the existing manual Security Check UI.

path = Path("Shirox/Services/NetworkFetch.swift")
text = path.read_text(encoding="utf-8")
marker = "// MARK: - NetworkFetchManager"
if marker not in text:
    raise SystemExit("v5: NetworkFetchManager marker not found")
head, tail = text.split(marker, 1)

old = '''    private var interactiveSerienStream = false

    private func isSerienStreamHost(_ host: String?) -> Bool {'''
new = '''    private var interactiveSerienStream = false
    private var serienStreamFastProbe = false
    private var serienStreamProviderCaptured = false
    private let serienStreamSessionKey = "shirox.serienstream.session.validatedAt"

    private func serienStreamSessionIsFresh() -> Bool {
        let ts = UserDefaults.standard.double(forKey: serienStreamSessionKey)
        guard ts > 0 else { return false }
        return Date().timeIntervalSince1970 - ts < 6 * 60 * 60
    }

    private func markSerienStreamSessionFresh() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: serienStreamSessionKey)
        serienStreamFastProbe = true
    }

    private func presentSerienStreamVerificationIfNeeded() {
        #if os(iOS)
        guard interactiveSerienStream,
              completionHandler != nil,
              !serienStreamProviderCaptured,
              !cutoffTriggered,
              let webView else { return }
        CloudflareBypassManager.shared.activeBypassWebView = webView
        CloudflareBypassManager.shared.setActiveBypassFinishHandler { [weak self] in
            self?.continueAfterManualSerienStreamVerification()
        }
        #endif
    }

    private func continueAfterManualSerienStreamVerification() {
        // The user has completed whatever visible verification was necessary. Re-trigger
        // only the selected provider button (never the CAPTCHA itself), then give the page
        // a short window to expose the provider URL before returning control to the module.
        armSerienStreamProviderButton()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.completionHandler != nil else { return }
            if self.serienStreamProviderCaptured || self.cutoffTriggered {
                self.markSerienStreamSessionFresh()
            }
            self.stopMonitoring(reason: "user-finished")
        }
    }

    private func isSerienStreamHost(_ host: String?) -> Bool {'''
if old not in tail:
    raise SystemExit("v5: interactive property block not found")
tail = tail.replace(old, new, 1)

old = '''        if let candidate = URL(string: urlString) {
            interactiveSerienStream = isSerienStreamHost(candidate.host) && candidate.path == "/r"
        } else {
            interactiveSerienStream = false
        }
        completionHandler = completion'''
new = '''        if let candidate = URL(string: urlString) {
            interactiveSerienStream = isSerienStreamHost(candidate.host) && candidate.path == "/r"
        } else {
            interactiveSerienStream = false
        }
        serienStreamFastProbe = interactiveSerienStream && serienStreamSessionIsFresh()
        serienStreamProviderCaptured = false
        completionHandler = completion'''
if old not in tail:
    raise SystemExit("v5: startMonitoring state block not found")
tail = tail.replace(old, new, 1)

old = '''            #if os(iOS)
            if interactiveSerienStream, let webView {
                // Reuse Shirox's existing high-level verification window. The page is fully
                // user-controlled: no CAPTCHA/Turnstile click is automated.
                CloudflareBypassManager.shared.activeBypassWebView = webView
                CloudflareBypassManager.shared.setActiveBypassFinishHandler { [weak self] in
                    self?.stopMonitoring(reason: "user-finished")
                }
            }
            #endif'''
new = '''            #if os(iOS)
            if interactiveSerienStream {
                // Fast path: the WKWebsiteDataStore is persistent, so after one successful
                // manual verification most later episodes can resolve silently. On a fresh
                // session give it longer; otherwise show the manual sheet quickly.
                let delayNs: UInt64 = serienStreamFastProbe ? 4_000_000_000 : 1_200_000_000
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: delayNs)
                    self?.presentSerienStreamVerificationIfNeeded()
                }
            }
            #endif'''
if old not in tail:
    raise SystemExit("v5: immediate verification presentation block not found")
tail = tail.replace(old, new, 1)

old = '''    private func addRequest(_ urlString: String) {
        if !networkRequests.contains(urlString) {
            networkRequests.append(urlString)
            if let cutoff = options?.cutoff, !cutoff.isEmpty,
               urlString.lowercased().contains(cutoff.lowercased()),
               !cutoffTriggered {
                cutoffTriggered = true
                cutoffUrl = urlString
                stopMonitoring(reason: "cutoff")
            }
        }
    }'''
new = '''    private func addRequest(_ urlString: String) {
        if !networkRequests.contains(urlString) {
            networkRequests.append(urlString)

            if interactiveSerienStream,
               let u = URL(string: urlString),
               !isSerienStreamHost(u.host) {
                let lower = urlString.lowercased()
                let host = (u.host ?? "").lowercased()
                let cutoffMatch = options?.cutoff.map { !$0.isEmpty && lower.contains($0.lowercased()) } ?? false
                let providerLike = ["voe", "dood", "vidmoly", "streamtape", "filemoon", "streamwish", "vidoza"]
                    .contains { host.contains($0) || lower.contains($0) }
                if cutoffMatch || providerLike {
                    serienStreamProviderCaptured = true
                    markSerienStreamSessionFresh()
                }
            }

            if let cutoff = options?.cutoff, !cutoff.isEmpty,
               urlString.lowercased().contains(cutoff.lowercased()),
               !cutoffTriggered {
                cutoffTriggered = true
                cutoffUrl = urlString
                stopMonitoring(reason: "cutoff")
            }
        }
    }'''
if old not in tail:
    raise SystemExit("v5: addRequest block not found")
tail = tail.replace(old, new, 1)

path.write_text(head + marker + tail, encoding="utf-8")
print("Applied SerienStream v5 session reuse: silent fast path + manual fallback only when needed")
