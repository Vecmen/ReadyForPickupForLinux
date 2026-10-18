//
//  ViewModel.swift
//  InventoryWatch
//
//  Created by Worth Baker on 10/25/22.
//

import Foundation

@MainActor
final class ViewModel: ObservableObject {

    private let fulfillmentModel = FulfillmentModel()
    private var defaultsVendor = DefaultsVendor()

    @Published var searches: [SavedSearch] = []
    @Published var selectedSearchID: UUID?
    @Published var results: [UUID: [(FulfillmentStore, [PartAvailability])]] = [:]
    @Published var lastUpdated: [UUID: Date] = [:]
    @Published var searchErrors: [UUID: String] = [:]
    @Published var isLoading = false
    @Published var stores: [RetailStore] = []
    @Published var skuDataByProduct: [ProductType: SKUData] = [:]

    // Auto-refresh (minutes; 0 = Off). Backed by legacy
    // `preferredUpdateInterval`; only 0/5/10/15/30 are honoured -
    // any other stored legacy value (e.g. 1) is coerced to 5.
    @Published var autoRefreshIntervalMinutes: Int = 5
    @Published var nextAutoRefreshAt: Date?
    @Published var throttledUntil: Date?

    private var autoRefreshTask: Task<Void, Never>?
    private var throttleFailureCount = 0
    private var lastNotifiedPreferredKeys: [UUID: Set<String>] = [:]

