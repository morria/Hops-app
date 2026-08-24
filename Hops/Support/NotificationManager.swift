import Foundation
import UserNotifications
import Intents
import OSLog

@MainActor
final class NotificationManager: NSObject {

    static let shared = NotificationManager()

    private let log = Logger(subsystem: "com.w2asm.hops", category: "notifications")
    static let messageCategory = "com.w2asm.hops.message"
    static let replyAction = "com.w2asm.hops.message.reply"
    static let thumbsUpAction = "com.w2asm.hops.message.thumbsup"

    /// Set by the app so notification taps can deep-link.
    var openConversation: ((String) -> Void)?

    func bootstrap() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction, title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let thumbsUp = UNNotificationAction(identifier: Self.thumbsUpAction, title: "👍", options: [])
        let category = UNNotificationCategory(
            identifier: Self.messageCategory, actions: [reply, thumbsUp],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    /// Asked once the app has shown value (first successful sync), not at launch.
    func requestPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    func postMessage(_ inbound: MessageStore.InboundMessage) {
        let content = UNMutableNotificationContent()
        content.title = inbound.isDM ? inbound.senderName : inbound.conversationTitle
        if !inbound.isDM {
            content.subtitle = inbound.senderName
        }
        content.body = inbound.text
        content.sound = .default
        content.threadIdentifier = inbound.conversationKey
        content.categoryIdentifier = Self.messageCategory
        content.userInfo = [
            "conversationKey": inbound.conversationKey,
            "senderNum": inbound.senderNum,
            "packetId": inbound.packetId,
        ]
        // DMs may use time-sensitive; channel traffic never does (Focus breakthrough
        // belongs to communication notifications + the user's own allowances).
        if inbound.isDM {
            content.interruptionLevel = .timeSensitive
        }

        var finalContent: UNNotificationContent = content
        let sender = INPerson(
            personHandle: INPersonHandle(value: "node-\(inbound.senderNum)", type: .unknown),
            nameComponents: nil,
            displayName: inbound.senderName,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: "node-\(inbound.senderNum)")
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: inbound.text,
            speakableGroupName: inbound.isDM ? nil : INSpeakableString(spokenPhrase: inbound.conversationTitle),
            conversationIdentifier: inbound.conversationKey,
            serviceName: "Meshtastic",
            sender: sender,
            attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        if let updated = try? content.updating(from: intent) {
            finalContent = updated
        }

        let request = UNNotificationRequest(
            identifier: "message-\(inbound.packetId)",
            content: finalContent,
            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func postBondLost() {
        let content = UNMutableNotificationContent()
        content.title = "Radio needs re-pairing"
        content.body = "Open Hops to pair with your radio again."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "bond-lost", content: content, trigger: nil))
    }

    func postOutboxHeld() {
        let content = UNMutableNotificationContent()
        content.title = "Couldn't send yet"
        content.body = "Your message will send when your radio reconnects."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "outbox-held-\(UUID().uuidString)", content: content, trigger: nil))
    }

    func clearNotifications(for conversationKey: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { ($0.request.content.userInfo["conversationKey"] as? String) == conversationKey }
                .map { $0.request.identifier }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func setBadge(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.list, .banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        guard let key = userInfo["conversationKey"] as? String else { return }
        let senderNum = userInfo["senderNum"] as? Int64 ?? Int64(userInfo["senderNum"] as? Int ?? 0)
        let packetId = userInfo["packetId"] as? Int64 ?? Int64(userInfo["packetId"] as? Int ?? 0)

        let actionId = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText

        await MainActor.run {
            let radio = RadioManager.shared
            let destination = Self.destination(forConversationKey: key, senderNum: senderNum)
            switch actionId {
            case NotificationManager.replyAction:
                if let text = replyText, !text.isEmpty, let destination {
                    // Outbox-backed: persists immediately, transmits now or on reconnect.
                    radio.sendText(text, to: destination)
                    if radio.state != .connected {
                        NotificationManager.shared.postOutboxHeld()
                    }
                    radio.connectIfNeeded()
                }
            case NotificationManager.thumbsUpAction:
                if let destination {
                    radio.sendText("👍", to: destination, isEmoji: true, replyId: packetId)
                    radio.connectIfNeeded()
                }
            default:
                NotificationManager.shared.openConversation?(key)
            }
        }
    }

    private static func destination(forConversationKey key: String, senderNum: Int64) -> MessageDestinationRef? {
        if key.hasPrefix("ch-"), let index = Int32(key.dropFirst(3)) {
            return .channel(index)
        }
        if key.hasPrefix("dm-"), let num = Int64(key.dropFirst(3)) {
            return .node(num)
        }
        return senderNum > 0 ? .node(senderNum) : nil
    }
}
