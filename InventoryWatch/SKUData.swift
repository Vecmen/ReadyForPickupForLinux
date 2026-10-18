//
//  SKUData.swift
//  InventoryWatch
//
//  Created by Worth Baker on 11/8/21.
//

import Foundation

struct SKUData {
    private let skuLookup: [String: String]
    let orderedSKUs: [String]

    init(orderedSKUs: [String], lookup: [String: String]) {
        self.orderedSKUs = orderedSKUs
        self.skuLookup = lookup
    }

    func productName(forSKU sku: String) -> String? {
        return skuLookup[sku]
    }
}

// Mac SKU data: EVERY standard/retail configuration Apple lists on the
// US buy pages (product-selection configs), verified 2026-10-18 both on
// the buy-page config page (schema.org offers.sku / partNumber, with the
// full chip/RAM/storage spec in the config URL & details text) and via
// the live pickup-message API (real storePickupProductTitle for every
// SKU; 61 available / 30 ineligible at the first returned NY store).
// Display names are built from that buy-page spec text - RAM/storage
// are tied to the exact part number by Apple's own config page.
// Build-to-order combos beyond these standard configs (configurator
// memory/storage ranges) expose no part number on the buy pages and
// are NOT included - they have no store-pickup SKU to watch.
// Non-US suffixes follow the historic Mac pattern
// (<base><country.skuCode>/A) and are NOT verified (US is the focus).

func MacBookNeoDataForCountry(_ country: Country) -> SKUData {
    let orderedSkus = [
        "MHFH4\(country.skuCode)/A",
        "MHFD4\(country.skuCode)/A",
        "MHFG4\(country.skuCode)/A",
        "MHFJ4\(country.skuCode)/A",
        "MHFA4\(country.skuCode)/A",
        "MHFF4\(country.skuCode)/A",
        "MHFE4\(country.skuCode)/A",
        "MHFC4\(country.skuCode)/A"
    ]

    let skusToName = [
        "MHFH4\(country.skuCode)/A": "MacBook Neo 13in Blush 256GB",
        "MHFD4\(country.skuCode)/A": "MacBook Neo 13in Citrus 256GB",
        "MHFG4\(country.skuCode)/A": "MacBook Neo 13in Indigo 512GB",
        "MHFJ4\(country.skuCode)/A": "MacBook Neo 13in Blush 512GB",
        "MHFA4\(country.skuCode)/A": "MacBook Neo 13in Silver 256GB",
        "MHFF4\(country.skuCode)/A": "MacBook Neo 13in Indigo 256GB",
        "MHFE4\(country.skuCode)/A": "MacBook Neo 13in Citrus 512GB",
        "MHFC4\(country.skuCode)/A": "MacBook Neo 13in Silver 512GB"
    ]

    return SKUData(orderedSKUs: orderedSkus, lookup: skusToName)
}

func M5MacBookAir13DataForCountry(_ country: Country) -> SKUData {
    let orderedSkus = [
        "MDHC4\(country.skuCode)/A",
        "MGP94\(country.skuCode)/A",
        "MGP74\(country.skuCode)/A",
        "MGP84\(country.skuCode)/A",
        "MDH74\(country.skuCode)/A",
        "MDHF4\(country.skuCode)/A",
        "MDHG4\(country.skuCode)/A",
        "MDHD4\(country.skuCode)/A",
        "MDH94\(country.skuCode)/A",
        "MDHA4\(country.skuCode)/A",
        "MDHJ4\(country.skuCode)/A",
        "MDHE4\(country.skuCode)/A",
        "MDHH4\(country.skuCode)/A",
        "MDHK4\(country.skuCode)/A",
        "MDH84\(country.skuCode)/A"
    ]

    let skusToName = [
        "MDHC4\(country.skuCode)/A": "M5 MacBook Air 13in Starlight 16GB 1TB",
        "MGP94\(country.skuCode)/A": "M5 MacBook Air 13in Sky Blue 24GB 512GB",
        "MGP74\(country.skuCode)/A": "M5 MacBook Air 13in Starlight 24GB 512GB",
        "MGP84\(country.skuCode)/A": "M5 MacBook Air 13in Midnight 24GB 512GB",
        "MDH74\(country.skuCode)/A": "M5 MacBook Air 13in Silver 16GB 512GB",
        "MDHF4\(country.skuCode)/A": "M5 MacBook Air 13in Midnight 16GB 1TB",
        "MDHG4\(country.skuCode)/A": "M5 MacBook Air 13in Midnight 24GB 1TB",
        "MDHD4\(country.skuCode)/A": "M5 MacBook Air 13in Starlight 24GB 1TB",
        "MDH94\(country.skuCode)/A": "M5 MacBook Air 13in Silver 24GB 1TB",
        "MDHA4\(country.skuCode)/A": "M5 MacBook Air 13in Starlight 16GB 512GB",
        "MDHJ4\(country.skuCode)/A": "M5 MacBook Air 13in Sky Blue 16GB 1TB",
        "MDHE4\(country.skuCode)/A": "M5 MacBook Air 13in Midnight 16GB 512GB",
        "MDHH4\(country.skuCode)/A": "M5 MacBook Air 13in Sky Blue 16GB 512GB",
        "MDHK4\(country.skuCode)/A": "M5 MacBook Air 13in Sky Blue 24GB 1TB",
        "MDH84\(country.skuCode)/A": "M5 MacBook Air 13in Silver 16GB 1TB"
    ]

    return SKUData(orderedSKUs: orderedSkus, lookup: skusToName)
}

