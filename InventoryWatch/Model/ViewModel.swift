//
//  ViewModel.swift
//  InventoryWatch
//
//  Created by Worth Baker on 10/25/22.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.wehbs.ReadyForPickup", category: "Inventory")

@MainActor
final class ViewModel: ObservableObject {

    private let fulfillmentModel = FulfillmentModel()

    @Published var searches: [SavedSearch] = []
    @Published var selectedSearchID: UUID?
    @Published var results: [UUID: [(FulfillmentStore, [PartAvailability])]] = [:]
    @Published var lastUpdated: [UUID: Date] = [:]
    @Published var searchErrors: [UUID: String] = [:]
    @Published var stores: [RetailStore] = []
    @Published var skuDataByProduct: [ProductType: SKUData] = [:]

    // Fetches in flight per search. A count, not a flag: one search
    // can be fetched twice at once (e.g. edited during a sweep).
    @Published private var fetchesInFlight: [UUID: Int] = [:]

    // Auto-refresh (minutes; 0 = Off). Stored as
    // `preferredUpdateInterval` (shared with the Settings picker); only
    // 0/5/10/15/30 are honoured - any other stored value is coerced to 5.
    @Published var autoRefreshIntervalMinutes: Int = 5
    @Published var nextAutoRefreshAt: Date?
    @Published var throttledUntil: Date?

    @Published var pushoverEnabled: Bool = PushoverSettings.isEnabled
    @Published var pushoverConfigured: Bool = PushoverSettings.isConfigured
    @Published var pushoverFeedback: String?

    private var autoRefreshTask: Task<Void, Never>?
    private var sweepTask: Task<Void, Never>?
    private var isMonitoring = false
    private var throttleFailureCount = 0
    private var lastNotifiedPreferredKeys: [UUID: Set<String>] = [:]

    /// Allowed auto-refresh intervals in minutes (0 = Off).
    static let allowedIntervals = [0, 5, 10, 15, 30]

    init() {
        searches = SearchStore.load()
        selectedSearchID = searches.first?.id

        let stored = UserDefaults.standard.object(forKey: "preferredUpdateInterval") as? Int
        if let stored, Self.allowedIntervals.contains(stored) {
            autoRefreshIntervalMinutes = stored
        } else {
            autoRefreshIntervalMinutes = 5
            UserDefaults.standard.set(5, forKey: "preferredUpdateInterval")
        }
    }

    var selectedSearch: SavedSearch? {
        searches.first(where: { $0.id == selectedSearchID }) ?? searches.first
    }

    func storeName(for search: SavedSearch) -> String {
        stores.first(where: { $0.storeNumber == search.storeNumber })?.name
            ?? search.storeName ?? search.storeNumber
    }

    func availableCount(for search: SavedSearch) -> Int {
        (results[search.id] ?? []).reduce(0) { $0 + $1.1.count }
    }

    /// Any fetch in flight (toolbar spinner).
    var isLoading: Bool { fetchesInFlight.isEmpty == false }

    func isFetching(_ search: SavedSearch) -> Bool {
        fetchesInFlight[search.id] != nil
    }

    // MARK: - Stores & SKU data

    func loadStores() async {
        if stores.isEmpty == false { return }
        do {
            stores = try await fulfillmentModel.storesForPreferredCountry()
                .sorted { ($0.address.stateName ?? "") < ($1.address.stateName ?? "") }
            // Backfill store names on searches once stores are known.
            for idx in searches.indices {
                searches[idx].storeName = stores.first(where: { $0.storeNumber == searches[idx].storeNumber })?.name ?? searches[idx].storeName
            }
        } catch {
            logger.error("Couldn't load the store list: \(error.localizedDescription, privacy: .public)")
        }
    }

