# Releasing Oats

How a new version reaches users. Oats has a built-in updater (`Oats/App/UpdateChecker.swift`): on launch, at most once every 24 hours, it fetches a small JSON "appcast" from the repo, compares the version to what is running, and if there is a newer one it shows the release-notes dialog with an **Install** button.

> [!IMPORTANT]
> **The repo must stay public for updates to work.** The app fetches
> `https://raw.githubusercontent.com/leonickson1/oats/main/appcast.json`
> and downloads the DMG from a GitHub Release. If the repo ever goes **private**,
> both return `404` and **no user ever sees an update again**. (It has been
> public since Sep 2026.)

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
2. **Build + sign.** A Release build signed with Developer ID, hardened runtime on. The two extra flags matter: without a secure timestamp and with the debugger entitlement (both defaults of a plain build) Apple rejects the notarization.
   ```sh
   xcodebuild -project Oats.xcodeproj -scheme Oats -configuration Release \
     -destination 'platform=macOS' \
     CODE_SIGN_IDENTITY="Developer ID Application" CODE_SIGN_STYLE=Manual \
     DEVELOPMENT_TEAM=838ASYRYR5 ENABLE_HARDENED_RUNTIME=YES \
     CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO 'OTHER_CODE_SIGN_FLAGS=--timestamp' build
   ```
3. **Package + notarize.** Build the branded "Drag to Install" DMG (custom background, icon layout, volume icon), sign it with `codesign --timestamp`, then notarize:
   ```sh
   packaging/dmg/build-dmg.sh <path-to>/Oats.app Oats.dmg
   codesign --force --timestamp -s "Developer ID Application" Oats.dmg
   xcrun notarytool submit Oats.dmg --keychain-profile oats-notary --wait
   xcrun stapler staple Oats.dmg
   xcrun stapler validate Oats.dmg   # "The validate action worked!"
   ```
   The `oats-notary` keychain profile already exists on this Mac (created once with `xcrun notarytool store-credentials oats-notary --apple-id ... --team-id 838ASYRYR5` and an app-specific password).
4. **Create the GitHub Release** for the new tag (e.g. `v0.3.0`) and upload `Oats.dmg` as an asset. The stable download link is
   `https://github.com/leonickson1/oats/releases/latest/download/Oats.dmg`.
5. **Update `appcast.json`** on `main` with the new `version`, human-readable `notes` (these show in the dialog, one bullet per line reads well), and the DMG `url`. This is the switch that turns the update on for everyone.

## How fast users get it

The launch check is throttled to once per 24h (`checkOnLaunchIfDue`). So after you publish step 5, most users see the dialog **the next time they open Oats on a new day**, exactly the "notified the next day" behavior. Users can also force it now with **Settings → Updates → Check now**.

## Testing the dialog

Run the app with `OATS_QA_UPDATE=1` to show the update dialog with sample data (no network, no real version change), for screenshots or a quick look.
