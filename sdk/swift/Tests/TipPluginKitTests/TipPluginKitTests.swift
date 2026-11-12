import Foundation
import Testing
@testable import TipPluginKit

@Suite struct TipPluginKitTests {
    @Test func itemEncodesOnlyWhatIsSet() throws {
        let item = Item("btc").icon("sf:bitcoinsign", color: "chart3").label("$1").push(0.5)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let json = String(decoding: try enc.encode(item), as: UTF8.self)
        #expect(json == #"{"graph":{"push":0.5},"icon":"sf:bitcoinsign","iconColor":"chart3","id":"btc","label":"$1"}"#)
    }

    @Test func thousands() {
        #expect(Fmt.thousands(98412.3) == "98,412")
        #expect(Fmt.thousands(1.5, decimals: 2) == "1.50")
    }

    @Test func setLine() throws {
        let pipe = Pipe()
        let tip = Tip(out: pipe.fileHandleForWriting)
        tip.set(Item("x").label("hi"))
        try pipe.fileHandleForWriting.close()
        let line = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(line.contains(#""method":"set""#))
        #expect(line.contains(#""label":"hi""#))
        #expect(line.hasSuffix("\n"))
    }
}
