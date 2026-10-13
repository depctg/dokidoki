import Foundation
import WebKit

/// Executes the website's own page in an ephemeral WebKit view. Imported rules supply no code.
/// The site-specific bridge observes publicly rendered chapter data; gates must render an image first.
public struct RenderedSourceFetcher: SourceFetcher {
    private let ordinary: DefaultSourceFetcher
    public init(client: HTTPClient = HTTPClient()) { ordinary = DefaultSourceFetcher(client: client) }
    public func fetch(_ url: URL, rule: SiteRule, kind: ContentKind) async throws -> SourceResponse {
        guard rule.extractors[kind.rawValue]?.format == .renderedHTML else { return try await ordinary.fetch(url, rule: rule, kind: kind) }
        return try await WebPageSession.read(url, rule: rule)
    }
}

@MainActor private final class WebPageSession: NSObject, WKNavigationDelegate {
    private var failure: Error?
    private let rule: SiteRule
    private init(rule: SiteRule) { self.rule = rule }

    static func read(_ url: URL, rule: SiteRule) async throws -> SourceResponse {
        guard rule.permits(url) else { throw ReaderError.blockedHost }
        let session = WebPageSession(rule: rule)
        let isManhuagui = url.host == "www.manhuagui.com"
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // This adapter observes the desktop reader. Mobile requests redirect to a different
        // site/DOM, outside this rule's hosts. Ask WebKit for desktop content on every platform.
        if isManhuagui { configuration.defaultWebpagePreferences.preferredContentMode = .desktop }
        let controller = configuration.userContentController
        var filters: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        for host in rule.allowedHosts {
            filters.append(["trigger": ["url-filter": "^https?://" + NSRegularExpression.escapedPattern(for: host) + "/"], "action": ["type": "ignore-previous-rules"]])
        }
        // Images are loaded by the bounded native image loader, not by this metadata view.
        filters.append(["trigger": ["url-filter": ".*", "resource-type": ["image", "media", "font"]], "action": ["type": "block"]])
        let filterJSON = String(decoding: try JSONSerialization.data(withJSONObject: filters), as: UTF8.self)
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "reader-" + UUID().uuidString, encodedContentRuleList: filterJSON)
        if let list { controller.add(list) }
        if isManhuagui { controller.addUserScript(WKUserScript(source: captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        view.navigationDelegate = session
        defer {
            view.stopLoading(); view.navigationDelegate = nil
            if let list { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: list.identifier) { _ in } }
        }
        view.load(URLRequest(url: url))
        for _ in 0..<120 {
            try Task.checkCancellation()
            if let failure = session.failure { throw failure }
            if isManhuagui {
                if let html = try? await view.evaluateJavaScript(manhuaguiReadScript) as? String, !html.isEmpty {
                    guard html.utf8.count <= 8 * 1024 * 1024 else { throw ReaderError.tooLarge }
                    return SourceResponse(data: Data(html.utf8), url: view.url ?? url)
                }
            } else if !view.isLoading, let html = try? await view.evaluateJavaScript("document.documentElement.outerHTML") as? String, !html.isEmpty {
                guard html.utf8.count <= 8 * 1024 * 1024 else { throw ReaderError.tooLarge }
                return SourceResponse(data: Data(html.utf8), url: view.url ?? url)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ReaderError.extraction("The website did not expose readable pages within 30 seconds. It may require interaction or restrict this chapter. Try another chapter or open the source website.")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, rule.permits(url) else {
            if navigationAction.targetFrame?.isMainFrame == true { failure = ReaderError.blockedHost }
            return .cancel
        }
        return .allow
    }
    // Preserve an explicit host-policy error when WebKit subsequently reports cancellation.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = failure ?? error }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = failure ?? error }

    // Preserve the site's implementation and observe its argument. No unpacker, cookie manipulation,
    // or calls into gated reader functions. Readback requires its normal #mangaFile DOM element.
    private static let captureScript = """
    (() => {
      new MutationObserver(() => {
        const image = document.querySelector('#mangaFile');
        if (image && image.src) window.__readerRenderedSource = image.src;
      }).observe(document, {subtree: true, childList: true, attributes: true, attributeFilter: ['src']});
      let current;
      Object.defineProperty(window, 'SMH', {
        configurable: true,
        get() { return current; },
        set(value) {
          current = value;
          if (!value || value.__readerObserved) return;
          value.__readerObserved = true;
          let original = value.imgData;
          Object.defineProperty(value, 'imgData', {
            configurable: true,
            get() { return original; },
            set(fn) {
              original = function(data) {
                window.__readerChapter = data;
                return fn.apply(this, arguments);
              };
            }
          });
        }
      });
    })();
    """
    private static let manhuaguiReadScript = """
    (() => {
      const image = document.querySelector('#mangaFile');
      const source = (image && image.src) || window.__readerRenderedSource;
      const data = window.__readerChapter;
      if (!source || !data || !Array.isArray(data.files) || !data.files.length) return '';
      if (data.files.length > 600) return '';
      const first = new URL(source);
      const root = first.origin + data.path;
      const query = new URLSearchParams(data.sl || {}).toString();
      const html = document.implementation.createHTMLDocument(document.title);
      const parent = html.createElement('a');
      parent.setAttribute('data-reader-parent', '');
      parent.href = location.origin + location.pathname.replace(/[^/]+$/, '');
      html.body.append(parent);
      for (const file of data.files) {
        const node = html.createElement('img');
        node.setAttribute('data-reader-page', '');
        node.src = root + file + (query ? '?' + query : '');
        html.body.append(node);
      }
      return html.documentElement.outerHTML;
    })();
    """
}