func M5MacBookAir15DataForCountry(_ country: Country) -> SKUData {
    let orderedSkus = [
        "MGPC4\(country.skuCode)/A",
        "MDVF4\(country.skuCode)/A",
        "MDVK4\(country.skuCode)/A",
        "MDVE4\(country.skuCode)/A",
        "MGPD4\(country.skuCode)/A",
        "MDV94\(country.skuCode)/A",
        "MDVD4\(country.skuCode)/A",
        "MDVN4\(country.skuCode)/A",
        "MDVH4\(country.skuCode)/A",
        "MDVU4\(country.skuCode)/A",
        "MDVT4\(country.skuCode)/A",
        "MDVA4\(country.skuCode)/A",
        "MDVC4\(country.skuCode)/A",
        "MGPE4\(country.skuCode)/A",
        "MDVQ4\(country.skuCode)/A"
    ]

    let skusToName = [
        "MGPC4\(country.skuCode)/A": "M5 MacBook Air 15in Starlight 24GB 512GB",
        "MDVF4\(country.skuCode)/A": "M5 MacBook Air 15in Starlight 24GB 1TB",
        "MDVK4\(country.skuCode)/A": "M5 MacBook Air 15in Midnight 16GB 1TB",
        "MDVE4\(country.skuCode)/A": "M5 MacBook Air 15in Starlight 16GB 1TB",
        "MGPD4\(country.skuCode)/A": "M5 MacBook Air 15in Midnight 24GB 512GB",
        "MDV94\(country.skuCode)/A": "M5 MacBook Air 15in Silver 16GB 512GB",
        "MDVD4\(country.skuCode)/A": "M5 MacBook Air 15in Starlight 16GB 512GB",
        "MDVN4\(country.skuCode)/A": "M5 MacBook Air 15in Midnight 24GB 1TB",
        "MDVH4\(country.skuCode)/A": "M5 MacBook Air 15in Midnight 16GB 512GB",
        "MDVU4\(country.skuCode)/A": "M5 MacBook Air 15in Sky Blue 24GB 1TB",
        "MDVT4\(country.skuCode)/A": "M5 MacBook Air 15in Sky Blue 16GB 1TB",
        "MDVA4\(country.skuCode)/A": "M5 MacBook Air 15in Silver 16GB 1TB",
        "MDVC4\(country.skuCode)/A": "M5 MacBook Air 15in Silver 24GB 1TB",
        "MGPE4\(country.skuCode)/A": "M5 MacBook Air 15in Sky Blue 24GB 512GB",
        "MDVQ4\(country.skuCode)/A": "M5 MacBook Air 15in Sky Blue 16GB 512GB"
    ]

    return SKUData(orderedSKUs: orderedSkus, lookup: skusToName)
}

