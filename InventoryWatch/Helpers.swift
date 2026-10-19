//
//  Helpers.swift
//  InventoryWatch
//
//  Created by Worth Baker on 3/19/22.
//

import Foundation

typealias SKUString = String
typealias CountryCode = String

extension Array where Element == String {
  func sortedNumerically() -> [Element] {
    sorted { lhs, rhs in
      lhs.compare(rhs, options: [.numeric], locale: .current) == .orderedAscending
    }
  }
}
