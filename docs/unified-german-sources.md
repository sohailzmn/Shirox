# Unified German Sources for Shirox

This fork auto-installs a single **Shirox Unified GER (AniWorld + S.to)** module on the first successful launch. The manifest and bundled JavaScript source are hosted in [sohailzmn/sora-modules](https://github.com/sohailzmn/sora-modules).

- Search and episode lists use two separately scoped source adapters.
- A failed catalogue request does not hide results from the other catalogue.
- Source adapters retain multiple distinct verified stream candidates where available.
- Shirox's existing Smart Play and player recovery handle candidate choice and playback fallback.
- No private streaming server, public proxy, fixed credentials or additional cloud bills.
- Existing installed modules remain in place; if the user removes the unified module it is not silently re-added.
- The app waits for the first bootstrap when the user taps Watch right after launch.
- The app never automates CAPTCHA/Turnstile; users may have to complete a website verification.

This integration is **not** a deployment of AniBridge's Python server. It brings its unified-source/fallback goal to the native module architecture and avoids exposing a cloud proxy. A Python server could be added later to connect supported, authorized media libraries if needed.

## Testing
The isolated modules and combined JS wrapper were syntax-checked and passed synthetic routing/dedup/error-isolation checks. Actual playback and provider authorization remain dependent on the user/network, third-party site and hoster; no 100% uptime guarantee is possible.

## Release
Only merge this branch after verifying a Swift/iOS build and on-device playback. The existing nightly workflow publishes an unsigned IPA only when a build runs from `main`.
