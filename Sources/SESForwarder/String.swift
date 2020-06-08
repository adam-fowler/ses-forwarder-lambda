
// String extensions to help parsing email
extension StringProtocol {
    func enumerateLines(separator: String = "\r\n", _ body: (SubSequence) -> Bool) {
        var index = self.startIndex
        var separatorIndex = separator.startIndex
        var lineStart = self.startIndex
        var lineEnd = self.startIndex
        
        while index != self.endIndex {
            if self[index] == separator[separatorIndex] {
                if separatorIndex == separator.startIndex {
                    lineEnd = index
                }
                separatorIndex = separator.index(after: separatorIndex)
                if separatorIndex == separator.endIndex {
                    if !body(self[lineStart..<lineEnd]) {
                        return
                    }
                    lineStart = self.index(after: index)
                    separatorIndex = separator.startIndex
                }
            } else {
                separatorIndex = separator.startIndex
            }
            index = self.index(after: index)
        }
        
        if lineStart != self.endIndex {
            _ = body(self[lineStart..<self.endIndex])
        }
    }
    
    func headerField() -> SubSequence {
        let colon = self.firstIndex(of: ":") ?? self.endIndex
        return self[self.startIndex..<colon]
    }
    
    func headerFieldBody() -> SubSequence? {
        guard let colon = self.firstIndex(of: ":") else { return nil }
        let fieldStart = self.index(after: colon)
        return self[fieldStart..<self.endIndex]
    }
}
