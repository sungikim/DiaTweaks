# DiaTweaks

Small tweaks for the [Dia](https://www.diabrowser.com) browser, kept in place when Dia updates. Turn them on and off in **Dia → Settings → Patches**:

- Edge-to-edge web content
- Square corners by the sidebar
- Hide toolbar
- Hide sidebar button
- Hide Chat button
- Hide Chats button
- Hide recent tabs button

This fork of [JaceThings/DiaTweaks](https://github.com/JaceThings/DiaTweaks) adds:

- **Folders in folders.** Drag a folder into another one, or choose **New Subfolder** in a folder's menu. Near a folder's edge, how far left the pointer is picks the level a drop lands at, as in Arc. A folder emptied by a move stays until you delete it.
- **Folder dropdowns in top tabs.** With tabs at the top, folders stay closed and drop down their contents when you point at or click them, and folders inside them expand in place. Turned off, folders open in the tab bar as usual and pointing at one shows nothing; a folder inside a folder still drops down when Folders in folders is on.
- **Restore Arc folders.** Dia imports Arc's sidebar flattened. **Restore…** under Arc in Settings → Patches puts the imported folders back inside their Arc parents, matched by name and order, one space at a time.
- **Folder icon.** Show the same icon on every folder, in place of Dia's and imported ones.
- **Sidebar spacing** and **Folder spacing.** Space rows and folders in the sidebar closer together.
- **Plain active tab.** Remove the glow and outline around the selected tab.
- **Extensions menu button.** A ⋯ button at the end of the toolbar lists every extension, pinned or not. With Hide toolbar on, it moves into the sidebar URL bar.
- **Sidebar URL bar.** The page's address at the top of the sidebar, with back, forward and reload by the window buttons. Pair it with Hide toolbar for an Arc-style window.
- **Command bar.** ⌘T and ⌘L open an Arc-style bar that finds open tabs, history, bookmarks, Dia's commands and `chrome://` pages, and completes addresses as you type. Local addresses like `nas:5000` or `192.168.0.2` open over http with their port.
- **Arc-style bookmarks.** Double-click a bookmark's name in the sidebar to rename it in place. Its menu also offers Replace Bookmark URL with Current.
- **Tidy tabs.** Point at the line above your tabs for Sort and Group next to Close All, or use a tab's menu: Sort puts tabs from the same site together, Group puts them in a folder named after the site. Bookmarks and folders stay put.
- **Phone access.** Turn it on under Phone in Settings → Patches and open the address it shows (or scan its QR code) on your phone, over your network or Tailscale: your spaces' favorites, bookmarks with their folders, and open tabs, searchable, with links that open on the phone. In Safari, Share → Add to Home Screen makes it an app. The page lives at a secret address only you are given.
- **Downloads at the bottom.** Dia's downloads button moves from the top of the sidebar to its bottom left and stays there even when there are no downloads.
- **Tab memory.** Each tab's row in the sidebar shows the memory it uses, in MB, the figure Activity Monitor shows for its processes. Tabs sharing a process each count all of it. Experimental: it keeps a DevTools setting on that Dia turns off.
- **Little window for links.** Like Little Arc, a link opened from another app opens in a small window without the sidebar. **Open in Window** (⌘O) moves the page to a tab in your main window.
- **Keep windows active.** A window keeps its active look after you click into another app.
- **Full screen** squares the page's corners, and if Dia quits unexpectedly twice right after opening, the patches turn themselves off until you turn them back on in Settings → Patches.

The sidebar URL bar, command bar and parts of Tidy tabs are ported from [daypatch](https://github.com/TA3/daypatch) (MIT License, © 2026 The daypatch contributors); its license notice is in `src/dylib/ArcBar.m` and `src/dylib/Tabs.m`.

Dia's folder code is Swift without symbols, so the folder tweaks patch Dia's code in memory at launch, found by exact byte signatures. If a Dia update changes that code, those tweaks turn themselves off and their switches are greyed out until this repository catches up. They were built against Dia 1.55.1.

Unofficial and not affiliated with The Browser Company. Apple Silicon, macOS 14 or later.

## Install

1. Install Dia into Applications, if it isn't there already.
2. Install Apple's developer tools: `xcode-select --install`
3. Run:

   ```sh
   git clone https://github.com/sungikim/DiaTweaks.git
   cd DiaTweaks
   ./install.sh
   ```

Dia quits and reopens. When macOS asks to access "Dia Safe Storage", enter your password and click **Always Allow**.

## How it works

- Everything is built on your Mac from this source. The only download is Dia itself, from The Browser Company's own update feed, and it's used only if it's signed by The Browser Company and passes Gatekeeper.
- An untouched copy of the official Dia is kept in `~/Library/Application Support/DiaPatches/pristine`. Restoring puts it back.
- The patched Dia gets one extra line that loads the add-on, its built-in updater is switched off (DiaTweaks updates it instead, keeping the patches), and it's re-signed with a certificate created on your Mac, in your login keychain, called "DiaPatches Local Signing". Nothing is signed with anyone else's certificate.
- The add-on only rearranges Dia's own interface. It doesn't read your pages or passwords, and its only network use is checking Dia's update feed. Restore Arc folders reads Arc's `StorableSidebar.json`, only when you click it. The command bar reads the profile's History, Bookmarks and Favicons, read-only, to list results.
- Nothing runs in the background unless you turn on Phone access, which runs a small server (`diapatch-mobile`, on port 7480) that serves only that page and the list Dia last saved for it. Turning it off, or restoring the original Dia, stops it. Updates are checked when Dia opens and installed when you quit it.
- Because the app is now signed by you, macOS asks once per Dia update before Dia can read "Dia Safe Storage". Dia's built-in passkey support is off, since only The Browser Company can sign for it; signing in with a password works.

## Uninstall

In Dia, open **Settings → Patches** and click **Restore…**. Dia reopens as the original app with its own updates.

Or from Terminal:

```sh
~/Library/Application\ Support/DiaPatches/bin/diapatch uninstall --relaunch --purge
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). PRs need a screenshot or screen recording of the change.
