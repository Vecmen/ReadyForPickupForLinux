//
//  ModelLoader.swift
//  InventoryWatch
//
//  Created by Worth Baker on 10/25/22.
//

import Foundation

actor SKUDataLoader {

    var defaultsManager = DefaultsVendor()

    private var cachediPhoneData: [Country: AllPhoneModels] = [:]

    var skuDataForPreferredProduct: SKUData {
        get async throws {
            return try await skuData(for: defaultsManager.preferredProductType, and: defaultsManager.preferredCountry)
        }
    }

    func skuData(for productType: ProductType, and country: Country) async throws -> SKUData {
        switch productType {
        case .MacBookNeo:
            return MacBookNeoDataForCountry(country)
        case .M5MacBookAir13:
            return M5MacBookAir13DataForCountry(country)
        case .M5MacBookAir15:
            return M5MacBookAir15DataForCountry(country)
        case .MacBookPro14:
            return MacBookPro14DataForCountry(country)
        case .MacBookPro16:
            return MacBookPro16DataForCountry(country)
        case .iMac:
            return iMacDataForCountry(country)
        case .MacMini:
            return MacMiniDataForCountry(country)
        case .MacStudio:
            return MacStudioDataForCountry(country)

        case .iPhone16:
            return try phoneModels(for: country).toSkuData(\.iphone16)
        case .iPhone17:
            return try phoneModels(for: country).toSkuData(\.iphone17)
        case .iPhone17e:
            return try phoneModels(for: country).toSkuData(\.iphone17e)
        case .iPhoneAir:
            return try phoneModels(for: country).toSkuData(\.iphoneAir)
        case .iPhoneDuo:
            return try phoneModels(for: country).toSkuData(\.iphoneDuo)
        case .iPhonePro18:
            return try phoneModels(for: country).toSkuData(\.pro18)
        case .iPhoneProMax18:
            return try phoneModels(for: country).toSkuData(\.proMax18)
        }
    }

    // MARK: - Current iPhones (iPhoneModelsCurrent-intl.json, US-verified)

    private func generateiPhoneModelsByCountry() throws -> [Country: AllPhoneModels] {
        if cachediPhoneData.isEmpty == false {
            return cachediPhoneData
        }

        let phoneModelsJson = try loadIPhoneModels()
        var rv = [Country: AllPhoneModels]()

        let mapping: [(String, WritableKeyPath<AllPhoneModels, [AllPhoneModels.PhoneModel]>)] = [
            ("iphone16", \AllPhoneModels.iphone16),
            ("iphone17", \AllPhoneModels.iphone17),
            ("iphone17e", \AllPhoneModels.iphone17e),
            ("iphoneAir", \AllPhoneModels.iphoneAir),
            ("iphoneDuo", \AllPhoneModels.iphoneDuo),
            ("pro18", \AllPhoneModels.pro18),
            ("proMax18", \AllPhoneModels.proMax18)
        ]

        for (countryCode, phones) in phoneModelsJson {
            guard let country = Countries[countryCode.uppercased()] else {
                throw AppError.invalidLocalModelStore
            }

            var phoneModels = AllPhoneModels()
            for (key, keyPath) in mapping {
                guard let models = phones[key] else { continue }
                phoneModels[keyPath: keyPath] = models.map {
                    AllPhoneModels.PhoneModel(sku: $0.key, productName: $0.value)
                }
            }
            rv[country] = phoneModels
        }

        cachediPhoneData = rv
        return rv
    }

    private func phoneModels(for country: Country) throws -> AllPhoneModels {
        let iPhoneModels = try generateiPhoneModelsByCountry()

        guard let models = iPhoneModels[country] else {
            throw AppError.invalidLocalModelStore
        }

        return models
    }

    // country: type: model: description
    private func loadIPhoneModels() throws -> [String: [String: [String: String]]] {
        if let path = Bundle.main.path(forResource: "iPhoneModelsCurrent-intl", ofType: "json") {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode([String: [String: [String: String]]].self, from: data)
        } else {
            throw AppError.invalidProjectState
        }
    }
}
