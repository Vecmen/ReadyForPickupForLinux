//
//  DefaultsVendor.swift
//  InventoryWatch
//
//  Created by Worth Baker on 10/25/22.
//

import Foundation
import Combine

extension UserDefaults {
    
    @objc dynamic var preferredStoreNumber: String {
        get { string(forKey: "preferredStoreNumber") ?? "R032" }
        set { setValue(newValue, forKey: "preferredStoreNumber") }
    }
    
    @objc dynamic var lastUpdateDate: String? {
        get { string(forKey: "lastUpdateDate") }
        set { setValue(newValue, forKey: "lastUpdateDate") }
    }
    
    @objc dynamic var preferredUpdateInterval: Int {
        get {
            if let currentValue = object(forKey: "preferredUpdateInterval") as? Int {
                return currentValue
            } else {
                // WB 10/28/22: Changing default update interval from 1min to 5min
                let presetValue = 5
                set(presetValue, forKey: "preferredUpdateInterval")
                
                return presetValue
            }
        }
        set { setValue(newValue, forKey: "preferredUpdateInterval") }
    }
}

struct DefaultsVendor {
    
    var preferredCountry: Country {
        let value = UserDefaults.standard.string(forKey: "preferredCountry") ?? "US"
        
        return Countries[value] ?? USData
    }
    
    var preferredProductType: ProductType {
        let value = UserDefaults.standard.string(forKey: "preferredProductType") ?? "iPhonePro18"

        if let product = ProductType(rawValue: value) {
            return product
        }

        // Migration: the saved type was removed from the catalog
        // (e.g. "iPhonePro14", "MacBookPro"). Rewrite the preference
        // to a current product so Settings/ContentView pickers (which
        // read the same key) show a valid selection instead of blank.
        // preferredSKUs for the old type are left alone; Settings
        // clears them when the user next changes product type.
        UserDefaults.standard.set(ProductType.iPhonePro18.rawValue, forKey: "preferredProductType")
        return .iPhonePro18
    }
    
    var countryPathElement: String {
        let country = preferredCountry
        if country.shortcode == "US" {
            return ""
        } else {
            return country.shortcode + "/"
        }
    }
    
    var preferredStoreNumber: String {
        get { return UserDefaults.standard.preferredStoreNumber }
        set { UserDefaults.standard.preferredStoreNumber = newValue }
    }
    
    var lastUpdateDate: String? {
        get { return UserDefaults.standard.lastUpdateDate }
        set { UserDefaults.standard.lastUpdateDate = newValue }
    }
    
    // unused - keeping this around as an example implementation
    private var preferredStoreNumberStream: AnyPublisher<String, Never> {
        return UserDefaults.standard
            .publisher(for: \.preferredStoreNumber)
            .eraseToAnyPublisher()
    }
    
    var preferredUpdateInterval: Int {
        return UserDefaults.standard.preferredUpdateInterval
    }
    
    var shouldIncludeNearbyStores: Bool {
        let value = UserDefaults.standard.object(forKey: "shouldIncludeNearbyStores") as? Bool
        
        return value ?? true
    }
    
    var preferredSKUs: Set<String> {
        guard let defaults = UserDefaults.standard.string(forKey: "preferredSKUs") else {
            return []
        }
        
        return defaults.components(separatedBy: ",").reduce(into: Set<String>()) { partialResult, next in
            partialResult.insert(next)
        }
    }
    
    var customSkuData: (sku: String, nickname: String)? {
        guard
            let sku = UserDefaults.standard.string(forKey: "customSku"),
            let name = UserDefaults.standard.string(forKey: "customSkuNickname")
        else {
            return nil
        }
        
        return (sku, name)
    }
    
    var showResultsOnlyForPreferredModels: Bool {
        UserDefaults.standard.bool(forKey: "showResultsOnlyForPreferredModels")
    }
    
    var notifyOnlyForPreferredModels: Bool {
        UserDefaults.standard.bool(forKey: "notifyOnlyForPreferredModels")
    }
}

/// One-time migration from the old bundle ID (com.worthbak.InventoryWatch)
/// to com.wehbs.ReadyForPickup. Changing PRODUCT_BUNDLE_IDENTIFIER changes
/// the UserDefaults domain, so without this, savedSearches and every
/// legacy preference (preferredStoreNumber, preferredSKUs, Pushover
/// enable flag, Sparkle settings, etc.) would appear empty on first launch
/// of the renamed app. Copies only keys missing in the new domain, then
/// records completion. Pushover keys are deliberately not migrated: they
/// live in the old app's Keychain items, and macOS asks for the login
/// password whenever a different app reads those, so users re-enter them.
enum LegacyDataMigration {
    static let legacyBundleIdentifier = "com.worthbak.InventoryWatch"
    private static let migrationKey = "legacyDataMigrationCompletedV1"

    static func migrateIfNeeded() {
        let standard = UserDefaults.standard

        if standard.bool(forKey: migrationKey) == false {
            if let legacy = UserDefaults(suiteName: legacyBundleIdentifier) {
                for (key, value) in legacy.dictionaryRepresentation()
                where standard.object(forKey: key) == nil {
                    standard.set(value, forKey: key)
                }
            }
            standard.set(true, forKey: migrationKey)
            _ = standard.synchronize()
        }
    }
}
