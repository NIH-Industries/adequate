# Adequate

A small macOS browser from NIH Industries, built on WebKit (WKWebView).

- **Spaces**: each Space has its own tabs and its own persistent cookies,
  storage and logins. Switch with the dots at the bottom of the sidebar;
  right-click one to rename, reorder or delete it. Deleting a Space erases
  its site data.
- **`adequate` CLI**: `adequate open <space> <url>...` opens tabs in a Space,
  creating it if needed; `adequate spaces` lists them. Requests carry a
  per-user token, so web pages can't forge them.
- **Default browser**: links from other apps open as a tab in the current Space.
  Use Adequate › Make Adequate the Default Browser.
- **No extensions**: WKWebView apps can't load them, so passwords come from
  the 1Password app (Quick Access, ⌘⇧Space) by copy and paste.
- **Fresh start**: tabs aren't kept between launches; Spaces and logins are.

## Keys

| key | does |
|---|---|
| ⌘T / ⌘W | new tab / close tab |
| ⌘L | address bar |
| ⌘S | show / hide the sidebar |
| ⌘⇧C | copy the current page's address |
| ⌘[ / ⌘] | back / forward |
| ⌘R | reload |
| ⌥⌘I | developer tools (or right-click › Inspect Element) |
| ⌃Tab / ⌃⇧Tab | recent tabs in this Space, most recent first |
| ⌘⇧[ / ⌘⇧] | previous / next tab in the sidebar |
| ⌘1–⌘8, ⌘9 | tab by position, last tab |
| ⌃1–⌃9 | Space by position |
| ⌘⇧N | new Space |
| ⌘= / ⌘- / ⌘0 | zoom in / out / actual size |
| ⌘-click a link | open it in a background tab |

## Build

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make run          # build, install to ~/Applications and open
make install-cli  # link the adequate CLI into ~/.local/bin
```
