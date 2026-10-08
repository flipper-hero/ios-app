import Foundation

/// Minimal gzip + ustar reader for firmware update packages. Only regular files and folders.
public enum TarGz {
    public struct Entry: Sendable, Equatable {
        public var path: String
        public var data: Data
    }

    public enum ArchiveError: Error, Equatable, CustomStringConvertible {
        case notGzip
        case corrupt(String)
        case tooLarge

        public var description: String {
            switch self {
            case .notGzip: L("The package is not a gzip archive")
            case .corrupt(let why): L("The package is damaged: \(why)")
            case .tooLarge: L("The package is unexpectedly large")
            }
        }
    }

    public static let maxUnpackedBytes = 64 * 1024 * 1024

    public static func extract(_ gz: Data) throws -> [Entry] {
        try untar(gunzip(gz))
    }

    /// Strips the gzip framing (RFC 1952) and inflates the raw deflate stream inside.
    public static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { throw ArchiveError.notGzip }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else { throw ArchiveError.corrupt("extra field") }
            offset += 2 + Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        }
        if flags & 0x08 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 } // FNAME
        if flags & 0x10 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 } // FCOMMENT
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < bytes.count - 8 else { throw ArchiveError.corrupt("header") }
        let deflated = data.subdata(in: data.startIndex + offset ..< data.endIndex - 8)
        guard let inflated = try? (deflated as NSData).decompressed(using: .zlib) as Data else {
            throw ArchiveError.corrupt("deflate stream")
        }
        guard inflated.count <= maxUnpackedBytes else { throw ArchiveError.tooLarge }
        return inflated
    }

    public static func untar(_ tar: Data) throws -> [Entry] {
        var entries: [Entry] = []
        var offset = tar.startIndex
        while offset + 512 <= tar.endIndex {
            let header = tar.subdata(in: offset ..< offset + 512)
            if header.allSatisfy({ $0 == 0 }) { break } // end-of-archive marker
            let name = field(header, 0, 100)
            let prefix = field(header, 345, 155)
            let path = prefix.isEmpty ? name : prefix + "/" + name
            guard let size = Int(field(header, 124, 12).trimmingCharacters(in: .whitespaces), radix: 8) else {
                throw ArchiveError.corrupt("size of \(path)")
            }
            let type = header[header.startIndex + 156]
            let dataStart = offset + 512
            guard dataStart + size <= tar.endIndex else { throw ArchiveError.corrupt("truncated \(path)") }
            if type == UInt8(ascii: "0") || type == 0 {
                entries.append(Entry(path: path, data: tar.subdata(in: dataStart ..< dataStart + size)))
            }
            offset = dataStart + ((size + 511) / 512) * 512
        }
        return entries
    }

    private static func field(_ header: Data, _ start: Int, _ length: Int) -> String {
        let slice = header.subdata(in: header.startIndex + start ..< header.startIndex + start + length)
        let end = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(decoding: slice[slice.startIndex..<end], as: UTF8.self)
    }
}
