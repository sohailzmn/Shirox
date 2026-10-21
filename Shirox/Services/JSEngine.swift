import Foundation
@preconcurrency import JavaScriptCore
import Combine

@MainActor
final class JSEngine: ObservableObject {
    static let shared = JSEngine()

    private(set) var context: JSContext

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        return URLSession(configuration: config)
    }()

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    private init() {
        context = JSContext()!
        setupContext()
    }

    // MARK: - Module Loading

    func loadModule(_ module: ModuleDefinition) async throws {
        // Clear cookies so the previous module's session doesn't bleed into this one
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        NetworkFetchManager.clearCookies()

        let script: String
        if let cached = module.scriptContent {
            script = cached
        } else {
            guard let url = URL(string: module.scriptUrl) else {
                throw URLError(.badURL)
            }
            let (data, _) = try await session.data(from: url)
            guard let fetched = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotDecodeContentData)
            }
            script = fetched
        }

        // Fresh context for each module
        context = JSContext()!
        setupContext()
        context.evaluateScript(script)
        if let exception = context.exception {
            Logger.shared.log("[JSEngine] Script load error: \(exception)", type: "Error")
        }
    }

    // MARK: - Context Setup

    private func setupContext() {
        setupConsoleLogging()
        setupBase64()
        setupFetchV2()
        setupFetchAliases()
        setupSoraCompat()
        setupScrapingUtilities()
        setupMangaBridge()
        setupTimers()
        context.setupNetworkFetch()
        context.setupNetworkFetchSimple()

        context.exceptionHandler = { _, exception in
            Logger.shared.log("[JS Exception] \(exception?.toString() ?? "unknown")", type: "Error")
        }
    }

    // MARK: - Console Bridge

    private func setupConsoleLogging() {
        let consoleLog: @convention(block) (JSValue) -> Void = { value in
            Logger.shared.log("[JS] \(value.toString() ?? "undefined")", type: "Debug")
        }
        let consoleError: @convention(block) (JSValue) -> Void = { value in
            Logger.shared.log("[JS Error] \(value.toString() ?? "undefined")", type: "Error")
        }
        let consoleWarn: @convention(block) (JSValue) -> Void = { value in
            Logger.shared.log("[JS Warn] \(value.toString() ?? "undefined")", type: "General")
        }
        let consoleObj = JSValue(newObjectIn: context)!
        consoleObj.setObject(consoleLog, forKeyedSubscript: "log" as NSString)
        consoleObj.setObject(consoleError, forKeyedSubscript: "error" as NSString)
        consoleObj.setObject(consoleWarn, forKeyedSubscript: "warn" as NSString)
        consoleObj.setObject(consoleLog, forKeyedSubscript: "debug" as NSString)
        context.setObject(consoleObj, forKeyedSubscript: "console" as NSString)
    }

    // MARK: - Base64 Bridge

    private func setupBase64() {
        let btoa: @convention(block) (String) -> String = { input in
            Data(input.utf8).base64EncodedString()
        }
        let atob: @convention(block) (String) -> String = { input in
            guard let data = Data(base64Encoded: input) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        context.setObject(btoa, forKeyedSubscript: "btoa" as NSString)
        context.setObject(atob, forKeyedSubscript: "atob" as NSString)
    }

    // MARK: - fetchv2 Bridge

    private func setupFetchV2() {
        // The native function called from JS. It starts a URLSession task and calls
        // the resolve/reject callbacks when done.
        // All parameters are JSValue (non-optional) — JSCore always provides non-nil JSValue
        // objects; null/undefined JS values have isNull/isUndefined == true, never Swift nil.
        let fetchNative: @convention(block) (String, JSValue, JSValue, JSValue, JSValue, JSValue) -> Void =
        { [weak self] urlString, headersVal, methodVal, bodyVal, resolve, reject in
            guard let self else {
                reject.call(withArguments: ["JSEngine deallocated"])
                return
            }
            guard let url = URL(string: urlString) else {
                reject.call(withArguments: ["Invalid URL: \(urlString)"])
                return
            }
            if HostBlocklist.shared.isBlocked(url) {
                reject.call(withArguments: ["Blocked host: \(url.host ?? urlString)"])
                return
            }

            let method = (methodVal.isNull || methodVal.isUndefined) ? "GET" : (methodVal.toString() ?? "GET")
            let body: String? = (bodyVal.isNull || bodyVal.isUndefined) ? nil : bodyVal.toString()
            // Extract headers before entering the Task (JSValue is not Sendable)
            let jsHeaders = (!headersVal.isUndefined && !headersVal.isNull)
                ? (headersVal.toDictionary() as? [String: String] ?? [:])
                : [String: String]()

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
            for (key, value) in jsHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }

            if let body, let bodyData = body.data(using: .utf8) {
                request.httpBody = bodyData
            }

            let ctx = self.context

            Task {
                do {
                    // CF cookie injection — inject all bypass session cookies, not just cf_clearance,
                    // because some APIs (e.g. AllAnime) require additional Turnstile session cookies.
                    if let host = url.host,
                       let bypassHeader = CloudflareBypassManager.shared.fullCookieHeader(for: host) {
                        let existing = request.value(forHTTPHeaderField: "Cookie") ?? ""
                        request.setValue(
                            existing.isEmpty ? bypassHeader : "\(existing); \(bypassHeader)",
                            forHTTPHeaderField: "Cookie"
                        )
                        // cf_clearance is UA-bound — replay the UA that solved the challenge,
                        // otherwise CF rejects the cookie and evicts the cache via flagPendingVerification.
                        if let ua = CloudflareBypassManager.shared.bypassUserAgent(for: host) {
                            request.setValue(ua, forHTTPHeaderField: "User-Agent")
                        }
                    }

                    var (data, response) = try await self.session.data(for: request)
                    guard var httpResponse = response as? HTTPURLResponse else {
                        reject.call(withArguments: ["No response data"])
                        return
                    }
                    var responseText = String(data: data, encoding: .utf8) ?? ""

                    // CF reactive retry: bypass the final redirect destination, then retry directly
                    // against that URL — avoids cross-domain Cookie stripping on URLSession redirects.
                    if JSEngine.isTurnstileResponse(status: httpResponse.statusCode, body: responseText) {
                        let cfResponseURL = httpResponse.url ?? url
                        // We have a solved session if either the live bypass WebView is still
                        // around, or a persisted cookie survived a relaunch. Retry the FINAL URL
                        // directly with that cookie+UA — URLSession strips cookies on cross-domain
                        // redirects, which is what walled the first request in the first place.
                        let recovered = await CloudflareBypassManager.shared.retryWithSolvedSession(
                            for: cfResponseURL,
                            method: request.httpMethod ?? "GET",
                            body: request.httpBody,
                            extraHeaders: request.allHTTPHeaderFields ?? [:],
                            session: self.session
                        )
                        if let recovered {
                            data = recovered.data
                            httpResponse = recovered.response
                            responseText = String(data: recovered.data, encoding: .utf8) ?? ""
                        } else {
                            // No usable session, or the session itself is now walled — defer to a
                            // user-initiated "Verify Cloudflare" action instead of silently failing.
                            await CloudflareBypassManager.shared.flagPendingVerification(for: cfResponseURL)
                        }
                    }

                    let status = httpResponse.statusCode

                    var headersDict: [String: String] = [:]
                    for (key, value) in httpResponse.allHeaderFields {
                        headersDict[String(describing: key)] = String(describing: value)
                    }

                    let responseObj = JSValue(newObjectIn: ctx)!
                    responseObj.setValue(status, forProperty: "status")
                    responseObj.setValue(status >= 200 && status < 300, forProperty: "ok")
                    responseObj.setValue(httpResponse.url?.absoluteString ?? urlString, forProperty: "url")
                    responseObj.setValue(headersDict, forProperty: "headers")

                    // text() method
                    let textFn: @convention(block) () -> String = { responseText }
                    responseObj.setObject(textFn, forKeyedSubscript: "text" as NSString)

                    // json() method
                    let jsonFn: @convention(block) () -> JSValue = {
                        let script = "JSON.parse(\(Self.jsStringLiteral(responseText)))"
                        return ctx.evaluateScript(script) ?? JSValue(undefinedIn: ctx)
                    }
                    responseObj.setObject(jsonFn, forKeyedSubscript: "json" as NSString)

                    resolve.call(withArguments: [responseObj])
                } catch {
                    reject.call(withArguments: [error.localizedDescription])
                }
            }
        }

        context.setObject(fetchNative, forKeyedSubscript: "fetchv2Native" as NSString)

        // JS wrapper that returns a Promise
        let fetchv2JS = """
        function fetchv2(url, headers, method, body) {
            return new Promise(function(resolve, reject) {
                fetchv2Native(url, headers || {}, method || 'GET', body || null, resolve, reject);
            });
        }
        """
        context.evaluateScript(fetchv2JS)
    }

    // MARK: - Fetch Aliases (Sora compatibility)

    private func setupFetchAliases() {
        context.evaluateScript("""
        function soraFetch(url, options) {
            var headers = {}, method = 'GET', body = null;
            if (options) {
                headers = options.headers || {};
                method  = options.method  || 'GET';
                body    = options.body    || null;
            }
            return fetchv2(url, headers, method, body);
        }
        function fetch(url, options) {
            return soraFetch(url, options);
        }
        """)
    }

    private func setupSoraCompat() {
        // _0xB4F2 is a module validation function required by some Sora modules.
        // It must return a 16-char string whose lowercase chars contain c,r,a,n,c,i.
        let tokenBlock: @convention(block) () -> String = { "shirox-cranci-10" }
        context.setObject(tokenBlock, forKeyedSubscript: "_0xB4F2" as NSString)

        context.evaluateScript("""
        if (typeof sendLog === 'undefined') {
            function sendLog(msg) { console.log('[Module] ' + msg); }
        }
        """)
    }

    // MARK: - Timers

    private func setupTimers() {
        var timerMap: [Int: DispatchWorkItem] = [:]
        var nextId = 1

        let setTimeoutBlock: @convention(block) (JSValue, Double) -> Int = { callback, delay in
            let id = nextId
            nextId += 1
            let item = DispatchWorkItem {
                timerMap.removeValue(forKey: id)
                callback.call(withArguments: [])
            }
            timerMap[id] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0) / 1000.0, execute: item)
            return id
        }

        let clearTimeoutBlock: @convention(block) (Int) -> Void = { id in
            timerMap[id]?.cancel()
            timerMap.removeValue(forKey: id)
        }

        let setIntervalBlock: @convention(block) (JSValue, Double) -> Int = { callback, delay in
            let id = nextId
            nextId += 1
            let interval = max(delay, 16) / 1000.0
            func schedule() {
                guard timerMap[id] != nil else { return }
                let item = DispatchWorkItem {
                    guard timerMap[id] != nil else { return }
                    callback.call(withArguments: [])
                    schedule()
                }
                timerMap[id] = item
                DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
            }
            timerMap[id] = DispatchWorkItem {}
            schedule()
            return id
        }

        context.setObject(setTimeoutBlock, forKeyedSubscript: "setTimeout" as NSString)
        context.setObject(clearTimeoutBlock, forKeyedSubscript: "clearTimeout" as NSString)
        context.setObject(setIntervalBlock, forKeyedSubscript: "setInterval" as NSString)
        context.setObject(clearTimeoutBlock, forKeyedSubscript: "clearInterval" as NSString)
    }

    // MARK: - Scraping Utilities

    private func setupScrapingUtilities() {
        let utilsJS = """
        function getElementsByTag(html, tag) {
            var regex = new RegExp('<' + tag + '[^>]*>([\\\\s\\\\S]*?)</' + tag + '>', 'gi');
            var matches = [];
            var match;
            while ((match = regex.exec(html)) !== null) {
                matches.push(match[0]);
            }
            return matches;
        }

        function getAttribute(element, attr) {
            var regex = new RegExp(attr + '=["\\'](.*?)["\\']');
            var match = element.match(regex);
            return match ? match[1] : '';
        }

        function getInnerText(element) {
            return element.replace(/<[^>]*>/g, '').trim();
        }

        function stripHtml(html) {
            return html.replace(/<[^>]*>/g, '');
        }
        """
        context.evaluateScript(utilsJS)
    }

    // MARK: - Helpers

    /// Resolves a JS Promise by calling the given function name with arguments,
    /// then invokes the completion handler with the result string.
    func callAsyncJS(_ functionName: String, args: [Any], completion: @escaping (Result<String, Error>) -> Void) {
        guard let fn = context.objectForKeyedSubscript(functionName),
              !fn.isUndefined else {
            completion(.failure(JSEngineError.functionNotFound(functionName)))
            return
        }

        let promise = fn.call(withArguments: args)

        guard let promise, !promise.isUndefined, !promise.isNull else {
            completion(.failure(JSEngineError.nullResult))
            return
        }

        // Async module functions return a Promise; synchronous ones (e.g. the
        // local-playback bridge) return a plain value. If the return isn't a
        // thenable, resolve with it directly — calling .then/.catch on a string
        // throws "undefined is not an object" and the completion never fires.
        let thenValue = promise.objectForKeyedSubscript("then")
        if thenValue == nil || thenValue?.isUndefined == true {
            let str = promise.toString() ?? ""
            DispatchQueue.main.async { completion(.success(str)) }
            return
        }

        let thenBlock: @convention(block) (JSValue) -> Void = { result in
            let str = result.toString() ?? ""
            DispatchQueue.main.async {
                completion(.success(str))
            }
        }

        let catchBlock: @convention(block) (JSValue) -> Void = { error in
            let msg = error.toString() ?? "Unknown JS error"
            DispatchQueue.main.async {
                completion(.failure(JSEngineError.jsError(msg)))
            }
        }

        let thenFn = JSValue(object: thenBlock, in: context)
        let catchFn = JSValue(object: catchBlock, in: context)

        promise.invokeMethod("then", withArguments: [thenFn as Any])
        promise.invokeMethod("catch", withArguments: [catchFn as Any])
    }

    /// Async wrapper for callAsyncJS.
    ///
    /// Bounded and resume-once, because the underlying callback is driven by a JS Promise from an
    /// untrusted module script:
    ///
    /// * A promise that never settles (a hung request inside the module, a swallowed rejection,
    ///   a code path that simply never calls resolve) left the continuation suspended forever.
    ///   Every caller inherited that: the stream picker span forever, `refetchStream` never
    ///   released `isRefetchingStream` — blocking all later recovery — and the next-episode
    ///   prefetch leaked a task. Cancelling the enclosing Task does not resume a continuation, so
    ///   even backing out of the screen didn't clear it. The timeout converts a hang into a normal
    ///   error the existing paths already handle.
    /// * A thenable that invokes both its resolve and reject callbacks (or either one twice) would
    ///   resume the continuation more than once, which traps at runtime. The gate makes the first
    ///   outcome win and drops the rest.
    func callAsyncJS(_ functionName: String, args: [Any], timeout: TimeInterval = 120) async throws -> String {
        let gate = ContinuationGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                gate.attach(cont)
                callAsyncJS(functionName, args: args) { result in
                    gate.settle(result)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    gate.settle(.failure(JSEngineError.timedOut(functionName)))
                }
            }
        } onCancel: {
            gate.settle(.failure(CancellationError()))
        }
    }

    static func isTurnstileResponse(status: Int, body: String) -> Bool {
        // Some sites return a 200 HTML "Just a moment" page or a 403
        // challenge without the word "Cloudflare". Never treat a normal
        // series page or an ordinary HTTP 403 as a challenge.
        guard status == 200 || status == 403 || status == 503 else { return false }
        let lower = body.lowercased()
        let challengeMarkers = lower.contains("cf-turnstile") ||
            lower.contains("challenges.cloudflare.com") ||
            lower.contains("__cf_chl_") ||
            lower.contains("jschl") ||
            lower.contains("challenge-platform") ||
            lower.contains("cf-spinner") ||
            lower.contains("cf-mitigated")
        let challengePage = (lower.contains("just a moment") ||
            lower.contains("checking your browser") ||
            lower.contains("verify you are human") ||
            lower.contains("security check")) &&
            (lower.contains("cloudflare") || lower.contains("challenge"))
        return challengeMarkers || challengePage
    }

    static func jsStringLiteral(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

/// Resume-once gate for a checked continuation that several independent callbacks can complete
/// (the JS promise, a timeout, task cancellation). Only the first outcome is delivered.
/// Shared by `JSEngine` and `ModuleJSRunner`, which both bridge untrusted module promises.
final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var pending: Result<String, Error>?
    private var finished = false

    /// Stores the continuation, delivering immediately if an outcome already arrived.
    func attach(_ cont: CheckedContinuation<String, Error>) {
        lock.lock()
        if let pending {
            self.pending = nil
            finished = true
            lock.unlock()
            cont.resume(with: pending)
            return
        }
        continuation = cont
        lock.unlock()
    }

    /// Delivers the first outcome; later calls are no-ops.
    func settle(_ result: Result<String, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard let cont = continuation else {
            // Raced ahead of attach (cancellation can fire before the body runs) — hold it.
            pending = result
            lock.unlock()
            return
        }
        continuation = nil
        finished = true
        lock.unlock()
        cont.resume(with: result)
    }
}

enum JSEngineError: LocalizedError {
    case functionNotFound(String)
    case nullResult
    case jsError(String)
    case parseError(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .functionNotFound(let name): return "JS function '\(name)' not found in module"
        case .nullResult: return "JS function returned null/undefined"
        case .jsError(let msg): return "JS error: \(msg)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .timedOut(let name): return "Module function '\(name)' timed out"
        }
    }
}