func MacBookPro14DataForCountry(_ country: Country) -> SKUData {
    let orderedSkus = [
        "MGDU4\(country.skuCode)/A",
        "MGDT4\(country.skuCode)/A",
        "MDE34\(country.skuCode)/A",
        "MGXX4\(country.skuCode)/A",
        "MGDQ4\(country.skuCode)/A",
        "MDE14\(country.skuCode)/A",
        "MGDN4\(country.skuCode)/A",
        "MEQJ4\(country.skuCode)/A",
        "MDE54\(country.skuCode)/A",
        "MJLW4\(country.skuCode)/A",
        "MJ3D4\(country.skuCode)/A",
        "MDE64\(country.skuCode)/A",
        "MJ3E4\(country.skuCode)/A",
        "MGDP4\(country.skuCode)/A",
        "MJLV4\(country.skuCode)/A",
        "MGDR4\(country.skuCode)/A"
    ]

    let skusToName = [
        "MGDU4\(country.skuCode)/A": "MacBook Pro 14in M5 Max (18c/32c) Space Black 36GB 2TB",
        "MGDT4\(country.skuCode)/A": "MacBook Pro 14in M5 Pro (18c/20c) Space Black 24GB 2TB",
        "MDE34\(country.skuCode)/A": "MacBook Pro 14in M5 (10c/10c) Space Black 24GB 1TB",
        "MGXX4\(country.skuCode)/A": "MacBook Pro 14in M5 Pro (18c/20c) Space Black Nano-texture 48GB 2TB",
        "MGDQ4\(country.skuCode)/A": "MacBook Pro 14in M5 Max (18c/32c) Silver 36GB 2TB",
        "MDE14\(country.skuCode)/A": "MacBook Pro 14in M5 (10c/10c) Space Black 16GB 1TB",
        "MGDN4\(country.skuCode)/A": "MacBook Pro 14in M5 Pro (15c/16c) Silver 24GB 1TB",
        "MEQJ4\(country.skuCode)/A": "MacBook Pro 14in M5 (10c/10c) Space Black Nano-texture 16GB 1TB",
        "MDE54\(country.skuCode)/A": "MacBook Pro 14in M5 (10c/10c) Silver 16GB 1TB",
        "MJLW4\(country.skuCode)/A": "MacBook Pro 14in M5 Pro (15c/16c) Space Black 24GB 2TB",
        "MJ3D4\(country.skuCode)/A": "MacBook Pro 14in M5 (10c/10c) Space Black 32GB 1TB",
        "MDE64\(country.skuCode)/A": "MacBook Pro 14in M5 (10c/10c) Silver 24GB 1TB",
        "MJ3E4\(country.skuCode)/A": "MacBook Pro 14in M5 (10c/10c) Silver 32GB 1TB",
        "MGDP4\(country.skuCode)/A": "MacBook Pro 14in M5 Pro (18c/20c) Silver 24GB 2TB",
        "MJLV4\(country.skuCode)/A": "MacBook Pro 14in M5 Pro (15c/16c) Silver 24GB 2TB",
        "MGDR4\(country.skuCode)/A": "MacBook Pro 14in M5 Pro (15c/16c) Space Black 24GB 1TB"
    ]

    return SKUData(orderedSKUs: orderedSkus, lookup: skusToName)
}

func MacBookPro16DataForCountry(_ country: Country) -> SKUData {
    let orderedSkus = [
        "MGEC4\(country.skuCode)/A",
        "MGEE4\(country.skuCode)/A",
        "MGE94\(country.skuCode)/A",
        "MGE74\(country.skuCode)/A",
        "MGE64\(country.skuCode)/A",
        "MGE44\(country.skuCode)/A",
        "MGED4\(country.skuCode)/A",
        "MGEA4\(country.skuCode)/A"
    ]

    let skusToName = [
        "MGEC4\(country.skuCode)/A": "MacBook Pro 16in M5 Pro (18c/20c) Space Black 48GB 1TB",
        "MGEE4\(country.skuCode)/A": "MacBook Pro 16in M5 Max (18c/40c) Space Black 48GB 2TB",
        "MGE94\(country.skuCode)/A": "MacBook Pro 16in M5 Max (18c/40c) Silver 48GB 2TB",
        "MGE74\(country.skuCode)/A": "MacBook Pro 16in M5 Max (18c/32c) Silver 36GB 2TB",
        "MGE64\(country.skuCode)/A": "MacBook Pro 16in M5 Pro (18c/20c) Silver 48GB 1TB",
        "MGE44\(country.skuCode)/A": "MacBook Pro 16in M5 Pro (18c/20c) Silver 24GB 1TB",
        "MGED4\(country.skuCode)/A": "MacBook Pro 16in M5 Max (18c/32c) Space Black 36GB 2TB",
        "MGEA4\(country.skuCode)/A": "MacBook Pro 16in M5 Pro (18c/20c) Space Black 24GB 1TB"
    ]

    return SKUData(orderedSKUs: orderedSkus, lookup: skusToName)
}