    // Legacy published state kept for the app scene / commands.
    @Published var availableParts: [(FulfillmentStore, [PartAvailability])] = []
    @Published var errorState: AppError?
    @Published var hasLatestVersion = true
    @Published var preferredStoreName: String? = nil

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
        get { searches.first(where: { $0.id == selectedSearchID }) ?? searches.first }
        set {
            guard let newValue, let idx = searches.firstIndex(where: { $0.id == newValue.id }) else { return }
            searches[idx] = newValue
            SearchStore.save(searches)
        }
    }

    func storeName(for search: SavedSearch) -> String {
        stores.first(where: { $0.storeNumber == search.storeNumber })?.name
            ?? search.storeName ?? search.storeNumber
    }

    func availableCount(for search: SavedSearch) -> Int {
        (results[search.id] ?? []).reduce(0) { $0 + $1.1.count }
    }

    func preferredCount(for search: SavedSearch) -> Int {
        (results[search.id] ?? []).reduce(0) { acc, next in
            acc + next.1.filter { search.isPreferred($0) }.count
        }
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
            print(error)
        }
    }

    func skuData(for productType: ProductType) async -> SKUData? {
        if let cached = skuDataByProduct[productType] { return cached }
        do {
            let data = try await fulfillmentModel.skuData(for: productType)
            skuDataByProduct[productType] = data
            return data
        } catch {
            print(error)
            return nil
        }
    }

    var storesForCurrentCountry: [RetailStore] {
        get async {
            await loadStores()
            return stores
        }
    }

    // MARK: - Search management

    func addSearch() {
        let product: ProductType = .iPhonePro18
        let store = stores.first(where: { $0.storeNumber == defaultsVendor.preferredStoreNumber }) ?? stores.first
        let search = SavedSearch(productType: product, storeNumber: store?.storeNumber ?? "R032", storeName: store?.name)
        searches.append(search)
        selectedSearchID = search.id
        SearchStore.save(searches)
        Task { await fetch(search: search) }
    }

    func deleteSelectedSearch() {
        guard let id = selectedSearch?.id else { return }
        searches.removeAll { $0.id == id }
        results[id] = nil
        selectedSearchID = searches.first?.id
        if searches.isEmpty {
            // Never leave the app with zero searches.
            searches = [SavedSearch(productType: .iPhonePro18, storeNumber: "R032", storeName: "SoHo")]
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

    func fetchSelected() async {
        guard let search = selectedSearch else { return }
        await fetch(search: search)
        restartAutoRefresh()
    }

    func fetchAllSearches() async {
        await fetchAllSequentially()
        restartAutoRefresh()
    }

    /// Sequential by design (no parallel bursts against Apple's API),
    /// with a small stagger between searches.
    private func fetchAllSequentially() async {
        for (index, search) in searches.enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await fetch(search: search)
        }
    }

    /// Cmd-R / legacy entry point.
    func fetchLatestInventory() async {
        await fetchAllSearches()
    }

    // MARK: - Auto-refresh scheduler

    /// (Re)starts the Task.sleep-based scheduler. Idempotent: any
    /// previous loop is cancelled first, so view re-appearances and
    /// settings changes never stack timers. Changing the interval or
    /// turning it Off takes effect immediately, without relaunch.
    func restartAutoRefresh(withMinutes minutes: Int? = nil) {
        if let minutes {
            autoRefreshIntervalMinutes = Self.allowedIntervals.contains(minutes) ? minutes : 5
            UserDefaults.standard.set(autoRefreshIntervalMinutes, forKey: "preferredUpdateInterval")
        }

        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        nextAutoRefreshAt = nil

        guard autoRefreshIntervalMinutes > 0 else {
            print("[AutoRefresh] off")
            return
        }

        autoRefreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                guard let self else { return }
                let delay = await self.currentAutoRefreshDelay()
                let next = Date().addingTimeInterval(delay)
                await MainActor.run { self.nextAutoRefreshAt = next }
                print("[AutoRefresh] next refresh in \(Int(delay))s at \(next)")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                await self.fetchAllSequentially()
            }
        }
        print("[AutoRefresh] started, every \(autoRefreshIntervalMinutes) min")
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        nextAutoRefreshAt = nil
    }

    /// Base interval, extended by exponential throttle backoff
    /// (x2 per consecutive throttled cycle, capped at 60 min).
    private func currentAutoRefreshDelay() -> TimeInterval {
        let base = TimeInterval(autoRefreshIntervalMinutes * 60)
        var delay = base
        if throttleFailureCount > 0 {
            delay = min(3600, base * pow(2.0, Double(min(throttleFailureCount, 4))))
        }
        if let throttledUntil, throttledUntil > Date() {
            delay = max(delay, throttledUntil.timeIntervalSinceNow)
        }
        return delay
    }

    func fetch(search: SavedSearch) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let parts = try await fulfillmentModel.fetchInventory(for: search)
            results[search.id] = parts
            lastUpdated[search.id] = Date()
            searchErrors[search.id] = nil
            if search.id == selectedSearch?.id {
                availableParts = parts
                errorState = nil
            }
            throttleFailureCount = 0
            throttledUntil = nil
            notifyIfNeeded(search: search, parts: parts)
        } catch {
            let message: String
            if case AppError.throttled(let statusCode) = error {
                throttleFailureCount += 1
                let backoff = min(3600, TimeInterval(autoRefreshIntervalMinutes * 60) * pow(2.0, Double(min(throttleFailureCount, 4))))
                let retryAt = Date().addingTimeInterval(backoff)
                throttledUntil = retryAt
                let mins = Int((backoff / 60).rounded(.up))
                message = "Apple is throttling requests (HTTP \(statusCode)); retrying in ~\(mins) min (next retry at \(retryAt.formatted(date: .omitted, time: .shortened)))."
            } else {
                message = (error as? AppError)?.errorMessage ?? error.localizedDescription
            }
            searchErrors[search.id] = message
            if search.id == selectedSearch?.id {
                errorState = error as? AppError ?? .generic(error)
            }
            print(error)
        }
    }

    private func notifyIfNeeded(search: SavedSearch, parts: [(FulfillmentStore, [PartAvailability])]) {
        guard search.notifyOnThisMac else { return }

        // Dedup: only notify for preferred models that were NOT
        // available at this store on the previous fetch. Unchanged
        // auto-refresh cycles send nothing; a model that disappears
        // and returns will notify again.
        func key(_ store: FulfillmentStore, _ part: PartAvailability) -> String {
            "\(store.storeNumber)|\(part.partNumber)"
        }
        let currentKeys = Set(parts.flatMap { store, ps in ps.filter { search.isPreferred($0) }.map { key(store, $0) } })
        let previousKeys = lastNotifiedPreferredKeys[search.id] ?? []
        let newKeys = currentKeys.subtracting(previousKeys)
        lastNotifiedPreferredKeys[search.id] = currentKeys

        guard newKeys.isEmpty == false else { return }
        guard let skuData = skuDataByProduct[search.productType] else { return }

        let newParts: [(FulfillmentStore, [PartAvailability])] = parts.compactMap { store, ps in
            let fresh = ps.filter { newKeys.contains(key(store, $0)) }
            return fresh.isEmpty ? nil : (store, fresh)
        }
        Task {
            await NotificationSender().sendNotificationIfNeeded(availableParts: newParts, skuData: skuData, search: search)
        }
    }

    func clearCurrentAvailableParts() {
        availableParts = []
        if let id = selectedSearch?.id { results[id] = [] }
    }

    func updateStoreName() async {
        await loadStores()
        if let search = selectedSearch {
            preferredStoreName = storeName(for: search)
        }
    }

    func getDefaultStoreForCurrentCountry() async -> RetailStore? {
        try? await fulfillmentModel.getDefaultStoreForCurrentCountry()
    }
}
