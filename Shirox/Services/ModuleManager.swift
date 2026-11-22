import Foundation
import SwiftUI
import Combine

/// The bundled resolver is a minimum revision for this app, including when a
/// detail view still holds a value copied before the launch migration.
enum SourceModuleRevision {
    static func effective(_ module: ModuleDefinition) -> ModuleDefinition {
        guard var bundled = BundledUnifiedSource.module, module.id == bundled.id,
              module.version.compare(bundled.version, options: .numeric) != .orderedDescending else { return module }
        bundled.jsonUrl = module.jsonUrl
        return bundled
    }

    static func acceptsRemote(_ fresh: ModuleDefinition, replacing old: ModuleDefinition) -> Bool {
        guard fresh.id == old.id else { return false }
        if old.id == BundledUnifiedSource.module?.id {
            return fresh.version.compare(effective(old).version, options: .numeric) == .orderedDescending
        }
        return fresh.version != old.version
    }
}

/// Mirror of MangaModuleResolver's preference, for the anime side: keep the active
/// module if it's an anime (non-manga) module, else fall back to the first anime
/// module, else nil.
enum AnimeModulePreference {
    static func pick(active: ModuleDefinition?, modules: [ModuleDefinition]) -> ModuleDefinition? {
        if let active, active.isManga == false { return active }
        return modules.first { $0.isManga == false }
    }
}

@MainActor
final class ModuleManager: ObservableObject {
    static let shared = ModuleManager()

    @Published var modules: [ModuleDefinition] = []
    @Published var activeModule: ModuleDefinition?
    @Published var moduleReadyId: String? = nil
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let storageKey = "savedModules"
    private let activeKey = "activeModuleId"

    // Optional, self-contained German source shipped by this fork. Install it once
    // without replacing users' selected modules, credentials, or local files.
    private let unifiedGermanURL =
        "https://raw.githubusercontent.com/sohailzmn/sora-modules/main/UnifiedGerman_v1.json"
    private let unifiedGermanInstalledKey = "shiroxUnifiedGermanBootstrappedV1"
    private var unifiedGermanBootstrapTask: Task<Void, Never>?
    private var didCheckUnifiedGermanThisLaunch = false

    private init() {
        loadFromStorage()
        Task { [weak self] in
            await self?.ensureUnifiedGermanSource()
        }
    }

    /// Safe to call at launch and again when the user taps Watch immediately:
    /// both callers await the same task, never installing duplicate modules.
    /// A failed network import is retried on next launch. Removing this optional
    /// module later is respected because the successful bootstrap flag persists.
    func ensureUnifiedGermanSource() async {
        if let inFlight = unifiedGermanBootstrapTask {
            await inFlight.value
            return
        }
        guard !didCheckUnifiedGermanThisLaunch else { return }
        didCheckUnifiedGermanThisLaunch = true

        let task = Task { @MainActor in
            if installBundledSource() {
                // The app and its tested resolver ship together. A remote update
                // is optional and must never delay the first playback attempt.
                Task { await self.refreshUnifiedGermanSource() }
                return
            }
            // Already installed? Pick up a repaired manifest/script at launch.
            // Respect explicit user removal: do not silently reinstall it.
            if UserDefaults.standard.bool(forKey: unifiedGermanInstalledKey) {
                await refreshUnifiedGermanSource()
                return
            }
            if modules.contains(where: { $0.jsonUrl == unifiedGermanURL }) {
                UserDefaults.standard.set(true, forKey: unifiedGermanInstalledKey)
                return
            }
            guard let url = URL(string: unifiedGermanURL) else { return }
            await addModule(from: url)
            if modules.contains(where: { $0.jsonUrl == unifiedGermanURL }) {
                UserDefaults.standard.set(true, forKey: unifiedGermanInstalledKey)
            }
        }
        unifiedGermanBootstrapTask = task
        await task.value
        unifiedGermanBootstrapTask = nil
    }

