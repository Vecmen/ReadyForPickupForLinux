//
//  DefaultsVendor.swift
//  InventoryWatch
//
//  Created by Worth Baker on 10/25/22.
//

import Foundation

extension UserDefaults {

    @objc dynamic var preferredStoreNumber: String {
        get { string(forKey: "preferredStoreNumber") ?? "R032" }
        set { setValue(newValue, forKey: "preferredStoreNumber") }
    }
}

struct DefaultsVendor {

    var preferredCountry: Country {
        let value = UserDefaults.standard.string(forKey: "preferredCountry") ?? "US"

        return Countries[value] ?? USData
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
}
