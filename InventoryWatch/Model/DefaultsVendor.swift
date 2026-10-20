//
//  DefaultsVendor.swift
//  InventoryWatch
//
//  Created by Worth Baker on 10/25/22.
//

import Foundation

struct DefaultsVendor {

    /// The country new searches start in (Settings). It keeps the key of
    /// the app-wide country setting it replaced, which saved the United
    /// Kingdom as "UK"; a code the catalog doesn't have reads as "US".
    var defaultCountryCode: CountryCode {
        let stored = UserDefaults.standard.string(forKey: "preferredCountry") ?? "US"
        let code = stored == "UK" ? "GB" : stored
        return Country.with(code: code) == nil ? "US" : code
    }
}
