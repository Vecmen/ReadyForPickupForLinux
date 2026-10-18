//
//  SavedSearch.swift
//  InventoryWatch
//

import Foundation

/// One saved search in the 2.0-style UI: a product at a store, with its
/// own preferred models, nearby-store preference, custom SKU and
/// local-notification preference. Multiple searches are persisted as
/// Codable JSON in UserDefaults (key "savedSearches").
struct SavedSearch: Codable, Identifiable, Equatable {
    var id: UUID
    var productTypeRaw: String
    var storeNumber: String
    var storeName: String?
    var includeNearby: Bool
    var preferredSKUs: [String]
    var onlyPreferred: Bool
    var notifyOnThisMac: Bool
    var customSku: String
    var customSkuNickname: String

    init(id: UUID = UUID(),
         productType: ProductType,
         storeNumber: String,
         storeName: String? = nil,
         includeNearby: Bool = true,
         preferredSKUs: [String] = [],
         onlyPreferred: Bool = false,
         notifyOnThisMac: Bool = true,
         customSku: String = "",
         customSkuNickname: String = "") {
        self.id = id
        self.productTypeRaw = productType.rawValue
        self.storeNumber = storeNumber
        self.storeName = storeName
        self.includeNearby = includeNearby
        self.preferredSKUs = preferredSKUs
        self.onlyPreferred = onlyPreferred
        self.notifyOnThisMac = notifyOnThisMac
        self.customSku = customSku
        self.customSkuNickname = customSkuNickname
    }

    /// Falls back to a current product if the saved type was retired.
    var productType: ProductType {
        get { ProductType(rawValue: productTypeRaw) ?? .iPhonePro18 }
        set { productTypeRaw = newValue.rawValue }
    }

    var customSkuData: (sku: String, nickname: String)? {
        let sku = customSku.trimmingCharacters(in: .whitespaces)
        guard sku.isEmpty == false else { return nil }
        let name = customSkuNickname.trimmingCharacters(in: .whitespaces)
        return (sku, name.isEmpty ? sku : name)
    }

    func isPreferred(_ part: PartAvailability) -> Bool {
        preferredSKUs.contains(part.partNumber) || customSkuData?.sku == part.partNumber
    }
}

/// UserDefaults-backed store for saved searches, with one-time
/// migration of the legacy single-search preferences.
enum SearchStore {
    private static let key = "savedSearches"

    static func load() -> [SavedSearch] {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SavedSearch].self, from: data),
           decoded.isEmpty == false {
            return decoded
        }
        let migrated = migrateLegacyPreferences()
        save(migrated)
        return migrated
    }

    static func save(_ searches: [SavedSearch]) {
        if let data = try? JSONEncoder().encode(searches) {
            UserDefaults.standard.set(data, forKey: key)
        }
        // Mirror the first search into the legacy keys so the older
        // DefaultsVendor-based code paths keep seeing a sane value.
        if let first = searches.first {
            UserDefaults.standard.set(first.productTypeRaw, forKey: "preferredProductType")
            UserDefaults.standard.set(first.storeNumber, forKey: "preferredStoreNumber")
            UserDefaults.standard.set(first.preferredSKUs.joined(separator: ","), forKey: "preferredSKUs")
            UserDefaults.standard.set(first.includeNearby, forKey: "shouldIncludeNearbyStores")
            UserDefaults.standard.set(first.onlyPreferred, forKey: "showResultsOnlyForPreferredModels")
        }
    }

    /// Builds the first saved search from the pre-2.0 single-search
    /// UserDefaults keys, so an existing setup is not lost.
    static func migrateLegacyPreferences() -> [SavedSearch] {
        let defaults = DefaultsVendor()
        var search = SavedSearch(
            productType: defaults.preferredProductType,
            storeNumber: defaults.preferredStoreNumber,
            includeNearby: defaults.shouldIncludeNearbyStores,
            preferredSKUs: Array(defaults.preferredSKUs).sorted(),
            onlyPreferred: defaults.showResultsOnlyForPreferredModels,
            notifyOnThisMac: true
        )
        if let custom = defaults.customSkuData {
            search.customSku = custom.sku
            search.customSkuNickname = custom.nickname
        }
        return [search]
    }
}
