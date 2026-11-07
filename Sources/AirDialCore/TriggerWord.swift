import Foundation

/// Finds the agent trigger word in a dictated sentence ("AGI, open my calendar", "a.g.i. 打开日历")
/// and returns the command without it. The word must stand alone ("magic" doesn't count).
public enum TriggerWord {
    public static func command(in text: String, word: String = "AGI") -> String? {
        let letters = word.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s.]?")
        guard let re = try? NSRegularExpression(pattern: "(?i)(?<![A-Za-z])\(letters)\\.?(?![A-Za-z])") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard re.firstMatch(in: text, range: range) != nil else { return nil }
        let stripped = re.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        let cleaned = stripped.trimmingCharacters(in: CharacterSet(charactersIn: " ,.，。:：!！?？-\n\t"))
        return cleaned.isEmpty ? nil : cleaned
    }
}
