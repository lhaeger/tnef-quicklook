# TNEF Preview: notes for Claude

Quick Look preview extension for winmail.dat (TNEF) on macOS. README.md covers what it does and how it is built; this file covers what to keep in mind while changing it.

## Layout

- `project.yml`: XcodeGen spec. The `.xcodeproj` is generated and git-ignored, so never edit it; change `project.yml` and run `xcodegen generate`.
- `TNEFPreview/`: host app (SwiftUI, one window). It only exists so macOS registers the extension.
- `TNEFPreviewExtension/PreviewProvider.swift`: data-based `QLPreviewProvider`, registered for `com.microsoft.tnef`.
- `TNEFKit/`: Swift package.
  - `TNEFKit`: parser, Foundation and CoreFoundation only, no AppKit.
  - `TNEFRender`: HTML page builder (AppKit, ImageIO).
  - `tnef-extract`, `tnef-render`: debug command-line tools.
  - Tests use Swift Testing.
- `scripts/make_fixtures.py`: generates the synthetic test files, including a small LZFu compressor and a CFB writer.
- `scripts/install.sh`: build, install to `~/Applications`, register.

## Commands

```bash
swift test --package-path TNEFKit
./scripts/install.sh
python3 -I scripts/make_fixtures.py TNEFKit/Tests/TNEFKitTests/Fixtures   # deterministic output
```

## Rules

- **The parser must never trap on input.** All reads go through `ByteReader`, which throws. Lengths are checked against the remaining bytes before allocating (`ByteReader.length()`). Chain walks in `CompoundFile` are bounded. Damage after the TNEF header becomes a warning, not a thrown error.
- **Every `.dat` file reaches the extension**, because macOS maps the extension to `com.microsoft.tnef`. Keep the 4-byte signature check before any full read.
- **Other apps can claim `.dat`.** Letter Opener declares `com.creativeinaustria.letteropener.winmail`, and macOS then labels some files with that type; the extension only sees types listed in `QLSupportedContentTypes` (`project.yml`). If a valid TNEF file shows the generic view, check its type with `mdls -name kMDItemContentType <file>` before debugging the parser.
- **Previews must not touch the network.** Anything that loads remote content has to go through `HTML.sanitizeMailBody`.
- **Test fixtures stay synthetic.** Extend `make_fixtures.py` instead of committing real mail. Check new parser behaviour against the `tnef` CLI (`brew install tnef`) using `tnef-extract`.
- **Inline pictures:** the n-th `\objattph` in the RTF body belongs to the n-th attachment sorted by `renderingPosition`; attachments without a position are not inline.

## Gotchas

- `qlmanage -p` crashes ("key cannot be nil") with app-extension previews. Verify in Finder or Mail instead, or render with `tnef-render` and look at the HTML.
- After reinstalling, Quick Look may keep the old extension process running. `scripts/install.sh` restarts it; by hand, run `pkill -f TNEFPreviewExtension; killall QuickLookUIService; qlmanage -r`.
- Finder and Mail cache an extension's XPC service name per process. After the bundle identifier changes they keep connecting to the old name ("extension connection was invalidated" in the log) until the user relaunches them. Avoid changing identifiers.
- Build output must stay in a `.noindex` folder (`build/DerivedData.noindex`). Otherwise Spotlight finds the built app, LaunchServices registers its extension as a second copy with the same identifier, and Quick Look may pick either one.
- To read the log, use `/usr/bin/log`: in zsh, `log` is a builtin. From the Claude desktop app the log store is not readable ("Operation not permitted"), so ask the user to run `/usr/bin/log stream --style compact --predicate 'process == "TNEFPreviewExtension"'` in the Terminal panel and read it from there.
- A sandbox report about `NSSpellChecker` / `mul-xpc (Apple)_OpenStep` about 10 s after the extension starts is AppKit's spell-server preflight timer, not a rendering problem.
- Install with `ditto` (in place). The user's shell aliases `rm`, `cp` and `mv` to interactive mode, so use `command cp` and friends in ad-hoc commands.
- Builds are ad-hoc signed (`CODE_SIGN_IDENTITY = -`); there is no team ID.

## Commits

Describe only the change itself. No attribution footer, and no future plans or rejected alternatives. This repo's `user.email` is the GitHub noreply address; keep it.
