// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Chrome Native Messaging wire framing: 4-byte little-endian length + UTF-8 JSON body.
public enum NativeMessagingFraming {
    public enum FramingError: Error, Equatable, Sendable {
        case truncatedHeader
        case truncatedBody
        case messageTooLarge
        case invalidUTF8
    }

    /// Chrome caps native messaging payloads at 1 MiB.
    public static let maxMessageBytes = 1_048_576

    public static func encode(_ jsonObject: Any) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
        guard body.count <= maxMessageBytes else { throw FramingError.messageTooLarge }
        var length = UInt32(body.count).littleEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(body)
        return packet
    }

    public static func encodeJSONData(_ body: Data) throws -> Data {
        guard body.count <= maxMessageBytes else { throw FramingError.messageTooLarge }
        var length = UInt32(body.count).littleEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(body)
        return packet
    }

    public static func decodeNext(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length: UInt32 = buffer.prefix(4).withUnsafeBytes { raw in
            raw.load(as: UInt32.self).littleEndian
        }
        let bodyLength = Int(length)
        guard bodyLength <= maxMessageBytes else { throw FramingError.messageTooLarge }
        guard buffer.count >= 4 + bodyLength else { return nil }
        let body = buffer.subdata(in: 4 ..< (4 + bodyLength))
        buffer.removeSubrange(0 ..< (4 + bodyLength))
        return body
    }

    public static func readMessage(from handle: FileHandle) throws -> Data {
        let header = handle.readData(ofLength: 4)
        guard header.count == 4 else { throw FramingError.truncatedHeader }
        let length: UInt32 = header.withUnsafeBytes { raw in
            raw.load(as: UInt32.self).littleEndian
        }
        let bodyLength = Int(length)
        guard bodyLength <= maxMessageBytes else { throw FramingError.messageTooLarge }
        let body = handle.readData(ofLength: bodyLength)
        guard body.count == bodyLength else { throw FramingError.truncatedBody }
        return body
    }

    public static func writeMessage(_ body: Data, to handle: FileHandle) throws {
        let packet = try encodeJSONData(body)
        try handle.write(contentsOf: packet)
    }
}