    @discardableResult
    private func installBundledSource() -> Bool {
        guard var bundled = BundledUnifiedSource.module else { return false }
        bundled.jsonUrl = unifiedGermanURL
        if let index = modules.firstIndex(where: { $0.id == bundled.id || $0.jsonUrl == unifiedGermanURL }) {
            if bundled.version.compare(modules[index].version, options: .numeric) == .orderedDescending {
                let active = activeModule?.id == modules[index].id
                modules[index] = bundled
                saveToStorage()
                if active { selectModule(bundled) }
            }
            return true
        }
        // An explicit removal remains respected across app upgrades.
        guard !UserDefaults.standard.bool(forKey: unifiedGermanInstalledKey) else { return false }
        modules.append(bundled)
        UserDefaults.standard.set(true, forKey: unifiedGermanInstalledKey)
        saveToStorage()
        if activeModule == nil { selectModule(bundled) }
        return true
    }

    /// Refresh only the bundled unified source, not unrelated third-party
    /// modules. A cached working script remains installed if GitHub is offline.
    private func refreshUnifiedGermanSource() async {
        guard modules.contains(where: { $0.jsonUrl == unifiedGermanURL }),
              let jsonURL = URL(string: unifiedGermanURL) else { return }
        do {
            var request = URLRequest(url: jsonURL)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            var fresh = try JSONDecoder().decode(ModuleDefinition.self, from: data)
            guard let old = modules.first(where: { $0.jsonUrl == unifiedGermanURL }),
                  fresh.version.compare(old.version, options: .numeric) == .orderedDescending,
                  fresh.scriptUrl == old.scriptUrl else { return }

            fresh.jsonUrl = unifiedGermanURL
            await cacheAssets(for: &fresh)
            // Never replace a cached module with a manifest whose JS failed
            // to download, or re-add it after the user removed it mid-refresh.
            guard let script = fresh.scriptContent, !script.isEmpty,
                  let index = modules.firstIndex(where: { $0.jsonUrl == unifiedGermanURL }) else { return }
            let wasActive = activeModule?.id == modules[index].id
            modules[index] = fresh
            saveToStorage()
            if wasActive { selectModule(fresh) }
            Logger.shared.log("[Modules] Unified German source updated to \(fresh.version)", type: "Debug")
        } catch {
            Logger.shared.log("[Modules] Unified German update skipped: \(error.localizedDescription)", type: "Debug")
        }
    }

    // MARK: - Add Module

