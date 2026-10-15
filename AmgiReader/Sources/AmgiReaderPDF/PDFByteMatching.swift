extension Array where Element == UInt8 {
    /// Whether `needle` occurs at `index`, without allocating.
    ///
    /// The scanners test a keyword at every byte of a file. Spelled as
    /// `Array(bytes[i..<i+n]) == needle`, each test built a fresh array — one
    /// allocation per byte, several passes per file — which made importing a
    /// 12 MB PDF take seconds. Same answer, compared in place.
    @inline(__always)
    func hasBytes(_ needle: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index + needle.count <= count else { return false }
        for offset in 0..<needle.count where self[index + offset] != needle[offset] {
            return false
        }
        return true
    }
}
