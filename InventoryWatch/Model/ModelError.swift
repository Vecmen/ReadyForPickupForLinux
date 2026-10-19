//
//  ModelError.swift
//  InventoryWatch
//
//  Created by Worth Baker on 10/25/22.
//

import Foundation

enum AppError: Swift.Error, LocalizedError {
    case failedToParseGithubVersion
    case invalidLocalModelStore
    case invalidProjectState
    case couldNotGenerateURL
    case noStoresFound
    case storeUnavailable
    case throttled(Int)
    case invalidStoreResponse
    case unexpectedJSONStructure
    case generic(Error?)
    
    var errorDescription: String? {
        switch self {
        case .generic(let error):
            return error?.localizedDescription ?? "unknown error"
        default:
            return "\(self)"
        }
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
        case .invalidLocalModelStore, .invalidProjectState, .failedToParseGithubVersion:
            return "ReadyForPickup has invalid or corrupted local data."
        case .generic(let optional):
            return "A network error occurred. Details: \(optional?.localizedDescription ?? "unknown")"
        }
    }
}
