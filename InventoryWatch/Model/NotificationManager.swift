//
//  NotificationManager.swift
//  InventoryWatch
//
//  Created by Worth Baker on 11/8/21.
//

import Foundation
import os
import UserNotifications

private let logger = Logger(subsystem: "com.wehbs.ReadyForPickup", category: "Notifications")

// Sendable (no stored state) rather than @MainActor: UserNotifications
// calls the delegate method and completion handlers on its own queue.
final class NotificationManager: NSObject, Sendable {
    
    static let shared = NotificationManager()
    
    func requestNotificationPermissions() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        
        center.requestAuthorization(options: [.alert, .badge, .sound]) { (granted, error) in
            if let error {
                logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else if granted == false {
                logger.info("Notifications are disabled for this app")
            }
        }
    }
    
    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        
        let uuidString = UUID().uuidString
        let request = UNNotificationRequest(identifier: uuidString,content: content, trigger: trigger)
        
        // Schedule the request with the system.
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.add(request) { (error) in
            if let error {
                logger.error("Couldn't post a notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Swift.Void) {
        completionHandler( [.banner, .badge, .sound])
    }
}
