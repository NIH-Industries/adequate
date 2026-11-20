# Changelog

## Unreleased

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
