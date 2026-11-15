# Changelog

All notable changes are listed here. This project follows
[Semantic Versioning](https://semver.org/).

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
