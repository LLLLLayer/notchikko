import AppKit
import WebKit

final class NotchikkoView: NSView {
    private let webView: WKWebView
    private var currentSVG: String = ""
    private var hasLoadedInitialHTML = false

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)

        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 通过状态加载 SVG（经 ThemeProvider 解析主题）
    func loadSVG(for state: NotchikkoState) {
        let key = state.rawValue
        guard key != currentSVG else { return }
        // 状态变化时清除旧状态的缓存，下次进入时重新随机
        if let oldState = NotchikkoState(rawValue: currentSVG) {
            ThemeProvider.shared.clearCache(for: oldState)
        }
        currentSVG = key

        guard let url = ThemeProvider.shared.svgURL(for: state) else {
            Log("SVG not found for state: \(state)", tag: "View")
            return
        }

        // 自定义主题 SVG 限制 1MB，防止恶意/巨型文件打爆内存
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 1_000_000 {
            Log("SVG too large (\(size) bytes), skipping: \(url.lastPathComponent)", tag: "View")
            return
        }
        guard var svgContent = try? String(contentsOf: url, encoding: .utf8) else { return }

        // 外部主题 SVG 安全清洗（内置主题信任跳过）
        if PreferencesStore.shared.preferences.themeId != ThemeProvider.builtinThemeId {
            svgContent = SVGSanitizer.sanitize(svgContent)
        }

        // 已加载过 HTML → 用 JS 注入新 SVG 并做 crossfade
        if hasLoadedInitialHTML {
            let escaped = svgContent
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            // 快速连续切换时，先清除所有残留的过渡层，只保留最新的
            let js = """
            (function() {
                var layers = document.querySelectorAll('.svg-layer');
                var next = document.createElement('div');
                next.id = 'svg-current';
                next.className = 'svg-layer';
                next.style.opacity = '0';
                next.innerHTML = `\(escaped)`;
                document.body.appendChild(next);
                requestAnimationFrame(function() {
                    for (var i = 0; i < layers.length; i++) {
                        layers[i].style.opacity = '0';
                    }
                    next.style.opacity = '1';
                    setTimeout(function() {
                        for (var i = 0; i < layers.length; i++) {
                            layers[i].remove();
                        }
                    }, 350);
                });
            })();
            """
            webView.evaluateJavaScript(js) { _, error in
                if let error { Log("SVG inject JS error: \(error.localizedDescription)", tag: "View") }
            }
            return
        }

        // 首次加载：用完整 HTML 初始化页面结构
        hasLoadedInitialHTML = true
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <style>
            * { margin: 0; padding: 0; }
            html, body {
                width: 100%;
                height: 100%;
                background: transparent;
                overflow: hidden;
            }
            .svg-layer {
                position: absolute;
                inset: 0;
                transition: opacity 0.3s ease;
            }
            svg {
                width: 100%;
                height: 100%;
                image-rendering: pixelated;
            }
        </style>
        </head>
        <body>
            <div id="svg-current" class="svg-layer">\(svgContent)</div>
        </body>
        </html>
        """

        webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
    }

    /// 眼球追踪
    func updateEyePosition(dx: CGFloat, dy: CGFloat) {
        let js = """
        (function() {
            var eyes = document.getElementById('eyes-js');
            if (eyes) eyes.setAttribute('transform', 'translate(\(dx), \(dy))');
            var body = document.getElementById('body-js');
            if (body) body.setAttribute('transform', 'translate(\(dx * 0.3), \(dy * 0.3))');
        })();
        """
        webView.evaluateJavaScript(js)
    }
}
