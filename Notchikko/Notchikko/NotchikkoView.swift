import AppKit
import WebKit

final class NotchikkoView: NSView {
    private let webView: WKWebView
    private var currentSVG: String = ""

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

    /// 加载 SVG — SVG 文件本身已经是最终朝向，代码不做任何翻转
    func loadSVG(named name: String) {
        guard name != currentSVG else { return }
        currentSVG = name

        guard let url = Bundle.main.url(forResource: name, withExtension: "svg") else {
            print("[NotchikkoView] SVG not found: \(name)")
            return
        }

        guard let svgContent = try? String(contentsOf: url, encoding: .utf8) else { return }

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
            svg {
                width: 100%;
                height: 100%;
                image-rendering: pixelated;
            }
        </style>
        </head>
        <body>\(svgContent)</body>
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
