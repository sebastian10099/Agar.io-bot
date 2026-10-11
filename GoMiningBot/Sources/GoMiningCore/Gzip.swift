import Foundation

/// Entpackt die Nachrichten des BingX-Livestreams (gzip, selten zlib oder Klartext).
public enum Gzip {
    /// Gibt Klartext unveraendert zurueck, entpackt gzip/zlib und liefert sonst nil.
    public static func decode(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }

        if bytes[0] == 0x1f, bytes[1] == 0x8b {
            guard let start = gzipPayloadStart(bytes), bytes.count >= start + 8 else { return nil }
            let payload = Data(bytes[start..<(bytes.count - 8)])
            return inflate(payload)
        }
        if bytes[0] == 0x78, [0x01, 0x5e, 0x9c, 0xda].contains(bytes[1]), bytes.count > 6 {
            return inflate(Data(bytes[2..<(bytes.count - 4)]))
        }
        // Klartext (JSON oder "Ping").
        if bytes[0] == UInt8(ascii: "{") || bytes[0] == UInt8(ascii: "[") || bytes[0] == UInt8(ascii: "P") || bytes[0] == UInt8(ascii: "p") {
            return data
        }
        return nil
    }

    /// Position des Deflate-Datenstroms hinter dem gzip-Kopf (RFC 1952).
    static func gzipPayloadStart(_ b: [UInt8]) -> Int? {
        guard b.count >= 18, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 {                     // FEXTRA
            guard b.count > i + 2 else { return nil }
            i += 2 + Int(b[i]) + Int(b[i + 1]) << 8
        }
        if flags & 0x08 != 0 {                     // FNAME
            while i < b.count, b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x10 != 0 {                     // FCOMMENT
            while i < b.count, b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }            // FHCRC
        return i < b.count ? i : nil
    }

    /// Rohes Deflate (RFC 1951) entpacken. Apples COMPRESSION_ZLIB erwartet genau dieses Format.
    public static func inflate(_ raw: Data) -> Data? {
        guard let out = try? (raw as NSData).decompressed(using: .zlib) else { return nil }
        return out as Data
    }

    /// Nur fuer Tests: verpackt Rohdaten als gzip (CRC wird nicht geprueft).
    public static func wrapForTests(_ plain: Data) -> Data? {
        guard let deflated = try? (plain as NSData).compressed(using: .zlib) else { return nil }
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        out.append(deflated as Data)
        out.append(Data([0, 0, 0, 0, 0, 0, 0, 0]))
        return out
    }
}
