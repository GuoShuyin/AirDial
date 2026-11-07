import Testing
@testable import AirDialCore

struct TriggerWordTests {
    @Test func testFindsTheTriggerAndStripsIt() {
        #expect(TriggerWord.command(in: "AGI, open tomorrow in my calendar.") == "open tomorrow in my calendar")
        #expect(TriggerWord.command(in: "agi open Safari") == "open Safari")
        #expect(TriggerWord.command(in: "A.G.I. 打开日历") == "打开日历")
        #expect(TriggerWord.command(in: "please, A G I, close this window") == "please, , close this window")
        #expect(TriggerWord.command(in: "AGI，帮我把这个窗口关掉。") == "帮我把这个窗口关掉")
    }

    @Test func testIgnoresOrdinaryText() {
        #expect(TriggerWord.command(in: "That was magic, honestly") == nil)
        #expect(TriggerWord.command(in: "Send the agile report") == nil)
        #expect(TriggerWord.command(in: "AGI") == nil)          // nothing to do
        #expect(TriggerWord.command(in: "hello world") == nil)
    }

    @Test func testCustomWord() {
        #expect(TriggerWord.command(in: "Jarvis open Mail", word: "Jarvis") == "open Mail")
    }
}
