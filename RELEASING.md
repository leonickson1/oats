# Releasing Oats

How a new version reaches users. Oats has a built-in updater (`Oats/App/UpdateChecker.swift`): on launch, at most once every 24 hours, it fetches a small JSON "appcast" from the repo, compares the version to what is running, and if there is a newer one it shows the release-notes dialog with an **Install** button.

> [!IMPORTANT]
> **The repo must be public for updates to work.** The app fetches
> `https://raw.githubusercontent.com/leonickson1/oats/main/appcast.json`
> and downloads the DMG from a GitHub Release. While the repo is **private**,
> both return `404` and **no user ever sees an update**. Either make the repo
> public, or host `appcast.json` + `Oats.dmg` on a public host (e.g. the site on
> Render) and point `UpdateChecker.defaultFeedURL` at it.

## The moving parts

| Thing | Where | What it holds |
|---|---|---|
| App version | `project.yml` → `MARKETING_VERSION` | the version the running app reports |
| Appcast | `appcast.json` (repo root, `main`) | `{ version, notes, url }` the updater reads |
| DMG | a GitHub Release asset | the actual download `url` points to |
| Feed URL | `UpdateChecker.defaultFeedURL` | where the app looks for `appcast.json` |

An update appears to users only when `appcast.json`'s `version` is **higher** than their installed `MARKETING_VERSION` (numeric compare), and the feed + DMG URLs are reachable.

## Cutting a release

1. **Bump the version.** In `project.yml`, raise `MARKETING_VERSION` (e.g. `0.2.1` → `0.3.0`) and `CURRENT_PROJECT_VERSION`, then `xcodegen generate`.
2. **Build + sign.** Archive a Release build signed with the Developer ID team (`838ASYRYR5`), hardened runtime on.
3. **Notarize** (so Gatekeeper does not block users on first open):
   ```sh
   xcrun notarytool store-credentials   # one-time, sets up a keychain profile
   xcrun notarytool submit Oats.dmg --keychain-profile <profile> --wait
   xcrun stapler staple Oats.dmg
   ```
4. **Create the GitHub Release** for the new tag (e.g. `v0.3.0`) and upload `Oats.dmg` as an asset. The stable download link is
   `https://github.com/leonickson1/oats/releases/latest/download/Oats.dmg`.
5. **Update `appcast.json`** on `main` with the new `version`, human-readable `notes` (these show in the dialog, one bullet per line reads well), and the DMG `url`. This is the switch that turns the update on for everyone.

## How fast users get it

The launch check is throttled to once per 24h (`checkOnLaunchIfDue`). So after you publish step 5, most users see the dialog **the next time they open Oats on a new day**, exactly the "notified the next day" behavior. Users can also force it now with **Settings → Updates → Check now**.

## Testing the dialog

Run the app with `OATS_QA_UPDATE=1` to show the update dialog with sample data (no network, no real version change), for screenshots or a quick look.
