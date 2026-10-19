//
//  ModelError.swift
//  InventoryWatch
//
//  Created by Worth Baker on 10/25/22.
//

import Foundation

enum AppError: Swift.Error, LocalizedError {
    case invalidLocalModelStore
    case invalidProjectState
    case couldNotGenerateURL
    case noStoresFound
    case storeUnavailable
    case throttled(Int)
    case invalidStoreResponse
    case unexpectedJSONStructure
    
    var errorDescription: String? {
        return "\(self)"
    }
    
    var errorMessage: String {
        switch self {
        case .couldNotGenerateURL:
            return "ReadyForPickup failed to construct a valid URL for your search."
        case .invalidStoreResponse, .unexpectedJSONStructure, .noStoresFound:
            return "Unexpected inventory data found. Please confirm that the selected store is valid for the selected country."
        case .storeUnavailable:
            return "Apple's fulfillment API returned an internal server error and is currently unavailable."
        case .throttled(let statusCode):
            return "Apple is throttling requests (HTTP \(statusCode)); retrying later."
        case .invalidLocalModelStore, .invalidProjectState:
            return "ReadyForPickup has invalid or corrupted local data."
        }
    }
}
