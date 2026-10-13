import Foundation
import WebKit

/// Executes the website's own page in an ephemeral WebKit view.
/// Rules select DOM extraction or an observed function argument; imported rules supply no code.
public struct RenderedSourceFetcher: SourceFetcher {
    private let ordinary: DefaultSourceFetcher
    public init(client: HTTPClient = HTTPClient()) { ordinary = DefaultSourceFetcher(client: client) }
    public func fetch(_ url: URL, rule: SiteRule, kind: ContentKind, backgroundLoading: Bool) async throws -> SourceResponse {
        guard let extraction = rule.extraction(for: kind, at: url), extraction.format.isRendered else { return try await ordinary.fetch(url, rule: rule, kind: kind, backgroundLoading: backgroundLoading) }
        return try await WebPageSession.read(url, rule: rule, extraction: extraction, backgroundLoading: backgroundLoading)
    }
}

@MainActor private final class WebPageSession: NSObject, WKNavigationDelegate {
    private var failure: Error?
    private let rule: SiteRule
    private init(rule: SiteRule) { self.rule = rule }

    static func read(_ url: URL, rule: SiteRule, extraction: ExtractionRule, backgroundLoading: Bool) async throws -> SourceResponse {
        guard rule.permits(url) else { throw ReaderError.blockedHost }
        let session = WebPageSession(rule: rule)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        switch extraction.rendering?.contentMode ?? .recommended {
        case .recommended: configuration.defaultWebpagePreferences.preferredContentMode = .recommended
        case .desktop: configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        case .mobile: configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        }
        let controller = configuration.userContentController
        var filters: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        for host in rule.allowedHosts {
            filters.append(["trigger": ["url-filter": "^https?://" + NSRegularExpression.escapedPattern(for: host) + "/"], "action": ["type": "ignore-previous-rules"]])
        }
        // Default normal resource loading keeps site load handlers working. The metadata
        // view is never presented; parsed PageObjects still use the shared native image cache.
        if !backgroundLoading || extraction.rendering?.loadAds == false {
            filters.append(["trigger": ["url-filter": ".*", "resource-type": ["image", "media", "font"]], "action": ["type": "block"]])
        }
        let filterJSON = String(decoding: try JSONSerialization.data(withJSONObject: filters), as: UTF8.self)
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "reader-" + UUID().uuidString, encodedContentRuleList: filterJSON)
        if let list { controller.add(list) }
        if extraction.format == .renderedJSON, let rendering = extraction.rendering {
            let options = String(decoding: try JSONEncoder().encode(rendering), as: UTF8.self)
            let script = captureScript.replacingOccurrences(of: "__OPTIONS__", with: options)
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
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
            let ready: Bool
            if let xpath = extraction.rendering?.readyXPath {
                ready = (try? await view.callAsyncJavaScript(
                    "return !!document.evaluate(xpath, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;",
                    arguments: ["xpath": xpath], in: nil, contentWorld: .page) as? Bool) == true
            } else { ready = !view.isLoading }
            if extraction.format == .renderedJSON, extraction.rendering?.readyXPath == nil || ready {
                if let html = try? await view.evaluateJavaScript("window.__readerSnapshot ? JSON.stringify(window.__readerSnapshot()) : null") as? String, !html.isEmpty, html != "null" {
                    guard html.utf8.count <= 8 * 1024 * 1024 else { throw ReaderError.tooLarge }
                    return SourceResponse(data: Data(html.utf8), url: view.url ?? url)
                }
            } else if extraction.format == .renderedHTML, ready,
                      let html = try? await view.evaluateJavaScript("document.documentElement.outerHTML") as? String, !html.isEmpty {
                guard html.utf8.count <= 8 * 1024 * 1024 else { throw ReaderError.tooLarge }
                return SourceResponse(data: Data(html.utf8), url: view.url ?? url)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ReaderError.extraction(String(localized: "The website did not expose readable pages within 30 seconds. It may require interaction or restrict this chapter. Try another chapter or open the source website.", bundle: .module))
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

    // Observe a normal call without invoking the function or changing its result.
    // Only publish it after the site creates the image selected by the rule's readiness XPath.
    private static let captureScript = """
    (() => {
      const options = __OPTIONS__;
      let captured, imageURL;
      function observeImage() {
        const image = document.evaluate(options.readyImageXPath, document, null,
          XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
        if (image && image.tagName === 'IMG' && image.getAttribute('src')) imageURL = image.src;
      }
      new MutationObserver(observeImage).observe(document,
        {subtree: true, childList: true, attributes: true, attributeFilter: ['src']});
      const observed = new WeakMap();
      function watch(object, parts) {
        if (!object || !['object', 'function'].includes(typeof object)) return;
        const key = parts[0], descriptor = Object.getOwnPropertyDescriptor(object, key);
        if (descriptor && (!descriptor.configurable || descriptor.get || descriptor.set)) return;
        let names = observed.get(object);
        if (!names) observed.set(object, names = new Set());
        if (names.has(key)) return;
        names.add(key);
        function prepare(value) {
          if (parts.length > 1) { watch(value, parts.slice(1)); return value; }
          if (typeof value !== 'function') return value;
          return function() {
            const result = Reflect.apply(value, this, arguments);
            captured = options.captureResult ? result : arguments[0];
            return result;
          };
        }
        let value = prepare(object[key]);
        Object.defineProperty(object, key, {
          configurable: true, enumerable: descriptor ? descriptor.enumerable : true,
          get() { return value; }, set(next) { value = prepare(next); }
        });
      }
      watch(window, options.captureFunction.split('.'));
      window.__readerSnapshot = () => {
        observeImage();
        return imageURL && captured ? {data: captured, imageURL, title: document.title, url: location.href} : null;
      };
    })();
    """
}
