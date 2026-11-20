import Foundation

/// Packets for the configuration channel of AULA's wireless keyboards (the Epomaker x
/// Aula F75 and the models that share its receiver): a vendor HID collection on usage
/// page 0xFF02 that carries 20-byte output reports with id 0x13.
///
/// Only the "real-time lighting" command is built here. It is what the vendor's own
/// app streams in its music mode: the keyboard shows a frame until the next one
/// arrives, goes back to its own effect a second or two after the last, and stores
/// nothing. Commands that write the keyboard's saved settings are deliberately absent:
/// a wrong settings block has stopped keyboards from typing until reflashed.
///
/// Seen working on an F75 over Bluetooth while a firmware effect (rainbow) was running.
///
/// Layout, from two independent write-ups that agree with each other and with packets
/// captured from the vendor app (bakiakyol/aula-f75-hub, headblade-dev/keylux-linux):
///
///     [0]     0x13                 report id
///     [1]     command
///     [2]     packets in this message
///     [3]     index of this packet
///     [4]     (sub << 4) | payload length
///     [5…18]  payload, zero padded
///     [19]    sum of bytes 0…18, mod 256
public enum AulaLighting {
    public static let vendorID = 0x3554
    /// Product ids the channel is documented on: Bluetooth, and the 2.4G receiver.
    public static let productIDs: Set<Int> = [0xFA07, 0xFA09]
    public static let usagePage = 0xFF02
    public static let reportID: UInt8 = 0x13
    public static let packetLength = 20

    static let realTimeLighting: UInt8 = 0x88
    static let wholeBoard: UInt8 = 2

    static let perKey: UInt8 = 1
    /// Payload bytes one packet carries.
    public static let chunk = 14
    /// Longest per-key frame worth sending: beyond about nine packets the keyboard
    /// starts dropping frames.
    public static let longestFrame = 9 * chunk

    /// A message split into as many packets as it needs.
    public static func packets(command: UInt8, sub: UInt8, payload: [UInt8]) -> [[UInt8]] {
        precondition(sub <= 0x0F)
        let chunks: [ArraySlice<UInt8>] = payload.isEmpty
            ? [[]]
            : stride(from: 0, to: payload.count, by: chunk).map { payload[$0..<min($0 + chunk, payload.count)] }
        return chunks.enumerated().map { index, part in
            var bytes = [UInt8](repeating: 0, count: packetLength)
            bytes[0] = reportID
            bytes[1] = command
            bytes[2] = UInt8(truncatingIfNeeded: chunks.count)
            bytes[3] = UInt8(truncatingIfNeeded: index)
            bytes[4] = (sub << 4) | UInt8(part.count)
            bytes.replaceSubrange(5..<(5 + part.count), with: part)
            bytes[19] = UInt8(truncatingIfNeeded: bytes[0..<19].reduce(0) { $0 + Int($1) })
            return bytes
        }
    }

    /// One single-packet message. `payload` is at most 14 bytes.
    public static func packet(command: UInt8, sub: UInt8, payload: [UInt8]) -> [UInt8]? {
        guard payload.count <= chunk, sub <= 0x0F else { return nil }
        return packets(command: command, sub: sub, payload: payload)[0]
    }

    /// A real-time frame painting every key one colour.
    public static func wholeBoard(red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        packet(command: realTimeLighting, sub: wholeBoard, payload: [red, green, blue])!
    }

    /// Keys sharing one colour in a per-key frame.
    public struct Group: Sendable, Equatable {
        public var red: UInt8, green: UInt8, blue: UInt8
        public var lights: [Int]

        public init(red: UInt8, green: UInt8, blue: UInt8, lights: [Int]) {
            self.red = red
            self.green = green
            self.blue = blue
            self.lights = lights
        }
    }

    /// The payload of a per-key frame: groups of `R G B count index…`, back to back.
    /// Keys that are not listed go dark, so black groups are left out.
    public static func perKeyPayload(_ groups: [Group]) -> [UInt8] {
        var payload: [UInt8] = []
        for group in groups where !group.lights.isEmpty && (group.red != 0 || group.green != 0 || group.blue != 0) {
            payload += [group.red, group.green, group.blue, UInt8(truncatingIfNeeded: group.lights.count)]
            payload += group.lights.sorted().map { UInt8(truncatingIfNeeded: $0) }
        }
        // Nothing lit: one dark key, which turns everything off.
        return payload.isEmpty ? [0, 0, 0, 1, 0] : payload
    }

    /// A real-time frame colouring keys individually.
    public static func perKey(_ groups: [Group]) -> [[UInt8]] {
        packets(command: realTimeLighting, sub: perKey, payload: perKeyPayload(groups))
    }
}
