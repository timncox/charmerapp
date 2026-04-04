# Charmera

A macOS menu bar app for the [Kodak Charmera](https://www.kodak.com/en/consumer/product/cameras/charmera) keychain digital camera.

One click imports photos and videos, fixes orientation, converts video, and publishes to your personal GitHub Pages gallery.

**[charmera.xyz](https://charmera.xyz)**

## Install

### Homebrew

```sh
brew tap timncox/charmera
brew install --cask charmera
```

### Download

Grab the DMG from the [latest release](https://github.com/timncox/charmera/releases/latest).

## How it works

1. **Plug in** your Kodak Charmera via USB — the menu bar icon turns gold
2. **Click the K** — photos are imported, oriented, converted, and uploaded
3. **Gallery goes live** at `username.github.io/charmera-gallery`

On first launch, sign in with GitHub. Charmera creates a repo and enables GitHub Pages automatically.

## Features

- **Menu bar native** — gray (idle), gold (camera connected), blue (importing)
- **Auto orientation** — Apple Vision detects faces, text, and horizon
- **Video conversion** — AVI to MP4 via ffmpeg
- **Photos.app import** — optional, configurable in Preferences
- **Duplicate detection** — SHA-256 hashing prevents re-imports
- **Camera cleanup** — deletes from camera after successful import
- **Eject from menu** — right-click to safely eject

## Requirements

- macOS 14 (Sonoma) or later
- GitHub account

## License

MIT
