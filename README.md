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
- **Restore Arc folders.** Dia imports Arc's sidebar flattened. **Restore…** under Arc in Settings → Patches puts the imported folders back inside their Arc parents, matched by name and order, one space at a time.
- **Folder icon.** Show the same icon on every folder, in place of Dia's and imported ones.
- **Sidebar spacing** and **Folder spacing.** Space rows and folders in the sidebar closer together.
- **Plain active tab.** Remove the glow and outline around the selected tab.
- **Extensions menu button.** A ⋯ button at the end of the toolbar lists every extension, pinned or not.

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
- The add-on only rearranges Dia's own interface. It doesn't read your pages, history or passwords, and its only network use is checking Dia's update feed. Restore Arc folders reads Arc's `StorableSidebar.json`, only when you click it.
- Nothing runs in the background. Updates are checked when Dia opens and installed when you quit it.
- Because the app is now signed by you, macOS asks once per Dia update before Dia can read "Dia Safe Storage". Dia's built-in passkey support is off, since only The Browser Company can sign for it; signing in with a password works.

## Uninstall

In Dia, open **Settings → Patches** and click **Restore…**. Dia reopens as the original app with its own updates.

Or from Terminal:

```sh
~/Library/Application\ Support/DiaPatches/bin/diapatch uninstall --relaunch --purge
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). PRs need a screenshot or screen recording of the change.
