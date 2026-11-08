# Card Rename

**[Download Card Rename (DMG)](https://github.com/Briantoma/CardRename/releases/latest/download/CardRename.dmg)** · [all releases](https://github.com/Briantoma/CardRename/releases)

The Labroll features are based on **[Labroll Utility](https://github.com/brixybrice/Labroll-Utility) by Brix** ([@brixybrice](https://github.com/brixybrice)).

Open the DMG and drag Card Rename to Applications. Apple Silicon, macOS 14 or later. Signed by Oz Color Shop and notarized by Apple (from version 1.7), so it opens like any downloaded app. At first launch, allow notifications and access to removable volumes.

From 1.7 on, the app checks this page's latest release once a day (and when its panel opens, at most hourly). A newer version shows **Update available** in the panel, with a Download button, and one notification.

Menu bar app that renames camera cards after the reel ID found in their clip names, as soon as they are mounted. Every card name follows the card naming scheme (see Naming scheme); the examples use the default, `{labroll}_{date:YYYYMMDD}_{cam}`, on an exFAT card.

| Card | Clips | New name |
| --- | --- | --- |
| Sony XDCAM, ARRI, Canon, DJI Ronin | `D902C001_260916JN.MXF` | `D902_261103` (the reel ID is the labroll; `{labroll}` alone gives `D902`) |
| RED | `A003_C001_0916AB_001.R3D` | `A003_261103` |
| Blackmagic | `A007_09161234_C001.braw` | `A007_261103` |
| No reel ID (Sony `C0001.MP4`, DJI, GoPro, Lumix, DCIM) | | Next labroll, e.g. `A001_GOPRO`, named directly or suggested in a dialog (see Labroll) |

Only cards still carrying a default name (UNTITLED, NO NAME, NONAME, DJI, editable in Settings) are renamed. A card with more than one reel ID is never renamed, an alert says so. Names are cut to the file system limit (FAT32 and exFAT 11 characters, APFS 27).

## Menu

- **Rename cards automatically**: on/off switch. The icon is filled when on.
- **Rename cards now**: rename the cards already mounted.
- **Labroll…**: opens the Labroll window (below).
- **Recent renames**: Clips (list the card in the Labroll window) and Undo buttons while the card is mounted.
- **Settings**: default card names; cards without reel ID named automatically or asked with the name suggested; the card naming scheme (below); eject the card after renaming, open at login, show icon in menu bar.
- **Open log**: `~/Library/Logs/CardRename.log` (same format as `rename_card.sh`).

The same panel opens in a window on first launch, and whenever the app is opened again from Applications. Useful when the menu bar icon is hidden: behind the notch on a full menu bar, switched off in System Settings > Menu Bar, or tucked away by Bartender or Ice. While this window or the Labroll window is open, Card Rename also shows in the Dock and the app switcher. The panel shows the version (e.g. `v1.7 (8)`).

Each rename posts a notification with an **Undo** button (hover the banner, or set Card Rename to "Alerts" in System Settings > Notifications to keep the button visible). After an undo, the automation leaves that card alone until it is reformatted.

The menu bar item is saved under the name `CardRename`, so menu bar managers (Ice, Bartender) list it as its own item. A manager may file it in its hidden section at first.

## Eject and reinsert after a rename

A renamed card should be ejected and inserted again before offloading:

- Finder, Spotlight and offload apps (Silverstack, ShotPut Pro, Hedge...) may keep the old name or path of the card until it is mounted again.
- Two volumes with the same name cannot share a mount point: if a card named `E003` is already mounted, macOS mounts the next `E003` as `E003 1`, and a copy can end up reading the wrong card. Card Rename warns before giving a card a name that is already mounted.

With **Eject the card after renaming** on, the card is ejected right after the rename and the notification says *Card renamed E003 and ejected. Please remove it and insert it again.* Undo then becomes available in the menu once the card is back.

## Labroll

Cameras without a reel ID (GoPro, DJI, Sony `C0001.MP4`...) get their clips renamed the Labroll Utility way:

```
GX010001.MP4  GX020001.MP4  GX010002.MP4   (shooting order, GoPro chapters kept together)
A001C001_20261102_GOPRO.MP4  A001C002_20261102_GOPRO.MP4  A001C003_20261102_GOPRO.MP4
```

- The card itself is named after the same labroll: `A001_20261102_GOPRO`, shortened to fit the label limit (`A001_261102_GOPRO`, then `A001_GOPRO`, then `A001`). The camera part is the Cam ID field, or the camera found on the card. The labroll counter then moves to `A002`. With "Ask, name suggested" in Settings, a dialog shows the name first and lets you change it. With the Next labroll field empty, the old `MODEL_YYMMDD` name is used.
- Once the card is ready (right after the rename, or when it is inserted again if it was ejected), its clips are listed in the **Labroll** window, with their names before and after. Nothing is copied or renamed until you click.
- **Copy + rename**: clips are copied to the destination folder under their new names, each copy read back from disk and checked with xxHash64. A log `A001_YYYY-MM-DD_HHMMSS.log` (old name, new name, hash, Labroll Utility's format) is written next to them. Existing files are never overwritten; Cancel deletes the partial copy, and the same button continues later.
- **Rename only, on the card**: clips are renamed in place. Camera indexes (Sony XML, GoPro LRF/THM) no longer match, so old and new names are kept in `~/Library/Logs/CardRename-clips.log`.
- Clips or folders can also be dropped on the window, or added with **Add clips…**. Order: creation time in the MP4/MOV header, else the file creation date, then GoPro clip and chapter. MP4, MOV, and MXF unless ignored.

### Naming scheme

Clip and card names follow two templates: clips under **Clip naming scheme** in the Labroll window, cards in the panel's **Settings**. The card scheme names every card: with a reel ID, `{labroll}` is the reel (D902) and the camera is left out unless one was recognised (Sony, DJI, GoPro...); without one, it is the next labroll.

| Token | Gives | Example |
| --- | --- | --- |
| `{labroll}` | labroll of the roll | `A001` |
| `{clip:3}` | clip number, 2 to 4 digits (clips only) | `001` |
| `{date:YYYYMMDD}` | date, format picked in the **Date** menu: YYYYMMDD, YYMMDD, YYYY-MM-DD, DDMMYY, DDMMYYYY, MMDDYY | `20261102` |
| `{cam}` | Cam ID, or the camera found on the card | `GOPRO` |
| `{name}` | original clip name, without extension (clips only) | `GX010001` |
| `{random:4}` | random characters (A-Z 2-9, no 0/O 1/I), against duplicate names | `X7K2` |

Defaults: clips `{labroll}C{clip:3}_{date:YYYYMMDD}_{cam}`, cards `{labroll}_{date:YYYYMMDD}_{cam}`. Each name is a token field: drag a token chip into the name (or click it to add it at the end), drag tokens to move them, and use the arrow on a Clip, date or Random token to change its digits, format or length. Text typed between tokens is kept as is. An empty token takes its separator with it (no Cam ID gives `A001C001_20261102`). The date is the day of the copy or rename, or the recording date (cards: oldest clip on the card). A live example shows the result, and card labels are shortened to fit 11 characters (FAT32, exFAT): YYYY becomes YY, then the date, camera and original name are left out, random characters kept.

## Build

Command Line Tools are enough, no Xcode.

```bash
./build.sh            # build/Card Rename.app
./build.sh test       # naming rule tests on fake cards
./build.sh install    # copy to /Applications and open
```

The build is signed with the first certificate found in the keychain: Developer ID Application (the only one other Macs accept, once notarized), else Apple Development (macOS then keeps the app's permissions from one build to the next), else ad hoc. `SIGN_ID="..." ./build.sh` picks one. First launch: macOS asks to allow notifications and access to removable volumes; both are needed.

## Shell script

`scripts/rename_card.sh` applies the same rules from Terminal or an Automator Quick Action, without the app:

```bash
DRY_RUN=1 bash scripts/rename_card.sh /Volumes/UNTITLED   # show what would happen
bash scripts/rename_card.sh                               # rename every card in /Volumes
bash scripts/rename_card.sh undo                          # give the last renamed card its old name back
```

## Credits

Card Rename by Thomas: [github.com/Briantoma/CardRename](https://github.com/Briantoma/CardRename).

The Labroll features are based on [Labroll Utility](https://github.com/brixybrice/Labroll-Utility) by Brix.

Both appear in the app under **About** (panel footer, or Card Rename > About Card Rename while a window is open).
