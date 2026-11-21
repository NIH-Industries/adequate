# Changelog

## Unreleased

### One Touch ID for a 1Password fill
⌘⇧P could ask for Touch ID two or three times in a row for the same
1Password account: once 1Password's session had lapsed, every request made
at the same moment (a login's password, its one-time code, a refresh of the
list in the background) asked on its own. Now the first request for an
account asks and the rest wait for it, so it's one touch per account.

## 0.2.1 - 2026-11-21

### 1Password fills only the site it chose for
⌘⇧P checks, as it fills, that the field is still on the site whose logins
it offered. Before, a page could swap the frame you'd clicked into for
another site's (after you clicked, or while 1Password was unlocking), and
the login went there. Now it says "Not filling: the page is no longer …"
instead.

### Tab numbers that count
Holding ⌘ shows each tab's real number while a Space has nine tabs or
fewer, so the only tab is ⌘1 rather than ⌘9. ⌘9 still goes to the last
tab, and past nine tabs the last one shows ⌘9 as before.

## 0.2.0 - 2026-11-20

### A rail instead of a hidden sidebar
⌘S now narrows the sidebar to a rail of icons rather than hiding it: just
the Space's emoji at the top, a favicon for each tab (hover for its title),
folders as icons with their tabs marked by a bar in the Space's colour, and
the Space dots stacked at the foot. Everything still works there: click to
switch, drag to reorder or split, right-click for the tab's menu, hold ⌘
for its number. Adequate remembers whether you left it full or narrow.
⌥⌘S hides it altogether, and the round button that floated over the page's
corner while it was hidden is gone.

### Calls you can hear the first time
A site you've let use your camera or microphone may now play sound without
a click, from the moment you say yes and on every page of it you load after.
Joining a Google Meet sometimes left you hearing no one until you reloaded,
because WebKit's autoplay rules had turned the call's audio away.

### Builds that keep their permissions
`make build` and `make install` sign Adequate with your Developer ID when
it's in your keychain, so macOS sees each rebuild as the same app and your
camera, microphone and Location answers stick. Without one they're signed
ad-hoc as before. `make install` no longer stops when the fresh build was
never registered with Launch Services, which is what happens once it's
signed with a Developer ID.

## 0.1.0 - 2026-11-19

### First release
A small macOS browser built on WebKit: Spaces with their own tabs, logins
and colour, throwaway Spaces that never touch the disk, the `adequate` CLI,
1Password logins with ⌘⇧P, video calls with screen sharing, notifications,
location, address suggestions from each Space's history, split view,
downloads in the sidebar and pages that ask before opening other apps. A
universal build, signed with a Developer ID and notarised, is on the GitHub
release. The README covers each in full.