    func skuData(for productType: ProductType) async -> SKUData? {
        if let cached = skuDataByProduct[productType] { return cached }
        do {
            let data = try await fulfillmentModel.skuData(for: productType)
            skuDataByProduct[productType] = data
            return data
        } catch {
            logger.error("Couldn't load models for \(productType.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Search management

    func addSearch() {
        // Starts at the selected search's store.
        let template = selectedSearch ?? SearchStore.defaultSearch()
        let search = SavedSearch(productType: .iPhonePro18, storeNumber: template.storeNumber, storeName: template.storeName)
        searches.append(search)
        selectedSearchID = search.id
        SearchStore.save(searches)
        Task { await refreshSearch(id: search.id) }
    }

    func deleteSearch(id: UUID) {
        searches.removeAll { $0.id == id }
        // A fetch still in flight for it drops its results (see fetch).
        results[id] = nil
        lastUpdated[id] = nil
        searchErrors[id] = nil
        lastNotifiedPreferredKeys[id] = nil
        // Deleting from the sidebar menu can target an unselected search;
        // only move the selection when the selected one went away.
        if searches.contains(where: { $0.id == selectedSearchID }) == false {
            selectedSearchID = searches.first?.id
        }
        if searches.isEmpty {
            // Never leave the app with zero searches.
            searches = [SearchStore.defaultSearch()]
            selectedSearchID = searches.first?.id
        }
        SearchStore.save(searches)
    }

    func updateSelected(_ mutate: (inout SavedSearch) -> Void) {
        guard let id = selectedSearch?.id, let idx = searches.firstIndex(where: { $0.id == id }) else { return }
        mutate(&searches[idx])
        searches[idx].storeName = stores.first(where: { $0.storeNumber == searches[idx].storeNumber })?.name ?? searches[idx].storeName
        SearchStore.save(searches)
    }

    // MARK: - Fetching

    /// Called on every main-window appearance; only the first one starts
    /// monitoring (a sweep now, then auto-refresh). Monitoring then runs
    /// for the life of the app: closing the window doesn't stop it, and
    /// reopening one doesn't start a second schedule.
    func startMonitoring() async {
        guard isMonitoring == false else { return }
        isMonitoring = true
        await fetchAllSearches()
    }

    func fetchSelected() async {
        guard let search = selectedSearch else { return }
        await refreshSearch(id: search.id)
    }

    /// Manual refresh of one search (toolbar, Retry, sidebar menu). Like
    /// any manual refresh, it reschedules auto-refresh.
    func refreshSearch(id: UUID) async {
        guard let search = searches.first(where: { $0.id == id }) else { return }
        if let statusCode = await fetch(search: search) {
            registerThrottle(statusCode: statusCode, searchID: id)
        }
        restartAutoRefresh()
    }

    /// Manual refresh of every search (File menu, first launch).
    func fetchAllSearches() async {
        await sweep()
        restartAutoRefresh()
    }

    /// Runs a sweep, or joins the one already running: manual refreshes
    /// and the auto-refresh loop share it, so only one sweep runs at a
    /// time. It runs in its own task, which nothing cancels.
    private func sweep() async {
        if let sweepTask {
            await sweepTask.value
            return
        }
        let task = Task {
            await fetchAllSequentially()
            sweepTask = nil
        }
        sweepTask = task
        await task.value
    }

    /// Sequential by design (no parallel bursts against Apple's API),
    /// with a small stagger between searches. A throttled response ends
    /// the sweep; a sweep that finishes unthrottled clears the backoff.
    private func fetchAllSequentially() async {
        for (index, id) in searches.map(\.id).enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            // Read it now: searches can be edited or deleted mid-sweep.
            guard let search = searches.first(where: { $0.id == id }) else { continue }
            if let statusCode = await fetch(search: search) {
                registerThrottle(statusCode: statusCode, searchID: id)
                return
            }
        }
        throttleFailureCount = 0
        throttledUntil = nil
    }

    // MARK: - Auto-refresh scheduler

    /// (Re)starts the Task.sleep-based scheduler. Idempotent: any
    /// previous loop is cancelled first, so settings changes and manual
    /// refreshes never stack timers; a sweep already running carries on.
    /// Changing the interval or turning it Off takes effect immediately,
    /// without relaunch.
    func restartAutoRefresh(withMinutes minutes: Int? = nil) {
        if let minutes {
            autoRefreshIntervalMinutes = Self.allowedIntervals.contains(minutes) ? minutes : 5
            UserDefaults.standard.set(autoRefreshIntervalMinutes, forKey: "preferredUpdateInterval")
        }

        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        nextAutoRefreshAt = nil

        guard autoRefreshIntervalMinutes > 0 else { return }

        autoRefreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                guard let self else { return }
                let delay = self.currentAutoRefreshDelay()
                self.nextAutoRefreshAt = Date().addingTimeInterval(delay)
                logger.debug("Next auto-refresh in \(Int(delay))s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                await self.sweep()
            }
        }
    }

    /// Re-reads Pushover config after Settings edits.
    func refreshPushoverState() {
        pushoverEnabled = PushoverSettings.isEnabled
        pushoverConfigured = PushoverSettings.isConfigured
    }

    func setPushoverEnabled(_ enabled: Bool) {
        PushoverSettings.isEnabled = enabled
        refreshPushoverState()
    }

    /// Real test push from Settings. Honest success/failure feedback.
    func sendTestPushover() async {
        do {
            try await PushoverClient.send(
                title: "ReadyForPickup test",
                message: "This is a test notification from ReadyForPickup on your Mac. Pushover is configured correctly.")
            pushoverFeedback = "Test sent - check Pushover on your phone."
        } catch {
            pushoverFeedback = error.localizedDescription
        }
        refreshPushoverState()
    }

    /// The refresh interval, or longer while Apple is throttling.
    private func currentAutoRefreshDelay() -> TimeInterval {
        var delay = TimeInterval(autoRefreshIntervalMinutes * 60)
        if let throttledUntil {
            delay = max(delay, throttledUntil.timeIntervalSinceNow)
        }
        return delay
    }

    /// Counts one throttled cycle (a sweep, or a single-search refresh)
    /// and holds auto-refresh back until `throttledUntil`: the interval
    /// (5 min when auto-refresh is Off) doubles per consecutive
    /// throttled cycle, capped at 60 min.
    private func registerThrottle(statusCode: Int, searchID: UUID) {
        throttleFailureCount += 1
        let base = TimeInterval(max(autoRefreshIntervalMinutes, 5) * 60)
        let backoff = min(3600, base * pow(2.0, Double(min(throttleFailureCount, 4))))
        let retryAt = Date().addingTimeInterval(backoff)
        throttledUntil = retryAt

        guard searches.contains(where: { $0.id == searchID }) else { return }
        let mins = Int((backoff / 60).rounded(.up))
        let time = retryAt.formatted(date: .omitted, time: .shortened)
        searchErrors[searchID] = autoRefreshIntervalMinutes > 0
            ? "Apple is throttling requests (HTTP \(statusCode)); retrying in ~\(mins) min (next retry at \(time))."
            : "Apple is throttling requests (HTTP \(statusCode)). Auto-refresh is off: wait ~\(mins) min (until \(time)) before refreshing."
    }

    /// Fetches one search and shows its results or error. Returns the
    /// HTTP status code when Apple throttled the request, for the caller
    /// to count once per cycle (registerThrottle).
    private func fetch(search: SavedSearch) async -> Int? {
        fetchesInFlight[search.id, default: 0] += 1
        defer {
            let remaining = (fetchesInFlight[search.id] ?? 1) - 1
            fetchesInFlight[search.id] = remaining > 0 ? remaining : nil
        }
        do {
            let parts = try await fulfillmentModel.fetchInventory(for: search)
            guard let current = currentVersion(of: search) else { return nil }
            results[search.id] = parts
            lastUpdated[search.id] = Date()
            searchErrors[search.id] = nil
            notifyIfNeeded(search: current, parts: parts)
            return nil
        } catch {
            // URLSession throws URLError(.cancelled) when the calling task
            // is cancelled; a cancelled fetch is not a failure.
            if Task.isCancelled { return nil }
            logger.error("Fetch failed for \(search.productTypeRaw, privacy: .public) at \(search.storeNumber, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if case AppError.throttled(let statusCode) = error { return statusCode }
            if currentVersion(of: search) != nil {
                searchErrors[search.id] = error.localizedDescription
            }
            return nil
        }
    }

    /// The search as it is now, or nil if it was deleted, or pointed at
    /// other inventory, while `search` was being fetched (that edit
    /// started a fetch of its own).
    private func currentVersion(of search: SavedSearch) -> SavedSearch? {
        guard let current = searches.first(where: { $0.id == search.id }),
              current.requestsSameInventory(as: search) else { return nil }
        return current
    }

    private func notifyIfNeeded(search: SavedSearch, parts: [(FulfillmentStore, [PartAvailability])]) {
        // Dedup FIRST (shared by both channels): only notify for
        // preferred models that were NOT available at this store on
        // the previous fetch. Unchanged auto-refresh cycles send
        // nothing on either channel; a model that disappears and
        // returns will notify again.
        func key(_ store: FulfillmentStore, _ part: PartAvailability) -> String {
            "\(store.storeNumber)|\(part.partNumber)"
        }
        let currentKeys = Set(parts.flatMap { store, ps in ps.filter { search.isPreferred($0) }.map { key(store, $0) } })
        let previousKeys = lastNotifiedPreferredKeys[search.id] ?? []
        let newKeys = currentKeys.subtracting(previousKeys)
        lastNotifiedPreferredKeys[search.id] = currentKeys

        guard newKeys.isEmpty == false else { return }

        let newParts: [(FulfillmentStore, [PartAvailability])] = parts.compactMap { store, ps in
            let fresh = ps.filter { newKeys.contains(key(store, $0)) }
            return fresh.isEmpty ? nil : (store, fresh)
        }

        // Not gated on skuDataByProduct: that cache only holds product
        // types opened in the UI, and part names are already resolved.
        if search.notifyOnThisMac {
            Task {
                await NotificationSender().sendNotificationIfNeeded(availableParts: newParts, search: search)
            }
        }

        // Pushover: per-search toggle + app-wide enable/keys. Single
        // attempt per new-availability event, never a retry loop;
        // failures are logged and surfaced, never crash the refresh.
        if search.notifyViaPushover, PushoverSettings.isConfigured {
            let alert = PushoverClient.stockMessage(for: search, parts: newParts)
            Task {
                do {
                    try await PushoverClient.send(title: alert.title, message: alert.message)
                    logger.info("Pushover alert sent for \(search.productTypeRaw, privacy: .public)")
                } catch {
                    logger.error("Pushover send failed: \(error.localizedDescription, privacy: .public)")
                    self.pushoverFeedback = "Pushover send failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
