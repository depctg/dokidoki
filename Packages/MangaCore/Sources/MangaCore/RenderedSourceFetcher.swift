import Foundation
import WebKit

/// Persistent, hidden browser sessions. Session state never enters content snapshots.
public struct RenderedSourceFetcher: SourceFetcher {
    private let ordinary: DefaultSourceFetcher
    private let sessions = RenderedSessionManager()
    public init(client: HTTPClient = HTTPClient()) { ordinary = DefaultSourceFetcher(client: client) }
    public func fetch(_ url: URL, rule: SiteRule, kind: ContentKind, backgroundLoading: Bool) async throws -> SourceResponse {
        try await fetch(url, rule: rule, kind: kind, backgroundLoading: backgroundLoading, load: SourceLoad())
    }
    public func fetch(_ url: URL, rule: SiteRule, kind: ContentKind, backgroundLoading: Bool, load: SourceLoad) async throws -> SourceResponse {
        guard let extraction = rule.extraction(for: kind, at: url), extraction.format.isRendered else {
            return try await ordinary.fetch(url, rule: rule, kind: kind, backgroundLoading: backgroundLoading)
        }
        return try await sessions.read(url, rule: rule, kind: kind, extraction: extraction, backgroundLoading: backgroundLoading, load: load)
    }
    public func cachedResource(_ url: URL, rule: SiteRule, owner: URL?, referer: URL?) async -> SourceResponse? {
        await sessions.resource(url, rule: rule, owner: owner, referer: referer)
    }
    public func invalidate() async { await sessions.close() }
}

/// The sender admits one rendered operation at a time. Keep up to four logical
/// contexts so a cover/metadata visit does not destroy a chapter's scroll position.
@MainActor private final class RenderedSessionManager {
    private struct Identity: Hashable { let url: URL; let policy: Data; let extraction: Data; let background: Bool }
    private struct Entry {
        let session: WebPageSession
        var used = ContinuousClock.now
        var expiry: Task<Void, Never>?
    }
    private var entries: [Identity: Entry] = [:]
    private var generation = 0
    nonisolated init() {}
    private func remove(_ identity: Identity) {
        guard let entry = entries.removeValue(forKey: identity) else { return }
        entry.expiry?.cancel(); entry.session.close()
    }
    func close() {
        generation += 1
        for identity in Array(entries.keys) { remove(identity) }
    }
    func read(_ url: URL, rule: SiteRule, kind: ContentKind, extraction: ExtractionRule, backgroundLoading: Bool, load: SourceLoad) async throws -> SourceResponse {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = Identity(url: load.sessionURL ?? url, policy: try rule.exported(), extraction: try encoder.encode(extraction), background: backgroundLoading)
        let epoch = generation
        if load.refresh { remove(identity) }
        entries[identity]?.expiry?.cancel()
        do {
            if entries[identity] == nil {
                if entries.count >= 4, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key { remove(oldest) }
                let session = try await WebPageSession.create(rule: rule, extraction: extraction, backgroundLoading: backgroundLoading)
                guard !Task.isCancelled, epoch == generation else { session.close(); throw CancellationError() }
                entries[identity] = Entry(session: session)
            }
            guard let session = entries[identity]?.session else { throw CancellationError() }
            let result = try await session.read(url, kind: kind, extraction: extraction, load: load)
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            entries[identity]?.used = .now
            entries[identity]?.expiry = Task { [weak self, weak session] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.entries[identity]?.session === session else { return }; self.remove(identity)
            }
            return result
        } catch { remove(identity); throw error }
    }
    func resource(_ url: URL, rule: SiteRule, owner: URL?, referer: URL?) async -> SourceResponse? {
        guard rule.permits(url), let policy = try? rule.exported(),
              let entry = entries.filter({ $0.key.url == owner && $0.key.policy == policy && $0.value.session.url == referer })
                .max(by: { $0.value.used < $1.value.used })?.value else { return nil }
        return await entry.session.resource(url)
    }
}

