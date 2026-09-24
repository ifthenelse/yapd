# Security policy

## Reporting a vulnerability

Please report privately, not in a public issue: open the repository's **Security** tab and choose **Report a vulnerability**. If that option isn't available, open a public issue that says only that you have a security report and asks for a private contact, without any details.

Include the Yapd version (**About Yapd** → **Copy** gives everything useful), your macOS version, and steps to reproduce. Reports are handled on a best-effort basis by a single maintainer.

## Supported versions

Only the latest version on the default branch receives fixes.

## What Yapd handles

Yapd's promise is that your audio and transcripts stay on your Mac. Anything that breaks it is in scope:

- Audio, transcripts or metadata leaving the Mac by any route.
- Recording or transcription starting without the user's action, or without the permission macOS requires.
- Files written outside the recordings folder you chose, or unsafe handling of paths and file names.
- Ways for another app or user to read recordings that they shouldn't be able to.

## How it is built

- The app source contains no networking code and no third-party packages.
- Transcription uses Apple's on-device speech recognition. The only download is the language model, fetched by macOS itself.
- Permissions: Microphone, System Audio Recording, and Accessibility, only for the global shortcut. macOS lets Yapd see key presses system-wide for that; Yapd compares each one against the shortcut and keeps none.
- It is not sandboxed, so that it can capture system audio and write to a folder you pick. It runs with the Hardened Runtime.

## Out of scope

- Recordings are ordinary files, unencrypted by Yapd. Protect them with FileVault and folder permissions.
- Attacks that need physical access, or another app that already holds the same macOS permissions.
- Builds you modified or signed yourself.
