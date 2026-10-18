//
//  AllPhoneModels.swift
//  InventoryWatch
//
//  Created by Worth Baker on 7/27/22.
//

import Foundation

struct AllPhoneModels {
    struct PhoneModel {
        let sku: String
        let productName: String
    }

    var iphone16: [PhoneModel] = []
    var iphone17: [PhoneModel] = []
    var iphone17e: [PhoneModel] = []
    var iphoneAir: [PhoneModel] = []
    var iphoneDuo: [PhoneModel] = []
    var pro18: [PhoneModel] = []
    var proMax18: [PhoneModel] = []

    func toSkuData(_ keypath: KeyPath<AllPhoneModels, [AllPhoneModels.PhoneModel]>) -> SKUData {
        let models = self[keyPath: keypath]

        let lookup: [String: String] = models.reduce(into: [:]) { acc, next in
            acc[next.sku] = next.productName
        }

        return SKUData(orderedSKUs: models.map { $0.sku }, lookup: lookup)
    }
}
