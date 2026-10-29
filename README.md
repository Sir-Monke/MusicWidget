<h1 align="center">Music Widget <img src="MusicWidget/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" height="40" align="top" alt=""></h1>

<p align="center">
  A desktop widget for macOS that shows what's playing in Apple Music, with back, play/pause and skip.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-D6943D?logo=apple&logoColor=white" alt="macOS 15+">
  <img src="https://img.shields.io/badge/licence-MIT-D6943D" alt="MIT licence">
  <img src="https://img.shields.io/badge/built%20with-WidgetKit-D6943D?logo=swift&logoColor=white" alt="Built with WidgetKit">
</p>

## Install

1. Download `MusicWidget.zip` from the [latest release](https://github.com/Sir-Monke/MusicWidget/releases/latest) and unzip it.
2. Open **Music Widget**. It moves itself into Applications and starts at login. It has no window.
   If macOS won't open it the first time, go to System Settings › Privacy & Security and click **Open Anyway**.
3. Click **OK** when macOS asks to let Music Widget control Music.
4. Right-click the desktop, choose **Edit Widgets…**, search **Music Widget** and add it.

## What it does

- **Two tiles wide.** Album cover on the left, song and artist on the right, controls underneath.
- **Keeps up.** Changes the moment Music skips, pauses or starts a new song.
- **Controls Music.** Back, play/pause and skip, straight from the desktop.
- **Private.** Talks only to Music on your Mac. When a streamed song has no cover, it looks one up on the iTunes Search API.

## How it works

A widget can't talk to Music, so the app does it for the widget. It reads Music with AppleScript, saves the song to `~/Library/Application Support/MusicWidget/now-playing.json` and tells the widget to refresh. The widget's buttons send commands back to the app.

## Build from source

Open `MusicWidget.xcodeproj` in Xcode and press Run. Music Widget copies itself into Applications, opens from there and starts at login. To check the logic:

```sh
/Applications/MusicWidget.app/Contents/MacOS/MusicWidget --selftest
```

## Remove

Remove the widget from the desktop, quit Music Widget in Activity Monitor, then drag it from Applications to the Bin.

## Licence

[MIT](LICENSE)
