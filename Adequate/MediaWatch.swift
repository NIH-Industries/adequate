import WebKit

/// Notices which tabs are playing sound, and mutes them, through a small
/// script in every frame of every page.
///
/// It runs in the page's own world: only there does wrapping
/// HTMLMediaElement.play catch players that never join the page (`new Audio()`,
/// as SoundCloud and Spotify use). A page could fake its own reports or mute
/// itself, which costs nothing. Sound made straight through Web Audio (some
/// games and synths) doesn't show.
@MainActor
final class MediaWatch: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.page
    private static let name = "adequateMedia"
    weak var state: SpaceState?

    /// Wires the script's replies into a new tab's configuration.
    /// Pop-ups share their opener's controller, so they're already wired.
    static func install(in config: WKWebViewConfiguration, for state: SpaceState) {
        let watch = MediaWatch()
        watch.state = state
        config.userContentController.add(watch, contentWorld: world, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let frame = body["frame"] as? String, let playing = body["playing"] as? Bool,
              let tab = state?.tabs.first(where: { $0.webView === message.webView })
        else { return }
        tab.mediaReport(frame: frame, playing: playing, info: message.frameInfo)
    }

    /// Calls `__adequateSetMuted(true|false)` in the frame, which mutes or
    /// unmutes its media and keeps it so as new media starts.
    static func setMuted(_ muted: Bool, in webView: WKWebView, frame: WKFrameInfo) {
        webView.evaluateJavaScript("globalThis.__adequateSetMuted?.(\(muted))", in: frame, in: world) { _ in }
    }

    /// The page script, which SpaceState adds to each tab with the others.
    static var userScript: WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }

    private static let script = """
        (() => {
          const id = Math.random().toString(36).slice(2);
          const seen = new Set();       // media found through its events, even outside the page
          const ours = new WeakSet();   // media we muted, so the page's own muting stays its own
          let muted = false, last = null;
          const all = () => new Set([...seen, ...document.querySelectorAll('audio, video')]);
          const audible = el => !el.paused && !el.ended && el.volume > 0 && (!el.muted || ours.has(el));
          const post = playing => {
            if (playing === last) return;
            last = playing;
            webkit.messageHandlers.\(name).postMessage({ frame: id, playing });
          };
          const report = () => post([...all()].some(audible));
          const silence = el => { if (muted && !el.muted) { el.muted = true; ours.add(el); } };
          const watch = e => {
            if (!(e.target instanceof HTMLMediaElement)) return;
            seen.add(e.target);
            silence(e.target);
            report();
          };
          for (const type of ['play', 'playing', 'pause', 'ended', 'emptied', 'volumechange']) {
            document.addEventListener(type, watch, true);
          }
          // new Audio(): never in the page, so its events never reach the document.
          const play = HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play = function () {
            if (!seen.has(this)) {
              seen.add(this);
              for (const type of ['playing', 'pause', 'ended', 'emptied', 'volumechange']) {
                this.addEventListener(type, watch);
              }
            }
            silence(this);
            return play.apply(this, arguments);
          };
          addEventListener('pagehide', () => post(false));
          globalThis.__adequateSetMuted = on => {
            muted = on;
            for (const el of all()) {
              if (on) silence(el);
              else if (ours.has(el)) { el.muted = false; ours.delete(el); }
            }
            report();
          };
        })();
        """
}
