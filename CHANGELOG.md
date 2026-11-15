# Changelog

All notable changes are listed here. This project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Adding and removing profiles without starting over. Running
  `install-mac.command` again shows a menu (add, remove, start over,
  refresh). `ghdp add` asks only about the new profile and leaves the others
  unchanged; `ghdp remove [name]` removes one and keeps its data unless you
  choose the Trash. A removed profile's name can't be reused while its old
  data is still there.

- `ghdp allow <profile> <owner/repo>`: let one profile commit and push to one
  repo of an owner it does not use (for example a teammate's repo), without
  opening up the rest of that owner. New optional `"repos"` list in
  `profiles.json`; `ghdp list` shows it.

## [0.1.0] - 2026-11-14

First public release, for macOS.

### Added

- One launcher app per GitHub account (`~/Applications/GitHub Desktop - <name>.app`),
  each with a colored letter badge.
- Fully separate profiles on top of the official GitHub Desktop: own login,
  own repo list, own settings. Several profiles can run side by side (up to
  20).
- Guided setup (`install-mac.command`). No config files to edit.
- Optional import of your current GitHub Desktop into the first profile, so
  that account does not need to sign in again.
- Per-profile commit identity (name and email). `~/.gitconfig` is never
  edited.
- Wrong-account guard on commit and push. It checks the email, folders and
  GitHub owners, names the right profile, and keeps the repo's own hooks
  working.
- Safety checks on every launch: pinned code-signature check of GitHub
  Desktop, private folders, refusal of risky Electron settings.
- Clean uninstall (`uninstall-mac.command`). Profile data goes to the Trash
  only if you say yes.
- Tests (bats), shellcheck-clean code, a policy check, a pre-commit secret
  check, and CI with pinned actions.
