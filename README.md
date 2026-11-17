# Adequate

A small macOS browser from NIH Industries, built on WebKit (WKWebView).

- **Spaces**: each Space has its own tabs and its own persistent cookies,
  storage and logins, and its own colour and emoji, which tint the sidebar.
  Switch with the dots at the bottom of the sidebar; right-click one to
  edit (name, emoji, colour), reorder or delete it. Deleting a Space erases
  its site data.
- **Throwaway Spaces**: tick Throwaway in the Space dialog and its logins,
  site data and history live only in memory, forgotten when Adequate quits.
  A kept Space's cookies are plain files any program running as you can read,
  so keep the logins that matter most (work SSO, cloud consoles, banking) in
  a throwaway one. Its dot has a dashed edge; right-click it › Forget
  Everything to log out of everything now. Turning it on for an existing
  Space erases what that Space had saved.
- **`adequate` CLI**: `adequate open <space> <url>...` opens tabs in a Space,
  creating it if needed; `adequate spaces` lists them. Requests carry a
  per-user token, so web pages can't forge them.
- **Default browser**: links from other apps open as a tab in the current Space.
  Use Adequate › Make Adequate the Default Browser.
- **No extensions**: WKWebView apps can't load them, so passwords come from
  the 1Password app (Quick Access, ⌘⇧Space) by copy and paste.
- **Sound**: a tab playing sound shows a speaker (click it to mute), and its
  Space's dot gets one too. Tab › Pause All Media hushes everything.
- **Video calls**: pages can use the camera and microphone once you allow
  them (asked once per site per Space, until Adequate quits), and share a
  window or the whole screen. To share one tab, right-click it and choose
  Open in New Window, then pick that window.
- **Notifications**: sites can show macOS notifications once you allow them
  (remembered per site per Space). Clicking one brings back its tab. They
  only come while Adequate is open with the tab loaded: there's no push.
- **Suggestions**: the address bar suggests sites (protocol and domain) from
  the Space's own history as you type (↑/↓ to choose). Each Space keeps its history to
  itself, in `history/<space id>.json`, and deleting the Space deletes it.
- **Where you are**: the address bar is usually hidden, so the site's name
  sits under the Space name in the sidebar (or in a pill at the top of the
  window when the sidebar is hidden), with a padlock when the whole page came
  over HTTPS and a warning when it didn't. Pages can't draw over either.
- **Asking first**: a page has to ask before it opens another app (Zoom,
  Slack, Mail). A yes, like a camera or microphone yes, holds for that site in
  that Space until Adequate quits; a no holds until the page reloads, so it
  can't keep asking. Return always picks the safe answer. Said the wrong
  thing? Right-click the tab › Reset Permissions for the site, which also
  forgets its notification answer.
- **Local files**: an html file can read the files in its own folder (so a
  report's images load), unless that folder is a catch-all one like
  Downloads, Desktop or your home folder: then it can only read itself.
- **Fresh start**: tabs aren't kept between launches; Spaces and logins are.

## Keys

| key | does |
|---|---|
| ⌘T / ⌘W | new tab / close tab |
| ⌘L | address bar (it floats over the page) |
| ⌘S | show / hide the sidebar |
| ⌘⇧C | copy the current page's address |
| ⌘[ / ⌘] | back / forward |
| ⌘R | reload |
| ⌥⌘I | developer tools (or right-click › Inspect Element) |
| ⌃Tab / ⌃⇧Tab | switcher of this Space's tabs, most recent first, with previews: let go of ⌃ to go there, Esc to stay |
| ⌘⇧[ / ⌘⇧] | previous / next tab in the sidebar |
| ⌘1–⌘8, ⌘9 | tab by position, last tab |
| ⌃1–⌃9 | Space by position |
| ⌘⇧N | new Space |
| ⌘⇧A | next tab playing sound, in any Space |
| ⌘= / ⌘- / ⌘0 | zoom in / out / actual size |
| ⌘-click a link | open it in a background tab |

## Build

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make run          # build, install to ~/Applications and open
make install-cli  # link the adequate CLI into ~/.local/bin
```
