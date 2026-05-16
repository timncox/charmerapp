---
status: active
last_touched: 2026-05-16
deploy: cd app && ./build.sh && ./dmg.sh
---

# charmera

macOS menu bar app for the Kodak Charmera keychain camera — imports photos from a connected Charmera and pushes them to a gallery.

## Release

`deploy:` builds + notarizes the DMG. The rest of a public release:

1. Bump `CFBundleShortVersionString` in `app/Info.plist` BEFORE running `deploy:`. `dmg.sh` packages whatever `build.sh` produced — version bumps after `build.sh` ship with the wrong label.
2. Run `deploy:` — `build.sh` builds + signs `Charmera.app`, `dmg.sh` packages + notarizes + staples `Charmera.dmg`.
3. `shasum -a 256 app/build/Charmera.dmg` for the hash.
4. `git tag vX.Y.Z && git push origin vX.Y.Z`.
5. `gh release create vX.Y.Z app/build/Charmera.dmg --repo timncox/charmerapp`.
6. Bump version + sha256 in `timncox/homebrew-charmera/Casks/charmera.rb`, commit, push.

Notarization needs the `charmera-notary` keychain profile. If `dmg.sh` returns 401, refresh via `xcrun notarytool store-credentials charmera-notary --apple-id timcox@gmail.com --team-id P5EK689L33` with a fresh app-specific password from https://account.apple.com.

> _Add architecture / stack / conventions to this file as you next work in the project._