@MainActor private final class WebPageSession: NSObject, WKNavigationDelegate {
    private var failure: Error?
    private let rule: SiteRule
    private let view: WKWebView
    private let filterID: String?
    private var requestedURL: URL?
    private var committed = false
    private var closed = false
    var url: URL? { view.url }
    private init(rule: SiteRule, view: WKWebView, filterID: String?) {
        self.rule = rule; self.view = view; self.filterID = filterID
        super.init(); view.navigationDelegate = self
    }
    static func create(rule: SiteRule, extraction: ExtractionRule, backgroundLoading: Bool) async throws -> WebPageSession {
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
        if !backgroundLoading || extraction.rendering?.loadAds == false {
            filters.append(["trigger": ["url-filter": ".*", "resource-type": ["image", "media", "font"]], "action": ["type": "block"]])
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: filters), as: UTF8.self)
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "reader-" + UUID().uuidString, encodedContentRuleList: json)
        if let list { controller.add(list) }
        if extraction.format == .renderedJSON, let rendering = extraction.rendering {
            let options = String(decoding: try JSONEncoder().encode(rendering), as: UTF8.self)
            controller.addUserScript(WKUserScript(source: captureScript.replacingOccurrences(of: "__OPTIONS__", with: options), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        return WebPageSession(rule: rule, view: view, filterID: list?.identifier)
    }
    func close() {
        closed = true
        view.stopLoading(); view.navigationDelegate = nil
        if let filterID { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: filterID) { _ in } }
        // Release the loaded document and its script timers as well as ongoing resources.
        view.loadHTMLString("", baseURL: nil)
    }
    private func matches(_ xpath: String) async -> Bool {
        (try? await view.callAsyncJavaScript("return !!document.evaluate(xpath,document,null,XPathResult.FIRST_ORDERED_NODE_TYPE,null).singleNodeValue;", arguments: ["xpath": xpath], in: nil, contentWorld: .page) as? Bool) == true
    }
    func read(_ url: URL, kind: ContentKind, extraction: ExtractionRule, load: SourceLoad, restarted: Bool = false) async throws -> SourceResponse {
        guard rule.permits(url) else { throw ReaderError.blockedHost }
        if requestedURL != url || load.refresh {
            failure = nil; requestedURL = url; committed = false
            if let fixture = try DemoContent.response(for: url) {
                view.loadSimulatedRequest(URLRequest(url: url), responseHTML: String(decoding: fixture.data, as: UTF8.self))
            } else { view.load(URLRequest(url: url)) }
        }
        let deadline = ContinuousClock.now + .seconds(30)
        var lastItems: [String] = [], actions = 0, waitingUntil: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if let failure { throw failure }
            let ready: Bool
            if !committed { ready = false }
            else if let xpath = extraction.rendering?.readyXPath { ready = await matches(xpath) }
            else { ready = !view.isLoading && view.url != nil }
            if ready {
                let text: String?
                if extraction.format == .renderedJSON {
                    text = try? await view.evaluateJavaScript("window.__readerSnapshot ? JSON.stringify(window.__readerSnapshot()) : null") as? String
                } else { text = try? await view.evaluateJavaScript("document.documentElement.outerHTML") as? String }
                if let text, !text.isEmpty, text != "null" {
                    guard let finalURL = view.url, rule.permits(finalURL) else { throw ReaderError.invalidResponse }
                    let needsItems = load.range != nil && extraction.session.map { $0.mode != .load } == true
                    let (response, objects) = try await Self.snapshot(text, url: finalURL,
                        key: ObjectKey(ruleID: rule.id, identityURL: url), kind: kind, rule: rule, extract: needsItems)
                    guard !closed else { throw CancellationError() }
                    if let failure { throw failure }
                    guard let range = load.range, let strategy = extraction.session, strategy.mode != .load else { return response }
                    let items: [String]
                    let satisfied: Bool
                    if case .chapter(let chapter) = objects.first {
                        let pages = objects.compactMap { object -> PageObject? in if case .page(let page) = object { return page }; return nil }
                        let indices = Set(pages.compactMap(\.sourceIndex))
                        items = pages.map { "\($0.sourceIndex ?? 0)|\($0.imageURL?.absoluteString ?? "")" }
                        satisfied = range.clamped(to: 0..<chapter.pageRefs.count).allSatisfy(indices.contains)
                        // A sequential next control cannot seek backward. Restart the
                        // same session document and replay normal actions when necessary.
                        if !satisfied, !restarted, actions == 0, strategy.mode == .page,
                           strategy.actionXPath?.contains("{index}") != true,
                           let first = indices.min(), first > range.lowerBound {
                            requestedURL = nil
                            return try await read(url, kind: kind, extraction: extraction, load: load, restarted: true)
                        }
                    } else if case .directory(let directory) = objects.first {
                        items = directory.mangaRefs.map { $0.key.id }
                        // A page action replaces the DOM. Return each changed batch;
                        // the repository assembles it with previously cached items.
                        satisfied = directory.hasMore == false || (strategy.mode == .scroll ? items.count >= range.upperBound :
                            directory.mangaRefs.contains { !load.knownItems.contains($0.key) })
                    } else { return response }
                    if satisfied { return response }
                    if let end = strategy.endXPath, await matches(end) { return response }
                    if items != lastItems { lastItems = items; waitingUntil = nil }
                    if waitingUntil == nil {
                        guard actions < 1_000, let target = strategy.actionXPath else { throw ReaderError.invalidResponse }
                        try await act(strategy.mode, xpath: target.replacingOccurrences(of: "{index}", with: String(range.lowerBound + 1)))
                        actions += 1; waitingUntil = .now + .seconds(5)
                    } else if ContinuousClock.now >= waitingUntil! {
                        throw ReaderError.extraction(String(localized: "The source did not advance to the requested items. Retry or refresh.", bundle: .module))
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ReaderError.extraction(String(localized: "The website did not expose readable pages within 30 seconds. It may require interaction or restrict this chapter. Try another chapter or open the source website.", bundle: .module))
    }
    private func act(_ mode: SessionRule.Mode, xpath: String) async throws {
        let performed = try await view.callAsyncJavaScript("""
        const element = document.evaluate(xpath,document,null,XPathResult.FIRST_ORDERED_NODE_TYPE,null).singleNodeValue;
        if (!element) return false;
        if (mode === 'page') {
          if (element.tagName === 'OPTION') {
            const select = element.parentElement; select.value = element.value;
            select.dispatchEvent(new Event('change', {bubbles:true}));
          } else element.click();
        } else {
          element.scrollIntoView({block:'end',behavior:'instant'});
          // Hidden WebKit views may suspend animation-frame delivery. A scroll
          // action must also notify listeners when the target is already visible.
          window.dispatchEvent(new Event('scroll'));
        }
        return true;
        """, arguments: ["xpath": xpath, "mode": mode.rawValue], in: nil, contentWorld: .page) as? Bool
        guard performed == true else { throw ReaderError.invalidResponse }
    }
    /// Passive pixels from an image the browser has already decoded. A tainted canvas,
    /// absent image or size limit is a cache miss. Never fetch/reload inside this lookup.
    func resource(_ url: URL) async -> SourceResponse? {
        guard !closed else { return nil }
        let encoded = try? await view.callAsyncJavaScript("""
        const image = Array.from(document.images).find(i => i.currentSrc === url && i.complete && i.naturalWidth > 0);
        if (!image || image.naturalWidth * image.naturalHeight > 16000000) return null;
        try {
          const canvas = document.createElement('canvas');
          canvas.width = image.naturalWidth; canvas.height = image.naturalHeight;
          canvas.getContext('2d').drawImage(image,0,0);
          const data = canvas.toDataURL('image/png');
          return data.length <= 33554432 ? data.substring(data.indexOf(',')+1) : null;
        } catch (_) { return null; }
        """, arguments: ["url": url.absoluteString], in: nil, contentWorld: .page) as? String
        guard let encoded else { return nil }
        let response = await Self.decodedResource(encoded, url: url)
        return closed || Task.isCancelled ? nil : response
    }
    // WebKit requires MainActor; snapshot parsing and resource decoding do not.
    // Explicit concurrent functions retain task cancellation without detached jobs.
    @concurrent nonisolated private static func snapshot(_ text: String, url: URL, key: ObjectKey,
        kind: ContentKind, rule: SiteRule, extract: Bool) async throws -> (SourceResponse, [ContentObject]) {
        try Task.checkCancellation()
        guard text.utf8.count <= 8 * 1024 * 1024 else { throw ReaderError.invalidResponse }
        let response = SourceResponse(data: Data(text.utf8), url: url)
        let objects = extract ? try RuleExtractor().extract(data: response.data, responseURL: url, key: key, kind: kind, rule: rule) : []
        try Task.checkCancellation()
        return (response, objects)
    }
    @concurrent nonisolated private static func decodedResource(_ encoded: String, url: URL) async -> SourceResponse? {
        guard !Task.isCancelled, let data = Data(base64Encoded: encoded), data.count <= 24 * 1024 * 1024 else { return nil }
        return SourceResponse(data: data, url: url)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, rule.permits(url) else {
            if navigationAction.targetFrame?.isMainFrame == true { failure = ReaderError.blockedHost }
            return .cancel
        }
        return .allow
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = failure ?? error }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = failure ?? error }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committed = true }

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
