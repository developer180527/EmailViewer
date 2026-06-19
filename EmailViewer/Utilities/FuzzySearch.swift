import Foundation

/// Lightweight fuzzy matcher. A query matches if its characters appear in order
/// (as a subsequence) within the text. The score rewards consecutive matches and
/// matches at word boundaries, so "ghub" ranks "GitHub" above incidental hits.
enum FuzzySearch {

    /// Returns a score (higher is better) if `query` fuzzy-matches `text`, else nil.
    static func score(query: String, in text: String) -> Int? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        guard q.count <= t.count else { return nil }

        var score = 0
        var ti = 0
        var qi = 0
        var previousMatched = false

        while qi < q.count && ti < t.count {
            if q[qi] == t[ti] {
                score += 1
                if previousMatched { score += 5 }                       // consecutive run
                if ti == 0 || isBoundary(t[ti - 1]) { score += 10 }     // start of a word
                previousMatched = true
                qi += 1
            } else {
                previousMatched = false
            }
            ti += 1
        }

        return qi == q.count ? score : nil
    }

    /// Best score across several fields (e.g. sender, subject, snippet).
    static func bestScore(query: String, in fields: [String]) -> Int? {
        fields.compactMap { score(query: query, in: $0) }.max()
    }

    private static func isBoundary(_ c: Character) -> Bool {
        c == " " || c == "." || c == "-" || c == "_" || c == "@" || c == "<" || c == "/"
    }
}
