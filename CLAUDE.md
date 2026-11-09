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
- **Previews must not touch the network.** Anything that loads remote content has to go through `HTML.sanitizeMailBody`.
- **Test fixtures stay synthetic.** Extend `make_fixtures.py` instead of committing real mail. Check new parser behaviour against the `tnef` CLI (`brew install tnef`) using `tnef-extract`.
- **Inline pictures:** the n-th `\objattph` in the RTF body belongs to the n-th attachment sorted by `renderingPosition`; attachments without a position are not inline.

## Gotchas

- `qlmanage -p` crashes ("key cannot be nil") with app-extension previews. Verify in Finder or Mail instead, or render with `tnef-render` and look at the HTML.
- After reinstalling, Quick Look may keep the old extension process running. Run `pkill -f TNEFPreviewExtension; qlmanage -r` and close any open preview.
- Install with `ditto` (in place). The user's shell aliases `rm`, `cp` and `mv` to interactive mode, so use `command cp` and friends in ad-hoc commands.
- Builds are ad-hoc signed (`CODE_SIGN_IDENTITY = -`); there is no team ID.

## Commits

Describe only the change itself. No attribution footer, and no future plans or rejected alternatives. This repo's `user.email` is the GitHub noreply address; keep it.
