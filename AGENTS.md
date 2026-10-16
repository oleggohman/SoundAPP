# Project instructions

Follow the Boost instructions in `/Users/oleggo/.codex/BOOST.md`.

## DMG release tags

- After every successful DMG build and verification, create an annotated Git tag
  in the format `v<VERSION>-build-<BUILD>` (for example, `v1.2.0-build-18`).
- Read VERSION and BUILD from the packaged app's `CFBundleShortVersionString`
  and `CFBundleVersion`, so the tag matches the DMG filename and contents.
- Build release DMGs from a clean committed source checkout and tag the exact
  commit used to build the app. With `--skip-build`, verify the existing app's
  source commit before tagging; do not assume it is the current HEAD.
- Never move or overwrite an existing release tag. If it already identifies the
  same release commit, retain it; otherwise stop and report the conflict.
- Report the DMG path and tag when finished. Do not push tags unless requested.

## GENERAL
- Add the current model name to commit message 
