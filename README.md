# Adequate

A small macOS browser from NIH Industries, built on WebKit (WKWebView).

- **Spaces**: each Space has its own tabs and its own persistent cookies,
  storage and logins, and its own colour and emoji, which tint the sidebar.
  Switch with the dots at the bottom of the sidebar; right-click one to
  edit (name, emoji, colour), reorder or delete it. Deleting a Space erases
  its site data.
- **Throwaway Spaces**: tick Throwaway in the Space dialog and nothing about
  the Space touches the disk: its logins, site data and history live only in
  memory, and the whole Space (name and all) is gone when Adequate quits. A
  kept Space's cookies are plain files any program running as you can read,
  so a throwaway Space suits a session you'd rather leave no trace of. Its dot
  has a dashed edge; right-click it › Forget Everything to log out of
  everything now. Turning it on for an existing Space erases what that Space
  had saved. Tabs in it can't be pinned.
- **`adequate` CLI**: `adequate open <space> <url>...` opens tabs in a Space,
  creating it if needed; `adequate spaces` lists them. Requests carry a
  per-user token, so web pages can't forge them.
- **Default browser**: links from other apps open as a tab in the current Space.
  Use Adequate › Make Adequate the Default Browser.
- **No extensions**: WKWebView apps can't load them. Logins come from
  1Password through its CLI instead: ⌘⇧P lists the logins saved for the site
  you're on, in every 1Password account (that site and its subdomains only, so a lookalike gets nothing,
  and only while the field is still on that site)
  and fills the one you pick, or a one-time code into a code field (otherwise
  the code is copied, and cleared a minute later). Needs `op` (`brew install
  1password-cli`) and 1Password › Settings › Developer › Integrate with
  1Password CLI; unlocking is 1Password's own Touch ID. Not on plain HTTP.
- **Sound**: a tab playing sound shows a speaker (click it to mute), and its
  Space's dot gets one too. Tab › Pause All Media hushes everything.
- **Video calls**: pages can use the camera and microphone once you allow
  them (asked once per site per Space, until Adequate quits), and share a
  window or the whole screen. A site you've allowed may play sound without
  a click, so a call you join isn't silent. To share one tab, right-click it and choose
  Open in New Window, then pick that window.
- **Location**: pages like maps can ask where you are, asked the same way
  as the camera (once per site per Space, until Adequate quits). macOS asks
  once too, whether Adequate may use Location Services.
- **Notifications**: sites can show macOS notifications once you allow them
  (remembered per site per Space). Clicking one brings back its tab. They
  only come while Adequate is open with the tab loaded: there's no push.
- **Suggestions**: the address bar suggests sites (protocol and domain) from
  the Space's own history as you type (↑/↓ to choose, Return to go there,
  or Tab to put it in the field and add a path, like `/admin`). Each Space keeps its history to
  itself, in `history/<space id>.json`, and deleting the Space deletes it.
- **Where you are**: the address bar is usually hidden, so the site's name
  sits under the Space name in the sidebar (or in a pill at the top of the
  window when the sidebar is narrowed or hidden), with a padlock when the whole page came
  over HTTPS and a warning when it didn't. Pages can't draw over either.
  Click the site name for the full address, to edit or copy (as ⌘L).
- **Sidebar**: ⌘S (or the button at its bottom left) narrows it to a rail:
  the Space's emoji (click it for the Space's menu), a favicon for each tab
  (hover for its title), folders as icons with their tabs marked by a bar in
  the Space's colour, a ring for a download in progress, and the Space dots.
  ⌘S again, or the button at the rail's foot, brings the full sidebar back;
  dragging the sidebar's edge shut narrows it too. Adequate remembers which
  you left it as. ⌥⌘S hides it altogether, for a call or a film, and again
  brings it back. Swipe sideways on it with
  two fingers to go to the next or previous Space. Double-click its top to
  zoom the window, as you would a title bar.
- **Asking first**: a page has to ask before it opens another app (Zoom,
  Slack, Mail). A yes, like a camera or microphone yes, holds for that site in
  that Space until Adequate quits; a no holds until the page reloads, so it
  can't keep asking. Return always picks the safe answer. Said the wrong
  thing? Right-click the tab › Reset Permissions for the site, which also
  forgets its notification answer.
