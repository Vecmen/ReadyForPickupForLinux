//
//  Countries.swift
//  InventoryWatch
//
//  Created by Worth Baker on 11/10/21.
//

import Foundation

struct Country: Hashable {
    let name: String
    let shortcode: String
    let locale: String
    let skuCode: String
}

let USData = Country(
    name: "United States",
    shortcode: "US",
    locale: "en_US",
    skuCode: "LL"
)

let AllCountries = [
    USData,
    Country(name: "Canada", shortcode: "CA", locale: "en_CA", skuCode: "LL"),
    Country(name: "Australia", shortcode: "AU", locale: "en_AU", skuCode: "X"),
    Country(name: "Germany", shortcode: "DE", locale: "de_DE", skuCode: "D"),
    Country(name: "United Kingdom", shortcode: "UK", locale: "en_GB", skuCode: "B"),
    Country(name: "South Korea", shortcode: "KR", locale: "ko_KR", skuCode: "KH"),
    Country(name: "Hong Kong", shortcode: "HK", locale: "en_HK", skuCode: "ZP"),
    Country(name: "France", shortcode: "FR", locale: "fr_FR", skuCode: "FN"),
    Country(name: "Italy", shortcode: "IT", locale: "it_IT", skuCode: "T"),
    Country(name: "Japan", shortcode: "JP", locale: "ja_JP", skuCode: "J"),
    Country(name: "Austria", shortcode: "AT", locale: "de_AT", skuCode: "D"),
    Country(name: "Netherlands", shortcode: "NL", locale: "nl_NL", skuCode: "N"),
    Country(name: "Thailand", shortcode: "TH", locale: "th_TH", skuCode: "TH"),
]
let Countries: [CountryCode: Country] = Dictionary(uniqueKeysWithValues: AllCountries.map { ($0.shortcode, $0) })
let OrderedCountries: [CountryCode] = AllCountries.map { $0.shortcode }