    func addModule(from jsonURL: URL) async {
        isLoading = true
        errorMessage = nil
        do {
            let (data, _) = try await URLSession.shared.data(from: jsonURL)
            var module = try JSONDecoder().decode(ModuleDefinition.self, from: data)
            module.jsonUrl = jsonURL.absoluteString

            // Cache script and icon
            await cacheAssets(for: &module)

            // Avoid duplicates
            if modules.contains(where: { $0.id == module.id }) {
                modules.removeAll { $0.id == module.id }
            }
            modules.append(module)
            saveToStorage()

            // Auto-select if it's the first module
            if activeModule == nil {
                selectModule(module)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Remove Module

    func removeModule(_ module: ModuleDefinition) {
        modules.removeAll { $0.id == module.id }
        if activeModule?.id == module.id {
            activeModule = nil
        }
        saveToStorage()
    }

    // MARK: - Select Module

    func selectModule(_ module: ModuleDefinition) {
        let module = SourceModuleRevision.effective(module)
        activeModule = module
        UserDefaults.standard.set(module.id, forKey: activeKey)
        
        Task {
            do {
                try await JSEngine.shared.loadModule(module)
                moduleReadyId = module.id
            } catch {
                Logger.shared.log("[ModuleManager] Failed to load JS for module \(module.sourceName): \(error.localizedDescription)", type: "Error")
            }
        }
    }

    /// Like selectModule, but suspends until the module's JS is loaded.
    /// Returns false when the script failed to load. Used by flows that must
    /// call into the module immediately after switching (Continue Reading).
    func selectAndAwaitReady(_ module: ModuleDefinition) async -> Bool {
        let module = SourceModuleRevision.effective(module)
        activeModule = module
        UserDefaults.standard.set(module.id, forKey: activeKey)
        do {
            try await JSEngine.shared.loadModule(module)
            moduleReadyId = module.id
            return true
        } catch {
            Logger.shared.log("[ModuleManager] Failed to load JS for module \(module.sourceName): \(error.localizedDescription)", type: "Error")
            return false
        }
    }

    // MARK: - Reorder Modules

    func moveModules(from source: IndexSet, to destination: Int) {
        modules.move(fromOffsets: source, toOffset: destination)
        saveToStorage()
    }

    func deselectModule() {
        activeModule = nil
        UserDefaults.standard.removeObject(forKey: activeKey)
    }

    // MARK: - Restore Active Module on Launch

    func restoreActiveModule() async {
        await ensureUnifiedGermanSource()
        guard let savedId = UserDefaults.standard.string(forKey: activeKey),
              let module = modules.first(where: { $0.id == savedId }) else { return }
        selectModule(module)
    }

    // MARK: - Backup Restore

    /// Replaces the installed module list from a backup by re-fetching each manifest.
    /// Returns the `jsonUrl`s that could not be installed, so the import can report them.
    ///
    /// Re-fetching rather than restoring stored definitions keeps the backup file small:
    /// a `ModuleDefinition` carries the module's whole script in `scriptContent` and its
    /// icon as base64 in `iconData`.
    func restoreModules(jsonUrls: [String], activeId: String?) async -> [String] {
        modules = []
        activeModule = nil
        saveToStorage()

        var failed: [String] = []
        for urlString in jsonUrls {
            guard let url = URL(string: urlString) else {
                failed.append(urlString)
                continue
            }
            let before = modules.count
            await addModule(from: url)
            if modules.count == before { failed.append(urlString) }
        }

        if let activeId, let module = modules.first(where: { $0.id == activeId }) {
            selectModule(module)
        }
        return failed
    }

    // MARK: - Auto-Update

    func checkForUpdates() async {
        await ensureUnifiedGermanSource()
        var didUpdate = false
        for installed in modules {
            guard let jsonUrlStr = installed.jsonUrl,
                  let jsonURL = URL(string: jsonUrlStr),
                  let (data, _) = try? await URLSession.shared.data(from: jsonURL),
                  var fresh = try? JSONDecoder().decode(ModuleDefinition.self, from: data),
                  SourceModuleRevision.acceptsRemote(fresh, replacing: installed) else { continue }
            fresh.jsonUrl = jsonUrlStr
            
            // Cache fresh assets
            await cacheAssets(for: &fresh)

            // Network awaits allow removal or another update. Recheck the live
            // revision and never replace a working resolver with an empty cache.
            guard fresh.scriptContent?.isEmpty == false,
                  let i = modules.firstIndex(where: { $0.id == installed.id }),
                  SourceModuleRevision.acceptsRemote(fresh, replacing: modules[i]) else { continue }
            
            let wasActive = activeModule?.id == modules[i].id
            modules[i] = fresh
            if wasActive { selectModule(fresh) }
            didUpdate = true
        }
        if didUpdate { saveToStorage() }
    }

    // MARK: - Asset Caching

    private func cacheAssets(for module: inout ModuleDefinition) async {
        // 1. Script
        if let scriptURL = URL(string: module.scriptUrl) {
            var request = URLRequest(url: scriptURL)
            request.timeoutInterval = 12
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let script = String(data: data, encoding: .utf8), !script.isEmpty {
                module.scriptContent = script
            }
        }
        
        // 2. Icon
        if let iconUrlStr = module.iconUrl,
           let iconURL = URL(string: iconUrlStr),
           let (data, _) = try? await URLSession.shared.data(from: iconURL) {
            module.iconData = data.base64EncodedString()
        }
    }

    // MARK: - Persistence

    private func saveToStorage() {
        if let data = try? JSONEncoder().encode(modules) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([ModuleDefinition].self, from: data) else { return }
        modules = saved
    }
}
