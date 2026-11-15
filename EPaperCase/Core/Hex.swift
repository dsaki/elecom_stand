import Foundation

extension Data {
    /// "F0D3 00 01" のような16進文字列から生成する（空白は無視）。不正な文字列は nil。
    init?(hex: String) {
        let chars = Array(hex.filter { !$0.isWhitespace })
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        self.init(bytes)
    }

    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }
}

extension UInt16 {
    var hexString: String { String(format: "%04X", self) }
}