- **Local files**: an html file can read the files in its own folder (so a
  report's images load), unless that folder is a catch-all one like
  Downloads, Desktop or your home folder: then it can only read itself.
- **Uploads**: a page's file button opens the usual Open panel, as a sheet
  that names the site asking; only what you pick goes to it. Dragging files
  onto a page works too.
- **Downloads**: what a page can't show (zips, disk images), or is told to
  save, goes to ~/Downloads, never written over (`report 2.pdf`) and never
  opened by itself. Right-click a link or image › Download Linked File works
  too. They're listed at the foot of the sidebar with their progress: hover
  one to cancel it or show it in Finder, double-click to open it, drag it out,
  or right-click for the rest. Files are quarantined like Safari's, so an app
  or script in one still gets Gatekeeper's checks. A throwaway Space's
  downloads are kept (you asked for them) but their quarantine record leaves
  out where they came from. The list is only for this run.
- **HTTP sign-in**: sites behind basic or digest authentication ask for a
  user name and password in a sheet naming the site. They're kept only until
  Adequate quits, never saved.
- **Split view**: two tabs side by side (⌘\\, or drag one tab onto the middle of another,
  or right-click › Open in Split View). Click a pane to use it: it gets the
  Space's colour, and shortcuts, ⌘W and the site name act on it. Clicking
  another tab replaces the left pane; going to the right-hand tab any other
  way (⌃Tab, ⌘1–9) leaves the split.
- **Pinned tabs**: hover a tab and click its pin (or right-click › Pin Tab)
  to keep it. Pins sit at the
  top of the sidebar and come back after a restart, asleep (dimmed) until you
  click one, so they cost nothing until used. A pin always comes back to the
  address you pinned, wherever you browse in it (right-click › Back to Pinned
  Page, or Pin This Page Instead). ⌘W puts a pin back to sleep rather than
  closing it: Unpin Tab gets rid of it.
- **Folders**: the folder button at the top of the sidebar makes one. Drag a
  tab onto a folder (or right-click › Move to Folder) to put it inside, which
  pins it, so folders and what's in them come back after a restart. Click a
  folder to open or close it; right-click to rename or remove it (its tabs stay
  as ordinary pins). Not in throwaway Spaces. ⌘1–9 and ⌘⇧[ / ⌘⇧] go by the
  tabs as the sidebar shows them, skipping those in closed folders.
- **Reordering**: drag a tab to the top or bottom edge of another (a line
  shows where it'll go). Among the pins or in a folder it's pinned; among
  ordinary tabs it's unpinned. Pins keep their order after a restart.
- **Fresh start**: other tabs aren't kept between launches; pins, Spaces and
  logins are.

## Keys

| key | does |
|---|---|
| ⌘T / ⌘W | new tab / close tab |
| ⌘L | address bar (it floats over the page) |
| ⌘S | show / hide the sidebar |
| ⌘⇧C | copy the current page's address |
| ⌘⇧P | fill a login from 1Password |
| ⌘F | find on the page: Return / ⇧Return (or ⌘G / ⌘⇧G) for next / previous, Esc to close and clear the highlight |
| ⌘[ / ⌘] | back / forward |
| ⌘R | reload |
| ⌥⌘I | developer tools (or right-click › Inspect Element) |
| ⌃Tab / ⌃⇧Tab | switcher of this Space's tabs, most recent first, with previews: let go of ⌃ to go there, Esc to stay |
| ⌘⇧[ / ⌘⇧] | previous / next tab in the sidebar |
| ⌘1–⌘8, ⌘9 | tab by position; the last tab (its own number while there are nine or fewer) |
| ⌃1–⌃9 | Space by position |
| hold ⌘ / ⌃ | show each tab's / Space's number |
| fn⌃F | fill the screen with the window (macOS's own Window › Fill) |
| ⌘⇧N | new Space |
| ⌘⇧A | next tab playing sound, in any Space |
| ⌥⌘L | show Downloads in Finder |
| ⌘= / ⌘- / ⌘0 | zoom in / out / actual size |
| ⌘-click a link | open it in a background tab |
| ⌘\\ | split view: a new tab beside this one, or back to one pane |

## Build

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make run          # build Adequate Dev, install to /Applications and open
make install-cli  # link the adequate CLI into ~/.local/bin
```

Builds from source are **Adequate Dev**: a separate app from the released
Adequate, with its own bundle id (`com.nih-industries.adequate.dev`), an
orange DEV ribbon on its icon, and its own Spaces, logins and settings. So
you can live in the released app (`brew install nih-industries/tap/adequate`)
and try changes in Adequate Dev beside it. Adequate Dev has no passkeys:
Apple's passkey entitlement belongs to the released app. The `adequate` CLI
always talks to the released app.