func iMacDataForCountry(_ country: Country) -> SKUData {
    let orderedSkus = [
        "MD2T4\(country.skuCode)/A",
        "MD2U4\(country.skuCode)/A",
        "MD3H4\(country.skuCode)/A",
        "MWUG3\(country.skuCode)/A",
        "MWV83\(country.skuCode)/A",
        "MD2Q4\(country.skuCode)/A",
        "MWUV3\(country.skuCode)/A",
        "MWV03\(country.skuCode)/A",
        "MWUY3\(country.skuCode)/A",
        "MWUF3\(country.skuCode)/A",
        "MWUC3\(country.skuCode)/A",
        "MWV53\(country.skuCode)/A",
        "MWUE3\(country.skuCode)/A",
        "MWUU3\(country.skuCode)/A",
        "MWV13\(country.skuCode)/A",
        "MWV33\(country.skuCode)/A",
        "MWV63\(country.skuCode)/A",
        "MWV43\(country.skuCode)/A",
        "MWUW3\(country.skuCode)/A",
        "MCR24\(country.skuCode)/A"
    ]

    let skusToName = [
        "MD2T4\(country.skuCode)/A": "iMac M4 (10c/10c) Blue 24GB 512GB",
        "MD2U4\(country.skuCode)/A": "iMac M4 (10c/10c) Pink 24GB 512GB",
        "MD3H4\(country.skuCode)/A": "iMac M4 (10c/10c) Silver Nano-texture 16GB 256GB",
        "MWUG3\(country.skuCode)/A": "iMac M4 (8c/8c) Pink 16GB 256GB",
        "MWV83\(country.skuCode)/A": "iMac M4 (10c/10c) Orange 16GB 256GB",
        "MD2Q4\(country.skuCode)/A": "iMac M4 (10c/10c) Green 24GB 512GB",
        "MWUV3\(country.skuCode)/A": "iMac M4 (10c/10c) Silver 16GB 512GB",
        "MWV03\(country.skuCode)/A": "iMac M4 (10c/10c) Green 16GB 512GB",
        "MWUY3\(country.skuCode)/A": "iMac M4 (10c/10c) Green 16GB 256GB",
        "MWUF3\(country.skuCode)/A": "iMac M4 (8c/8c) Blue 16GB 256GB",
        "MWUC3\(country.skuCode)/A": "iMac M4 (8c/8c) Silver 16GB 256GB",
        "MWV53\(country.skuCode)/A": "iMac M4 (10c/10c) Pink 16GB 512GB",
        "MWUE3\(country.skuCode)/A": "iMac M4 (8c/8c) Green 16GB 256GB",
        "MWUU3\(country.skuCode)/A": "iMac M4 (10c/10c) Silver 16GB 256GB",
        "MWV13\(country.skuCode)/A": "iMac M4 (10c/10c) Blue 16GB 256GB",
        "MWV33\(country.skuCode)/A": "iMac M4 (10c/10c) Blue 16GB 512GB",
        "MWV63\(country.skuCode)/A": "iMac M4 (10c/10c) Purple 16GB 256GB",
        "MWV43\(country.skuCode)/A": "iMac M4 (10c/10c) Pink 16GB 256GB",
        "MWUW3\(country.skuCode)/A": "iMac M4 (10c/10c) Yellow 16GB 256GB",
        "MCR24\(country.skuCode)/A": "iMac M4 (10c/10c) Silver 24GB 512GB"
    ]

    return SKUData(orderedSKUs: orderedSkus, lookup: skusToName)
}

func MacMiniDataForCountry(_ country: Country) -> SKUData {
    let orderedSkus = [
        "MHQM4\(country.skuCode)/A",
        "MHQL4\(country.skuCode)/A",
        "MHQK4\(country.skuCode)/A",
        "MHQV4\(country.skuCode)/A",
        "MHQU4\(country.skuCode)/A",
        "MHQN4\(country.skuCode)/A"
    ]

    let skusToName = [
        "MHQM4\(country.skuCode)/A": "Mac mini M6 (12c/12c) 24GB 512GB",
        "MHQL4\(country.skuCode)/A": "Mac mini M6 (12c/12c) 16GB 512GB",
        "MHQK4\(country.skuCode)/A": "Mac mini M6 (12c/12c) 16GB 256GB",
        "MHQV4\(country.skuCode)/A": "Mac mini M6 (12c/12c) 32GB 1TB",
        "MHQU4\(country.skuCode)/A": "Mac mini M5 Pro (18c/20c) 64GB 1TB",
        "MHQN4\(country.skuCode)/A": "Mac mini M5 Pro (15c/16c) 24GB 512GB"
    ]

    return SKUData(orderedSKUs: orderedSkus, lookup: skusToName)
}

func MacStudioDataForCountry(_ country: Country) -> SKUData {
    let orderedSkus = [
        "MHQJ4\(country.skuCode)/A",
        "MHL64\(country.skuCode)/A",
        "MHL74\(country.skuCode)/A"
    ]

    let skusToName = [
        "MHQJ4\(country.skuCode)/A": "Mac Studio M5 Max (18c/40c) 64GB 1TB",
        "MHL64\(country.skuCode)/A": "Mac Studio M5 Max (18c/32c) 36GB 512GB",
        "MHL74\(country.skuCode)/A": "Mac Studio M5 Ultra (30c/64c) 96GB 1TB"
    ]

    return SKUData(orderedSKUs: orderedSkus, lookup: skusToName)
}
