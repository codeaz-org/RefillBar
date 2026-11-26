// UsageBar: a small floating window + menu bar item that shows your
// Claude, Amp and Grok usage pages in compact form and keeps them refreshed.
// Build with ./build.sh (needs Xcode Command Line Tools).

import Cocoa
import WebKit

// MARK: - The pages to show

struct Source {
    let name: String
    let url: () -> URL
}

/// A date as yyyy-MM-dd, `offset` days from today (used for Grok's rolling window).
func day(_ offset: Int) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    return f.string(from: date)
}

let sources: [Source] = [
    Source(name: "Claude") {
        URL(string: "https://claude.ai/new#settings/usage")!
    },
    Source(name: "Amp") {
        URL(string: "https://ampcode.com/settings/billing")!
    },
    Source(name: "Grok") {
        // Same 7-day window as your tab, but it rolls forward with the date.
        URL(string: "https://grok.com/dashboard/usage?granularity=hour&from=\(day(-6))&to=\(day(0))")!
    },
]

// A Safari user agent, so sign-in pages treat the embedded view like a normal browser.
let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

// Remembers where you scrolled on each page and puts you back there after every
// reload, so the progress bars stay in view.
let keepScrollJS = #"""
(function () {
  var KEY = 'usagebar-scroll:' + location.pathname + location.hash;
  var saved = {};
  try { saved = JSON.parse(localStorage.getItem(KEY) || '{}'); } catch (e) {}
  var restoring = true;

  function isRoot(el) {
    return el === document || el === document.documentElement ||
           el === document.body || el === document.scrollingElement;
  }
  function pathOf(el) {
    if (isRoot(el)) return 'win';
    var p = [];
    while (el && el !== document.body) {
      var parent = el.parentElement;
      if (!parent) return null;
      p.unshift(Array.prototype.indexOf.call(parent.children, el));
      el = parent;
    }
    return p.join('.');
  }
  function find(path) {
    if (path === 'win') return document.scrollingElement;
    var el = document.body;
    var parts = path.split('.');
    for (var i = 0; i < parts.length && el; i++) el = el.children[+parts[i]];
    return el;
  }

  addEventListener('scroll', function (e) {
    if (restoring) return;
    var p = pathOf(e.target);
    if (p == null) return;
    var el = p === 'win' ? document.scrollingElement : e.target;
    saved[p] = el.scrollTop;
    try { localStorage.setItem(KEY, JSON.stringify(saved)); } catch (err) {}
  }, true);

  var tries = 0;
  var timer = setInterval(function () {
    for (var p in saved) {
      try {
        var el = find(p);
        if (el && Math.abs(el.scrollTop - saved[p]) > 1) el.scrollTop = saved[p];
      } catch (err) {}
    }
    if (++tries >= 24) stop();
  }, 250);
  function stop() { clearInterval(timer); restoring = false; }
  addEventListener('wheel', stop, { capture: true, passive: true });
})();
"""#

// Reads every progress bar on the page as {label, pct}, where pct is always
// "percent used" (bars that count down, like Amp's "99% remaining", are flipped).
let readBarsJS = #"""
(function () {
  var out = [];
  document.querySelectorAll('[role=progressbar],[role=meter],progress').forEach(function (el) {
    var max = parseFloat(el.getAttribute('aria-valuemax') || el.getAttribute('max') || 100);
    var now = parseFloat(el.getAttribute('aria-valuenow') || el.getAttribute('value'));
    if (isNaN(now) || !max) return;
    var label = el.getAttribute('aria-label') || '';
    var text = label + ' ' + (el.getAttribute('aria-valuetext') || '');
    // No aria-label: use the first line of the nearest ancestor that has text.
    for (var p = el.parentElement; !label && p && p !== document.body; p = p.parentElement) {
      var t = (p.innerText || '').trim();
      if (t) { label = t.split('\n')[0]; text = t; }
    }
    var pct = now / max * 100;
    if (/remaining|left/i.test(text)) pct = 100 - pct;
    out.push({ label: label.replace(/:.*$/, '').trim().slice(0, 40), pct: pct });
  });
  return JSON.stringify(out);
})()
"""#

// MARK: - One pane per site

final class Pane: NSView, WKNavigationDelegate, WKUIDelegate {
    let source: Source
    let webView: WKWebView
    private(set) var bars: [(label: String, pct: Double)] = []
    private let status = NSTextField(labelWithString: "loading…")
    private let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()

    init(source: Source, zoom: CGFloat) {
        self.source = source
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // logins persist between launches
        config.userContentController.addUserScript(
            WKUserScript(source: keepScrollJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)

        webView.customUserAgent = safariUA
        webView.pageZoom = zoom
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        let title = NSTextField(labelWithString: source.name)
        title.font = .boldSystemFont(ofSize: 11)
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        let home = NSButton(title: "↻", target: self, action: #selector(goHome))
        home.isBordered = false
        home.toolTip = "Go back to the usage page and reload"

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.addView(title, in: .leading)
        header.addView(status, in: .leading)
        header.addView(home, in: .trailing)

        for v in [header, webView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: 20),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc func goHome() { refresh(force: true) }

    private func withoutFragment(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return c?.string ?? url.absoluteString
    }

    /// Reloads the usage page. Automatic refreshes (force == false) are skipped while
    /// you are somewhere else on the site, e.g. in the middle of signing in.
    func refresh(force: Bool) {
        let target = source.url()
        guard let current = webView.url else {
            webView.load(URLRequest(url: target))
            return
        }
        let onPage = current.host == target.host && current.path == target.path
        guard force || onPage else {
            status.stringValue = "paused, click ↻ to return"
            return
        }
        if webView.isLoading && !force { return }

        if current.absoluteString == target.absoluteString {
            webView.reload()
        } else if withoutFragment(current) == withoutFragment(target) {
            // Only the #fragment differs: a plain load would not refetch anything.
            let hash = target.fragment ?? ""
            webView.evaluateJavaScript("location.hash = '\(hash)'; location.reload();", completionHandler: nil)
        } else {
            webView.load(URLRequest(url: target))
        }
    }

    /// Reads the bars off the page. Keeps the last reading while the page is
    /// mid-reload, and drops it when you are not on the usage page (signed out).
    func readBars(then done: @escaping () -> Void) {
        let target = source.url()
        guard let current = webView.url, current.host == target.host, current.path == target.path else {
            bars = []
            return done()
        }
        webView.evaluateJavaScript(readBarsJS) { [weak self] result, _ in
            if let data = (result as? String)?.data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !list.isEmpty {
                self?.bars = list.map { ($0["label"] as? String ?? "", $0["pct"] as? Double ?? 0) }
            }
            done()
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status.stringValue = "updated " + timeFormat.string(from: Date())
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        status.stringValue = "load failed, will retry"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        status.stringValue = "load failed, will retry"
    }

    // MARK: WKUIDelegate

    // Sign-in popups ("Continue with Google") get a real window of their own, so
    // they can hand the result back to the page that opened them.
    private var popup: NSWindow?

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        child.customUserAgent = safariUA
        child.uiDelegate = self
        let window = NSPanel(contentRect: child.frame, styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = child
        window.center()
        window.makeKeyAndOrderFront(nil)
        popup = window
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        popup?.close()
        popup = nil
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var split: NSSplitView!
    private var panes: [Pane] = []
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    private let intervals: [(String, Double)] = [
        ("15 seconds", 15), ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300),
    ]
    private let zooms: [Double] = [0.5, 0.6, 0.7, 0.8, 1.0]

    private var interval: Double {
        get { let v = defaults.double(forKey: "interval"); return v > 0 ? v : 60 }
        set { defaults.set(newValue, forKey: "interval") }
    }
    private var zoom: Double {
        get { let v = defaults.double(forKey: "zoom"); return v > 0 ? v : 0.6 }
        set { defaults.set(newValue, forKey: "zoom") }
    }
    private var floats: Bool {
        get { defaults.object(forKey: "float") == nil ? true : defaults.bool(forKey: "float") }
        set { defaults.set(newValue, forKey: "float") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildPanel()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        drawStatusItem()
        buildStatusMenu()
        let reader = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.readBars() }
        RunLoop.main.add(reader, forMode: .common)

        showPanel()
        panes.forEach { $0.refresh(force: true) }
        startTimer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Window

    private func buildPanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 900),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        panel.title = "Usage"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = floats
        panel.level = floats ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 260, height: 300)

        split = NSSplitView()
        split.isVertical = false // panes stacked top to bottom
        split.dividerStyle = .thin
        panes = sources.map { Pane(source: $0, zoom: CGFloat(zoom)) }
        panes.forEach { split.addArrangedSubview($0) }
        panel.contentView = split

        panel.center()
        panel.setFrameAutosaveName("UsageBarPanel")

        // Give the three panes equal height the first time; after that the
        // divider positions you drag to are remembered.
        let hadLayout = defaults.object(forKey: "NSSplitView Subview Frames UsageBarSplit") != nil
        split.autosaveName = "UsageBarSplit"
        if !hadLayout {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.split.layoutSubtreeIfNeeded()
                let h = self.split.bounds.height
                let n = CGFloat(self.panes.count)
                for i in 0..<(self.panes.count - 1) {
                    self.split.setPosition(h * CGFloat(i + 1) / n, ofDividerAt: i)
                }
            }
        }
    }

    private func showPanel() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel()
            panes.forEach { $0.refresh(force: false) }
        }
    }

    // MARK: Refreshing

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.panes.forEach { $0.refresh(force: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Menu bar bars

    private var shownBars = ""

    /// Reads the bars off all pages and redraws the menu bar item if they changed.
    private func readBars() {
        var left = panes.count
        for pane in panes {
            pane.readBars { [weak self] in
                left -= 1
                guard let self = self, left == 0 else { return }
                let now = self.panes.map { p in p.bars.map { "\($0.label)=\(Int($0.pct.rounded()))" }.joined(separator: ",") }
                    .joined(separator: "|")
                guard now != self.shownBars else { return }
                self.shownBars = now
                self.drawStatusItem()
                self.buildStatusMenu()
            }
        }
    }

    /// Menu bar item: for each site its initial, then one small vertical bar per
    /// usage bar on that page (fuller = more used; orange from 70%, red from 90%).
    private func drawStatusItem() {
        let barW: CGFloat = 5, gap: CGFloat = 2, letterW: CGFloat = 9, groupGap: CGFloat = 5
        let panes = self.panes
        let width = panes.reduce(CGFloat(0)) { $0 + letterW + CGFloat(max($1.bars.count, 1)) * (barW + gap) + groupGap } - groupGap
        let image = NSImage(size: NSSize(width: width, height: 16), flipped: false) { _ in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.labelColor,
            ]
            var x: CGFloat = 0
            for pane in panes {
                (String(pane.source.name.prefix(1)) as NSString).draw(at: NSPoint(x: x, y: 2), withAttributes: attrs)
                x += letterW
                if pane.bars.isEmpty {
                    ("?" as NSString).draw(at: NSPoint(x: x, y: 2), withAttributes: attrs)
                    x += barW + gap
                }
                for bar in pane.bars {
                    let track = NSRect(x: x, y: 2, width: barW, height: 12)
                    NSColor.labelColor.withAlphaComponent(0.25).setFill()
                    NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
                    (bar.pct >= 90 ? NSColor.systemRed : bar.pct >= 70 ? NSColor.systemOrange : NSColor.labelColor).setFill()
                    let h = max(1, track.height * CGFloat(min(max(bar.pct, 0), 100)) / 100)
                    NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: barW, height: h), xRadius: 1.5, yRadius: 1.5).fill()
                    x += barW + gap
                }
                x += groupGap
            }
            return true
        }
        statusItem.button?.image = image
        statusItem.button?.title = ""
    }

    @objc private func refreshNow() { panes.forEach { $0.refresh(force: true) } }

    @objc private func pickInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        interval = v
        startTimer()
        buildStatusMenu()
    }

    @objc private func pickZoom(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        zoom = v
        panes.forEach { $0.webView.pageZoom = CGFloat(v) }
        buildStatusMenu()
    }

    @objc private func toggleFloat() {
        floats.toggle()
        panel.isFloatingPanel = floats
        panel.level = floats ? .floating : .normal
        buildStatusMenu()
    }

    // MARK: Menus

    private func buildStatusMenu() {
        let menu = NSMenu()
        for pane in panes {
            menu.addItem(.sectionHeader(title: pane.source.name))
            if pane.bars.isEmpty {
                menu.addItem(NSMenuItem(title: "no bars found, open the window to sign in", action: nil, keyEquivalent: ""))
            }
            for bar in pane.bars {
                let filled = Int((min(max(bar.pct, 0), 100) / 10).rounded())
                let meter = String(repeating: "█", count: filled) + String(repeating: "░", count: 10 - filled)
                menu.addItem(NSMenuItem(title: "\(meter)  \(Int(bar.pct.rounded()))% used  \(bar.label)", action: nil, keyEquivalent: ""))
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Show / Hide Window", #selector(togglePanel)))
        menu.addItem(item("Refresh Now", #selector(refreshNow)))
        menu.addItem(.separator())

        let every = NSMenuItem(title: "Refresh Every", action: nil, keyEquivalent: "")
        let everyMenu = NSMenu()
        for (label, seconds) in intervals {
            let i = item(label, #selector(pickInterval(_:)))
            i.representedObject = seconds
            i.state = seconds == interval ? .on : .off
            everyMenu.addItem(i)
        }
        every.submenu = everyMenu
        menu.addItem(every)

        let zoomItem = NSMenuItem(title: "Page Zoom", action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu()
        for z in zooms {
            let i = item("\(Int(z * 100))%", #selector(pickZoom(_:)))
            i.representedObject = z
            i.state = abs(z - zoom) < 0.001 ? .on : .off
            zoomMenu.addItem(i)
        }
        zoomItem.submenu = zoomMenu
        menu.addItem(zoomItem)

        let floatItem = item("Keep on Top", #selector(toggleFloat))
        floatItem.state = floats ? .on : .off
        menu.addItem(floatItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit UsageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    /// The app has no visible menu bar, but it still needs these so that
    /// Cmd-C / Cmd-V / Cmd-A work when you sign in.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem(title: "Quit UsageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar app, no Dock icon
app.run()
