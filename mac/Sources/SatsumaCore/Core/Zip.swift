import Foundation
import Compression

/// Minimal ZIP reading and writing (store and deflate, no ZIP64), enough for DOCX, XLSX, ODS, EPUB and PPTX parts.
public enum Zip {
    // ------------------------------------------------------------------ CRC-32

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    // ------------------------------------------------------------------ raw deflate

    static func deflate(_ src: [UInt8]) -> [UInt8]? {
        if src.isEmpty { return nil }
        let cap = src.count + src.count / 8 + 1024
        var dst = [UInt8](repeating: 0, count: cap)
        let n = dst.withUnsafeMutableBufferPointer { d in
            src.withUnsafeBufferPointer { s in
                compression_encode_buffer(d.baseAddress!, cap, s.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        if n == 0 || n >= src.count { return nil }
        return Array(dst[0..<n])
    }

    static func inflate(_ src: ArraySlice<UInt8>, size: Int) -> [UInt8]? {
        if size == 0 { return [] }
        var dst = [UInt8](repeating: 0, count: size)
        let copy = Array(src)
        let n = dst.withUnsafeMutableBufferPointer { d in
            copy.withUnsafeBufferPointer { s in
                compression_decode_buffer(d.baseAddress!, size, s.baseAddress!, copy.count, nil, COMPRESSION_ZLIB)
            }
        }
        return n == size ? dst : nil
    }

    // ------------------------------------------------------------------ writing

    public final class Writer {
        struct Entry { let name: [UInt8]; let crc: UInt32; let method: UInt16; let compressed: Int; let size: Int; let offset: Int }
        private var out: [UInt8] = []
        private var entries: [Entry] = []
        private let time: UInt16
        private let date: UInt16

        public init() {
            let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
            time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
            date = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        }

        private func u16(_ v: UInt16) { out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8)) }
        private func u32(_ v: UInt32) { for i in 0..<4 { out.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }

        public func add(_ name: String, _ text: String, compress: Bool = true) { add(name, data: Array(text.utf8), compress: compress) }

        public func add(_ name: String, data: [UInt8], compress: Bool = true) {
            let nameBytes = Array(name.utf8)
            let crc = crc32(data)
            let packed = compress ? deflate(data) : nil
            let method: UInt16 = packed == nil ? 0 : 8
            let body = packed ?? data
            let offset = out.count
            u32(0x0403_4B50); u16(20); u16(0x0800); u16(method); u16(time); u16(date)
            u32(crc); u32(UInt32(body.count)); u32(UInt32(data.count)); u16(UInt16(nameBytes.count)); u16(0)
            out += nameBytes
            out += body
            entries.append(Entry(name: nameBytes, crc: crc, method: method, compressed: body.count, size: data.count, offset: offset))
        }

        public func finish() -> Data {
            let cdStart = out.count
            for e in entries {
                u32(0x0201_4B50); u16(0x0314); u16(20); u16(0x0800); u16(e.method); u16(time); u16(date)
                u32(e.crc); u32(UInt32(e.compressed)); u32(UInt32(e.size)); u16(UInt16(e.name.count)); u16(0); u16(0)
                u16(0); u16(0); u32(0o100644 << 16); u32(UInt32(e.offset))
                out += e.name
            }
            let cdSize = out.count - cdStart
            u32(0x0605_4B50); u16(0); u16(0); u16(UInt16(entries.count)); u16(UInt16(entries.count))
            u32(UInt32(cdSize)); u32(UInt32(cdStart)); u16(0)
            return Data(out)
        }

        public func write(to path: String) throws { try finish().write(to: P.url(path)) }
    }

    // ------------------------------------------------------------------ reading

    public final class Reader {
        public struct Entry { public let name: String; let method: UInt16; let compressed: Int; let size: Int; let offset: Int }
        private let bytes: [UInt8]
        public private(set) var entries: [Entry] = []

        public init(path: String) throws {
            bytes = [UInt8](try Data(contentsOf: P.url(path)))
            try parse()
        }

        private func u16(_ at: Int) -> Int { at + 1 < bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : 0 }
        private func u32(_ at: Int) -> Int { at + 3 < bytes.count ? u16(at) | u16(at + 2) << 16 : 0 }

        private func parse() throws {
            let minEnd = max(0, bytes.count - 65_557)
            var eocd = -1
            var i = bytes.count - 22
            while i >= minEnd {
                if bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 0x05 && bytes[i + 3] == 0x06 { eocd = i; break }
                i -= 1
            }
            if eocd < 0 { throw OpError("Not a valid ZIP-based file.") }
            let count = u16(eocd + 10)
            var p = u32(eocd + 16)
            for _ in 0..<count {
                guard p + 46 <= bytes.count, u32(p) == 0x0201_4B50 else { break }
                let method = UInt16(u16(p + 10))
                let compressed = u32(p + 20), size = u32(p + 24)
                let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
                let offset = u32(p + 42)
                let nameBytes = bytes[(p + 46)..<min(bytes.count, p + 46 + nameLen)]
                let name = String(decoding: nameBytes, as: UTF8.self)
                entries.append(Entry(name: name, method: method, compressed: compressed, size: size, offset: offset))
                p += 46 + nameLen + extraLen + commentLen
            }
        }

        public func entry(_ name: String) -> Entry? {
            entries.first { $0.name == name } ?? entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        public func data(_ name: String) -> [UInt8]? { entry(name).flatMap(data(of:)) }

        public func data(of e: Entry) -> [UInt8]? {
            let h = e.offset
            guard h + 30 <= bytes.count, u32(h) == 0x0403_4B50 else { return nil }
            let start = h + 30 + u16(h + 26) + u16(h + 28)
            guard start + e.compressed <= bytes.count else { return nil }
            let body = bytes[start..<(start + e.compressed)]
            switch e.method {
            case 0: return Array(body)
            case 8: return inflate(body, size: e.size)
            default: return nil
            }
        }

        public func text(_ name: String) -> String? { data(name).map { TextUtil.decode(Data($0)) } }

        public func xml(_ name: String) -> XMLDocument? {
            guard let d = data(name) else { return nil }
            return try? XMLDocument(data: Data(d), options: [.nodePreserveWhitespace])
        }
    }
}

extension XMLElement {
    var elementChildren: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }

    func kids(_ local: String, _ ns: String) -> [XMLElement] { elements(forLocalName: local, uri: ns) }
    func kid(_ local: String, _ ns: String) -> XMLElement? { elements(forLocalName: local, uri: ns).first }

    func descendants(_ local: String, _ ns: String? = nil) -> [XMLElement] {
        var out: [XMLElement] = []
        func walk(_ e: XMLElement) {
            for c in e.elementChildren {
                if c.localName == local && (ns == nil || c.uri == ns) { out.append(c) }
                walk(c)
            }
        }
        walk(self)
        return out
    }

    func attr(_ local: String, _ ns: String? = nil) -> String? {
        if let ns { return attribute(forLocalName: local, uri: ns)?.stringValue }
        return attribute(forName: local)?.stringValue
    }

    func named(_ local: String, _ ns: String) -> Bool { localName == local && uri == ns }
}

extension XMLDocument {
    func descendants(_ local: String, _ ns: String? = nil) -> [XMLElement] {
        guard let root = rootElement() else { return [] }
        var all = root.descendants(local, ns)
        if root.localName == local && (ns == nil || root.uri == ns) { all.insert(root, at: 0) }
        return all
    }
}

/// XML text escaping that also drops characters XML 1.0 can't carry.
public func xmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for u in s.unicodeScalars {
        switch u {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        default:
            let v = u.value
            if v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v != 0xFFFE && v != 0xFFFF) { out.unicodeScalars.append(u) }
        }
    }
    return out
}
