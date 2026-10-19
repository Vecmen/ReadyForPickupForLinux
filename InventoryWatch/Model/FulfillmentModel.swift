//
//  FulfillmentModel.swift
//  InventoryWatch
//
//  Created by Worth Baker on 10/25/22.
//

import Foundation

actor FulfillmentModel {

    let defaultsVendor = DefaultsVendor()
    let skuDataLoader = SKUDataLoader()

    var skuDataForPreferredProduct: SKUData {
        get async throws {
            return try await skuDataLoader.skuDataForPreferredProduct
        }
    }

    func skuData(for search: SavedSearch) async throws -> SKUData {
        try await skuDataLoader.skuData(for: search.productType, and: defaultsVendor.preferredCountry)
    }

    func skuData(for productType: ProductType) async throws -> SKUData {
        try await skuDataLoader.skuData(for: productType, and: defaultsVendor.preferredCountry)
    }

    private var cachedStoreData: [String: StoreCountry] = [:]

    func loadStoresByCountry() async throws -> [String: StoreCountry] {
        if cachedStoreData.isEmpty == false {
            return cachedStoreData
        }

        let decoder = JSONDecoder()

        do {
            // Remote store list currently returns HTTP 404 (live
            // 2026-10-18); this throws and falls back to local data.
            let url = URL(string: "https://www.apple.com/rsp-web/store-list?locale=en_US")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let jsonStores = try decoder.decode(StoreBootstrap.self, from: data)

            cachedStoreData = jsonStores.countryData
            return jsonStores.countryData
        } catch {
            print(error)
        }

        // If remote stores failed to load, fallback to local bootstrap.
        // Cache it too, or every fetch re-requests the failing remote list.
        if let path = Bundle.main.path(forResource: "Stores_LocalBootstrap", ofType: "json") {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let jsonStores = try decoder.decode(StoreBootstrap.self, from: data)
                cachedStoreData = jsonStores.countryData
                return jsonStores.countryData
            } catch {
                print(error)
                throw error
            }
        } else {
            throw AppError.invalidProjectState
        }
    }

    func storesForPreferredCountry() async throws -> [RetailStore] {
        let byCountry = try await loadStoresByCountry()
        guard let stores = byCountry[defaultsVendor.preferredCountry.locale]?.stores else {
            throw AppError.invalidProjectState
        }
        return stores
    }

    /// Legacy single-search entry point (kept for compatibility).
    func fetchInventory() async throws -> [(FulfillmentStore, [PartAvailability])] {
        try await fetchInventory(for: SearchStore.migrateLegacyPreferences()[0])
    }

    /// Fetches inventory for one saved search against Apple's current
    /// pickup endpoint. Requests are chunked at 20 parts (Apple's cap)
    /// and merged by store.
    func fetchInventory(for search: SavedSearch) async throws -> [(FulfillmentStore, [PartAvailability])] {
        let skuData = try await skuData(for: search)

        var allSkus = skuData.orderedSKUs
        if let custom = search.customSkuData, allSkus.contains(custom.sku) == false {
            allSkus.append(custom.sku)
        }

        let location = try await pickupLocation(storeNumber: search.storeNumber)
        let filter: Set<String>? = search.onlyPreferred
            ? Set(search.preferredSKUs).union(search.customSkuData.map { [$0.sku] } ?? [])
            : nil

        var merged: [String: FulfillmentStore] = [:]
        var order: [String] = []
        for chunkStart in stride(from: 0, to: allSkus.count, by: 20) {
            let chunk = Array(allSkus[chunkStart..<min(chunkStart + 20, allSkus.count)])
            let stores = try await fetchChunk(skus: chunk, location: location, skuData: skuData, search: search)
            for store in stores {
                if let existing = merged[store.storeNumber] {
                    let parts = existing.partsAvailability + store.partsAvailability.filter { new in
                        existing.partsAvailability.contains(where: { $0.partNumber == new.partNumber }) == false
                    }
                    merged[store.storeNumber] = FulfillmentStore(storeName: existing.storeName, storeNumber: existing.storeNumber, city: existing.city, state: existing.state, partsAvailability: parts)
                } else {
                    merged[store.storeNumber] = store
                    order.append(store.storeNumber)
                }
            }
        }

        let collected = order.compactMap { merged[$0] }
        return parseAvailableModels(from: collected, filterForModels: filter, search: search)
    }

    private func fetchChunk(skus: [String], location: String, skuData: SKUData, search: SavedSearch) async throws -> [FulfillmentStore] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.apple.com"
        components.path = "/\(defaultsVendor.countryPathElement.lowercased())shop/retail/pickup-message"
        var items: [URLQueryItem] = [URLQueryItem(name: "pl", value: "true"), URLQueryItem(name: "location", value: location)]
        for (i, sku) in skus.enumerated() where sku.isEmpty == false {
            items.append(URLQueryItem(name: "parts.\(i)", value: sku))
        }
        components.queryItems = items

        guard let url = components.url else { throw AppError.couldNotGenerateURL }
        var request = URLRequest(url: url)
        request.addValue("https://www.apple.com/shop/buy-iphone/", forHTTPHeaderField: "Referer")
        print(url.absoluteString)

        let (data, response) = try await URLSession.shared.data(for: request)
        return try parseStoreResponse(data, response: response as? HTTPURLResponse, skuData: skuData, search: search)
    }

    func getDefaultStoreForCurrentCountry() async throws -> RetailStore? {
        let stores = try await storesForPreferredCountry()
        let defaultStoreNumber: String
        switch defaultsVendor.preferredCountry.locale {
        case "en_US": defaultStoreNumber = "R032"
        case "fr_FR": defaultStoreNumber = "R277"
        case "en_CA": defaultStoreNumber = "R121"
        case "en_AU": defaultStoreNumber = "R238"
        case "de_DE": defaultStoreNumber = "R443"
        case "en_GB": defaultStoreNumber = "R092"
        default: return stores.first
        }
        return stores.first(where: { $0.storeNumber == defaultStoreNumber }) ?? stores.first
    }

    /// pickup-message takes a city / postal-code `location`, not an
    /// R### store number. Resolve it from the store list.
    private func pickupLocation(storeNumber: String) async throws -> String {
        if let stores = try? await storesForPreferredCountry(),
           let store = stores.first(where: { $0.storeNumber == storeNumber }) {
            if let postal = store.address.postalCode, postal.isEmpty == false { return postal }
            return store.address.cityStateDisplay
        }
        return storeNumber
    }

    private func parseStoreResponse(_ responseData: Data?, response: HTTPURLResponse?, skuData: SKUData, search: SavedSearch) throws -> [FulfillmentStore] {
        guard let responseData = responseData else {
            throw errorForStatusCode(response?.statusCode) ?? AppError.invalidStoreResponse
        }
        if let code = response?.statusCode, code >= 400 {
            // 541 is Apple's anti-bot/rate-limit page, 429 is standard.
            if code == 429 || code == 541 { throw AppError.throttled(code) }
            throw errorForStatusCode(code) ?? AppError.invalidStoreResponse
        }
        guard let json = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any],
              let body = json["body"] as? [String: Any] else {
            throw AppError.unexpectedJSONStructure
        }

        // Current shape: body.stores[]. Legacy: body.content.pickupMessage.stores[].
        // No stores + errorMessage (e.g. "Product(s) Invalid or not
        // buyable" for a retired product) -> honest no-stores error.
        let storeList: [[String: Any]]
        if let stores = body["stores"] as? [[String: Any]] {
            storeList = stores
        } else if let content = body["content"] as? [String: Any],
                  let pickupMessage = content["pickupMessage"] as? [String: Any],
                  let stores = pickupMessage["stores"] as? [[String: Any]] {
            storeList = stores
        } else {
            throw AppError.noStoresFound
        }

        return storeList.compactMap { storeJSON in
            guard let name = storeJSON["storeName"] as? String,
                  let number = storeJSON["storeNumber"] as? String,
                  let city = storeJSON["city"] as? String else { return nil }
            let state = storeJSON["state"] as? String
            guard let partsAvailability = storeJSON["partsAvailability"] as? [String: [String: Any]] else { return nil }

            let parsedParts: [PartAvailability] = partsAvailability.values.compactMap { part in
                guard let partNumber = part["partNumber"] as? String,
                      let availabilityString = part["pickupDisplay"] as? String,
                      // "default" = pre-order / check-back: not in stock.
                      let availability = PartAvailability.PickupAvailability(rawValue: availabilityString == "default" ? "unavailable" : availabilityString)
                else { return nil }

                let productName: String
                if let name = skuData.productName(forSKU: partNumber) {
                    productName = name
                } else if let custom = search.customSkuData, partNumber == custom.sku {
                    productName = custom.nickname
                } else {
                    productName = partNumber
                }
                return PartAvailability(partNumber: partNumber, partName: productName, availability: availability)
            }
            return FulfillmentStore(storeName: name, storeNumber: number, city: city, state: state, partsAvailability: parsedParts)
        }
    }

    private func parseAvailableModels(from stores: [FulfillmentStore], filterForModels: Set<String>?, search: SavedSearch) -> [(FulfillmentStore, [PartAvailability])] {
        let scoped = search.includeNearby ? stores : stores.filter { $0.storeNumber == search.storeNumber }
        return scoped
            .sorted(by: { first, _ in first.storeNumber == search.storeNumber })
            .compactMap { store in
                let rv = store.partsAvailability.filter { part in
                    guard part.availability == .available else { return false }
                    if let filter = filterForModels, filter.contains(part.partNumber) == false { return false }
                    return true
                }
                return rv.isEmpty ? nil : (store, rv)
            }
    }

    private func errorForStatusCode(_ statusCode: Int?) -> AppError? {
        guard let statusCode else { return nil }
        switch statusCode {
        case 429, 541: return .throttled(statusCode)
        case 500...599: return .storeUnavailable
        default: return nil
        }
    }
}
