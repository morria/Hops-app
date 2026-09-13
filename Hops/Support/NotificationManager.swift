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

    /// Set by the app so notification taps can deep-link. A tap that cold-
    /// launches the app can arrive before the UI wires this up — buffer the
    /// key and flush it the moment the handler lands.
    var openConversation: ((String, Int64) -> Void)? {
        didSet {
            if let pending = pendingOpen, let open = openConversation {
                pendingOpen = nil
                open(pending.key, pending.packetId)
            }
        }
    }
    private var pendingOpen: (key: String, packetId: Int64)?

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

    #if MESHSITES
    /// A reader submitted a form on the user's Meshsite (TODO 191). Field
    /// text is RF input — sanitized and truncated before it reaches a banner.
    func postFormSubmission(from: Int64, path: String, fields: [(String, String)]) {
        let content = UNMutableNotificationContent()
        let site = MeshsiteServer.siteName
        content.title = site.isEmpty ? "New form reply on your site" : "New form reply on \(site)"
        let who = String(format: "!%08x", UInt32(truncatingIfNeeded: from))
        let summary = fields.map { "\($0.0)=\(MeshsitesManager.sanitizeDisplay($0.1))" }.joined(separator: ", ")
        var body = "\(who) on \(path)"
        if !summary.isEmpty { body += " — \(summary)" }
        content.body = body.count > 160 ? String(body.prefix(159)) + "…" : body
        content.sound = .default
        content.threadIdentifier = "meshsite-replies"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "meshsite-reply-\(UUID().uuidString)", content: content, trigger: nil))
    }
    #endif

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

    // Both delegate methods use the completion-handler form on purpose. The
    // `async` variants let Swift call the completion from whatever executor
    // the task ends on — a cooperative background thread after `await
    // MainActor.run` — and UIKit's state-restoration work inside that
    // completion asserts off the main thread on iOS 26: SIGABRT in
    // _updateSnapshotAndStateRestorationWithAction on every tap (TODO 186).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { completionHandler([.list, .banner, .sound]) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let key = userInfo["conversationKey"] as? String
        let senderNum = userInfo["senderNum"] as? Int64 ?? Int64(userInfo["senderNum"] as? Int ?? 0)
        let packetId = userInfo["packetId"] as? Int64 ?? Int64(userInfo["packetId"] as? Int ?? 0)
        let actionId = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText

        Task { @MainActor in
            defer { completionHandler() }   // always on the main actor
            guard let key else { return }
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
                if let open = NotificationManager.shared.openConversation {
                    radio.noteAppEvent("notification tap: \(key) → handler")
                    open(key, packetId)
                } else {
                    radio.noteAppEvent("notification tap: \(key) → buffered (cold launch)")
                    NotificationManager.shared.pendingOpen = (key, packetId)
                }
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
