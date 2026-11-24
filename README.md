# Space Overview

See what uses the space on your Mac, and clear it. A fast Rust scanner with a native SwiftUI app.

- Folder tree with sizes, shares, item counts and dates
- What each app uses: the app itself, its data and its caches
- Largest and oldest files
- Rename, new folder, move to Trash with undo, and app uninstall

Nothing is sent anywhere: the app makes no network connections of its own.

## Install

Needs an Apple Silicon Mac (M1 or newer) with macOS 14 or newer. So far it has only been run on macOS 26.

1. Download `Space-Overview-0.1.0.zip` from [Releases](../../releases), unzip it and move the app to Applications.
2. Open it. macOS blocks it, because the app isn't notarized by Apple.
3. Go to **System Settings > Privacy & Security**, scroll down and choose **Open Anyway**.
4. In the app, choose **Open System Settings** and turn on Full Disk Access for Space Overview. Quit and reopen it.

Full Disk Access lets an app read and change nearly all your files, so only give it to apps you trust. You can also choose **Scan anyway** without it; macOS may then ask about folders one by one. After an update you may have to turn it off and on again.

## What it can change

- Files you delete go to the Trash. The app never empties it.
- Only your home folder and the contents of `/Applications` can be changed. Main folders, Keychains, cloud storage folders, and files inside apps and photo libraries are locked.
- Running apps can't be changed or uninstalled.
- Files in a Desktop or Documents folder synced by iCloud may also disappear from your other devices.
- Matches based only on a folder's name are marked as possible and never selected for you.

Version 0.1.0 is early. Check each preview before you confirm. Apps owned by an administrator may have to be removed in Finder, and system-wide files in `/Library` are left behind.

## Build

Needs Xcode and [Rust](https://rustup.rs).

```
./build.sh
open "build/Space Overview.app"
```

Tests: `cargo test --release --manifest-path core/Cargo.toml`, and `"build/Space Overview.app/Contents/MacOS/SpaceOverview" --selftest` for the file actions (uses throwaway files).

## License

[MIT](LICENSE)
