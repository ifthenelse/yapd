# Yapd: instructions for AI coding agents

## After every iteration, bump the version and the build number

An iteration is one round of changes handed back to the user. Before handing it back:

1. Bump the version: `scripts/version set X.Y.Z`. Patch for fixes, minor for new features. Leave major bumps to the user.
2. Bump the build number: `scripts/version bump`.
3. Rebuild so the numbers reach the app (`xcodegen generate` only if files were added or removed):
   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Yapd.xcodeproj -scheme Yapd -destination 'platform=macOS,arch=arm64' build`
4. Say the new version and build in your summary, e.g. "0.2.1 (4)".

`Config/Version.xcconfig` is the single source of truth. Never edit it by hand, and never edit the version keys in `Info.plist` or `project.yml`; use `scripts/version`. `scripts/version` on its own prints the current numbers, which also show in **About Yapd**.
