// LZO1X 圧縮。
//
// compress(_:) は niw/EPaperNFCSwift (MIT License) の LZO.swift を元にしています。
//   Copyright (c) 2026 Yoshimasa Niwa
//   https://github.com/niw/EPaperNFCSwift
// ライセンス全文は THIRD_PARTY_NOTICES.md を参照してください。

import Foundation

enum LZO1X {
    /// ストリーム終端マーカー。
    static let endOfStream: [UInt8] = [0x11, 0x00, 0x00]

    /// LZO1X 形式で圧縮する（1ブロック=最大2000バイト程度の入力を想定）。
    static func compress(_ data: Data) -> Data {
        let src = [UInt8](data)
        let n = src.count
        var out = [UInt8]()
        out.reserveCapacity(n + n / 16 + 8)

        if n == 0 {
            return Data(endOfStream)
        }

        struct Match {
            let start: Int
            let length: Int
            let distance: Int
        }

        func hash3(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> Int {
            let v = (UInt32(b0) << 16) | (UInt32(b1) << 8) | UInt32(b2)
            return Int((v &* 2_654_435_761) >> 16) & 0xFFFF
        }

        func appendLengthExtension(_ value: Int) {
            var v = value
            while v > 255 {
                out.append(0)
                v -= 255
            }
            out.append(UInt8(v))
        }

        func appendLE16(_ v: Int) {
            out.append(UInt8(v & 0xff))
            out.append(UInt8((v >> 8) & 0xff))
        }

        // state == 0 のときだけ使える長いリテラル。
        func emitLongLiteral(start: Int, end: Int) {
            let len = end - start
            precondition(len >= 4)
            if len <= 18 {
                out.append(UInt8(len - 3))
            } else {
                out.append(0x00)
                appendLengthExtension(len - 18)
            }
            out.append(contentsOf: src[start..<end])
        }

        // 先頭のリテラル。戻り値は出力後の state。
        func emitFirstLiteral(start: Int, end: Int) -> Int {
            let len = end - start
            precondition(len > 0)
            if len <= 3 {
                out.append(UInt8(17 + len))
                out.append(contentsOf: src[start..<end])
                return len
            } else if len <= 238 {
                out.append(UInt8(17 + len))
                out.append(contentsOf: src[start..<end])
                return 4
            } else {
                emitLongLiteral(start: start, end: end)
                return 4
            }
        }

        func emitM1State4(distance: Int, state: Int) {
            let d = distance - 2049
            out.append(UInt8(((d & 0x3) << 2) | state))
            out.append(UInt8((d >> 2) & 0xff))
        }

        func emitM2(length: Int, distance: Int, state: Int) {
            let d = distance - 1
            let dLow3 = (d & 0x7) << 2
            let high = UInt8((d >> 3) & 0xff)
            if length <= 4 {
                out.append(UInt8(0x40 | ((length - 3) << 5) | dLow3 | state))
            } else {
                out.append(UInt8(0x80 | ((length - 5) << 5) | dLow3 | state))
            }
            out.append(high)
        }

        func emitM3(length: Int, distance: Int, state: Int) {
            if length <= 33 {
                out.append(UInt8(0x20 | (length - 2)))
            } else {
                out.append(0x20)
                appendLengthExtension(length - 33)
            }
            appendLE16(((distance - 1) << 2) | state)
        }

        func emitMatch(length: Int, distance: Int, state: Int, previousState: Int) {
            if previousState == 4 && length == 3 && (2049...3072).contains(distance) {
                emitM1State4(distance: distance, state: state)
            } else if length <= 8 && distance <= 2048 {
                emitM2(length: length, distance: distance, state: state)
            } else {
                // 入力は高々数KBなので distance は常に 16384 以下。
                emitM3(length: length, distance: distance, state: state)
            }
        }

        let maxDistance = 16_384
        let maxMatchLen = 512
        var lastPos = [Int](repeating: -1, count: 1 << 16)
        var matches: [Match] = []
        var i = 0
        while i + 2 < n {
            let h = hash3(src[i], src[i + 1], src[i + 2])
            let cand = lastPos[h]
            lastPos[h] = i

            var bestLen = 0
            var bestDist = 0
            if cand >= 0 {
                let dist = i - cand
                if dist <= maxDistance,
                   src[cand] == src[i], src[cand + 1] == src[i + 1], src[cand + 2] == src[i + 2] {
                    let maxLen = min(maxMatchLen, n - i)
                    var len = 3
                    while len < maxLen && src[cand + len] == src[i + len] {
                        len += 1
                    }
                    let minUsefulLen = (dist <= 2048) ? 3 : 4
                    if len >= minUsefulLen {
                        bestLen = len
                        bestDist = dist
                    }
                }
            }

            if bestLen > 0 {
                matches.append(Match(start: i, length: bestLen, distance: bestDist))
                var k = 1
                while k < bestLen && i + k + 2 < n {
                    lastPos[hash3(src[i + k], src[i + k + 1], src[i + k + 2])] = i + k
                    k += 1
                }
                i += bestLen
            } else {
                i += 1
            }
        }

        if matches.isEmpty {
            _ = emitFirstLiteral(start: 0, end: n)
            out.append(contentsOf: endOfStream)
            return Data(out)
        }

        var state = emitFirstLiteral(start: 0, end: matches[0].start)

        for idx in matches.indices {
            let m = matches[idx]
            let matchEnd = m.start + m.length
            let nextStart = (idx + 1 < matches.count) ? matches[idx + 1].start : n
            let gap = nextStart - matchEnd

            if gap <= 3 {
                emitMatch(length: m.length, distance: m.distance, state: gap, previousState: state)
                if gap > 0 {
                    out.append(contentsOf: src[matchEnd..<(matchEnd + gap)])
                }
                state = gap
            } else {
                emitMatch(length: m.length, distance: m.distance, state: 0, previousState: state)
                emitLongLiteral(start: matchEnd, end: nextStart)
                state = 4
            }
        }

        out.append(contentsOf: endOfStream)
        return Data(out)
    }

    enum DecodeError: Error {
        case truncated
        case invalidDistance
        case missingEndMarker
    }

    /// LZO1X 展開。送信前の自己検証（圧縮→展開で元に戻ること）に使う。
    static func decompress(_ data: Data) throws -> Data {
        let src = [UInt8](data)
        var out = [UInt8]()
        var ip = 0

        func byte() throws -> Int {
            guard ip < src.count else { throw DecodeError.truncated }
            defer { ip += 1 }
            return Int(src[ip])
        }
        func lengthExtension(base: Int) throws -> Int {
            var len = base
            while true {
                let b = try byte()
                if b == 0 {
                    len += 255
                } else {
                    return len + b
                }
            }
        }
        func copyLiteral(_ count: Int) throws {
            guard ip + count <= src.count else { throw DecodeError.truncated }
            out.append(contentsOf: src[ip..<ip + count])
            ip += count
        }
        func copyMatch(distance: Int, length: Int) throws {
            guard distance >= 1, distance <= out.count else { throw DecodeError.invalidDistance }
            var from = out.count - distance
            for _ in 0..<length {
                out.append(out[from])
                from += 1
            }
        }

        // state: 直前の命令が残したリテラル数 (0...3)。4 は「長いリテラルの直後」。
        var state = 0
        let first = try byte()
        if first > 17 {
            let count = first - 17
            try copyLiteral(count)
            state = count <= 3 ? count : 4
        } else {
            ip = 0
        }

        while true {
            let t = try byte()
            var trailing = 0
            if t >= 64 {
                let length: Int
                let dLow: Int
                if t >= 128 {
                    length = 5 + ((t >> 5) & 0x3)
                } else {
                    length = 3 + ((t >> 5) & 0x1)
                }
                dLow = (t >> 2) & 0x7
                let h = try byte()
                try copyMatch(distance: (h << 3) + dLow + 1, length: length)
                trailing = t & 0x3
            } else if t >= 32 {
                var length = (t & 0x1f) + 2
                if length == 2 {
                    length = try lengthExtension(base: 31) + 2
                }
                let lo = try byte()
                let hi = try byte()
                let packed = (hi << 8) | lo
                try copyMatch(distance: (packed >> 2) + 1, length: length)
                trailing = packed & 0x3
            } else if t >= 16 {
                var length = (t & 0x7) + 2
                if length == 2 {
                    length = try lengthExtension(base: 7) + 2
                }
                let lo = try byte()
                let hi = try byte()
                let packed = (hi << 8) | lo
                let distance = 16384 + ((t & 0x8) << 11) + (packed >> 2)
                if distance == 16384 {
                    // 終端マーカー (0x11 0x00 0x00)
                    guard length == 3 else { throw DecodeError.missingEndMarker }
                    return Data(out)
                }
                try copyMatch(distance: distance, length: length)
                trailing = packed & 0x3
            } else {
                if state == 0 {
                    var count = t + 3
                    if t == 0 {
                        count = try lengthExtension(base: 15) + 3
                    }
                    try copyLiteral(count)
                    state = 4
                    continue
                }
                let h = try byte()
                if state == 4 {
                    try copyMatch(distance: (h << 2) + (t >> 2) + 2049, length: 3)
                } else {
                    try copyMatch(distance: (h << 2) + (t >> 2) + 1, length: 2)
                }
                trailing = t & 0x3
            }
            try copyLiteral(trailing)
            state = trailing
        }
    }
}
