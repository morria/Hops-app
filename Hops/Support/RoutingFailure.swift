import Foundation

/// Words for a failed send, keyed by the firmware's Routing.Error raw value
/// (plus our -1 local-timeout sentinel). `short` is the one-line transcript
/// status; `detail` is the Delivery Details explanation. One table so the
/// two never disagree (TODO 181).
enum RoutingFailure {

    static func short(code: Int32, isDM: Bool) -> String {
        switch code {
        case -1: return "No response"
        case 1:  return "No route to their radio"
        case 2:  return "Their radio rejected it"
        case 3:  return "Timed out in the mesh"
        case 5:  return "No response after retries"
        case 6:  return "No matching channel on their side"
        case 7:  return "Too large for the mesh"
        case 8:  return "Their radio saw it but didn't answer"
        case 9:  return "Airtime limit hit - try again shortly"
        case 34: return "Key mismatch - their key may have changed"
        case 35: return "Their radio didn't have your key - it does now, so retry"
        case 38: return "Rate limited - try again shortly"
        case 39: return "Your radio doesn't have their key"
        default: return isDM ? "No response from their radio" : "Couldn't send"
        }
    }

    static func detail(code: Int32) -> String {
        switch code {
        case -1:
            return "No acknowledgment arrived before the timeout. The message may still have been delivered - acks get lost more often than messages do."
        case 1:
            return "No route to the destination was found."
        case 2:
            return "The destination radio rejected the message (NAK)."
        case 3:
            return "The request timed out inside the mesh."
        case 5:
            return "Your radio gave up after its maximum retransmissions - nothing acknowledged the packet."
        case 6:
            return "The receiving side has no matching channel for this message."
        case 7:
            return "The message was too large for the mesh."
        case 8:
            return "The destination saw the request but sent no response."
        case 9:
            return "A radio on the path hit its regulatory duty-cycle limit."
        case 34:
            return "Encryption keys don't match - the destination couldn't decrypt it. Their key may have changed; check their node card."
        case 35:
            return "Their radio didn't have your public key, so it couldn't decrypt the message. Your radio has since sent your node info, so a retry usually goes through."
        case 38:
            return "Your radio rate-limited this send. Wait a moment and retry."
        case 39:
            return "Your radio has no public key on file for the destination - it may have dropped out of the radio's node list. A retry re-shares the contact first."
        default:
            return "Routing error code \(code)."
        }
    }
}
