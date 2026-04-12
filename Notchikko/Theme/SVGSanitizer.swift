import Foundation

/// SVG 安全清洗器 — 移除外部主题 SVG 中的潜在恶意内容
enum SVGSanitizer {

    /// 危险的 HTML/SVG 标签（会执行代码）
    private static let dangerousTags: Set<String> = [
        "script", "iframe", "object", "embed", "applet",
        "form", "input", "textarea", "button",
        "meta", "link", "base",
    ]

    /// 危险的属性前缀（事件处理器）
    private static let dangerousAttrPrefixes = [
        "on",           // onclick, onload, onerror, onmouseover, etc.
    ]

    /// 危险的属性值模式
    private static let dangerousValuePatterns = [
        "javascript:",
        "data:text/html",
        "vbscript:",
    ]

    /// 清洗 SVG 内容，移除危险元素和属性
    /// 返回清洗后的 SVG 字符串
    static func sanitize(_ svgContent: String) -> String {
        var result = svgContent

        // 1. 移除危险标签及其内容
        for tag in dangerousTags {
            // 匹配 <script>...</script> 和 <script ... />
            let patterns = [
                "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",  // <tag>...</tag>
                "<\(tag)[^>]*/\\s*>",                  // <tag ... />
                "<\(tag)[^>]*>",                       // <tag ...> (unclosed)
            ]
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    result = regex.stringByReplacingMatches(
                        in: result,
                        range: NSRange(result.startIndex..., in: result),
                        withTemplate: ""
                    )
                }
            }
        }

        // 2. 移除事件处理器属性 (on*)
        if let onAttrRegex = try? NSRegularExpression(
            pattern: "\\s+on\\w+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|\\S+)",
            options: .caseInsensitive
        ) {
            result = onAttrRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // 3. 移除 javascript: / data:text/html URL
        for pattern in dangerousValuePatterns {
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
            if let regex = try? NSRegularExpression(
                pattern: "=\\s*[\"']\\s*\(escaped)[^\"']*[\"']",
                options: .caseInsensitive
            ) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "=\"\""
                )
            }
        }

        return result
    }

    /// 检查 SVG 是否包含潜在危险内容（不修改，仅检测）
    static func containsDangerousContent(_ svgContent: String) -> Bool {
        let lower = svgContent.lowercased()

        for tag in dangerousTags {
            if lower.contains("<\(tag)") { return true }
        }
        if lower.contains("on") {
            // 更精确：检查是否有 on{event}= 模式
            if let regex = try? NSRegularExpression(pattern: "\\son\\w+=", options: .caseInsensitive) {
                if regex.firstMatch(in: svgContent, range: NSRange(svgContent.startIndex..., in: svgContent)) != nil {
                    return true
                }
            }
        }
        for pattern in dangerousValuePatterns {
            if lower.contains(pattern) { return true }
        }

        return false
    }
}
