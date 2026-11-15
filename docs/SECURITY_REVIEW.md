# Security review

An attacker-style review of the macOS version before release. The goal was
to break every security rule of the project.

- Where an attack could be tried safely, it was run for real in a throwaway
  home folder.
- Every attack that worked was fixed, and a test now repeats it on every
  change (`tests/mac/ghdp.bats`, section "attack tests").

## Results per rule

| Rule | Result |
|---|---|
| Never see, store, log, print or send tokens | ✅ No code touches the Keychain. Import skips cookies and copies no tokens. Remote URLs are shown without `user:token@`. |
| No network calls, telemetry or auto-update | ✅ Enforced by `scripts/check-policy.sh` in CI and in the pre-commit hook. |
| Least privilege | ✅ No sudo. Settings go only to the GitHub Desktop process. `~/.gitconfig` is never edited. |
| Private data folders | ✅ `700`/`600`, ACLs removed, checked and fixed on every run. |
| Strict input, no injection or path tricks | ✅ Tested with `../`, `-rf`, `$(...)`, backticks, newlines, device names and links. |
| No eval, no downloading or running code | ✅ Enforced by the policy check. |
| Linters clean | ✅ shellcheck: zero findings at style level, including the generated hook. |
| Signature check before launch | ✅ Pinned Team ID and bundle id, `--deep --strict`. |
| Wrong-account protection | ✅ Identity forced per profile, guard on commit and push. Also tested by hand in GitHub Desktop with two real accounts. |
| Clean, reversible uninstall | ✅ Data goes to the Trash only on yes. The normal GitHub Desktop data and tokens are never touched. |

## Findings and fixes

| ID | Finding | Severity | Fix |
|---|---|---|---|
| F1 | A link planted at `profiles.json.bak` made setup overwrite the file the link pointed to. | Low–Medium (needs write access to your private folder) | The old backup is removed before copying. |
| F2 | A link planted inside a launcher was written through. A launcher folder replaced by a link was followed. | Low | Linked launcher folders are refused; old files are removed before writing. |
| F3 | A remote URL containing a newline fooled the owner check. | Low | The guard refuses URLs with spaces or control characters (fail closed). |
| F4 | Import copied GitHub Desktop's cookies, which login does not need. | Low | Cookies are skipped. |
| F5 | Control characters in a folder name or URL were printed raw. | Low | They are removed from guard messages. |
| F6 | bash 3.2 ignores `set -e` inside `$(...)`. End of input could loop forever, and a path helper could return a wrong path. | Medium | Path helpers validate first. Every risky `$(...)` ends with `|| exit 1`. |
| F7 | An `rm -rf "$x/bin"` could have become `rm -rf /bin` if a variable were empty. | Medium | Every `rm -rf` uses `"${var:?}"`. |
| F8 | Mac folder names ignore case, so removing an "old" launcher by name could delete the new one. | Medium | Launchers are matched by bundle id. |
| F9 | A profile without rules could commit another profile's repo. | Medium | Another profile's folders and owners are always refused. |

A second, independent code review before release found more. All of these
are fixed and tested:

| ID | Finding | Severity | Fix |
|---|---|---|---|
| F10 | The push check also counted teammates' commits after you merged `main` into your branch (and commits merged on github.com), so normal pushes were refused. | High | Only commits that are on no remote yet are checked. |
| F11 | On a force-push where the old remote tip was unknown locally, the push check could not list the commits and let the push through. | Medium | It now checks every new commit, and stops if it cannot list them (fail closed). |
| F12 | Guard rules of removed or renamed profiles stayed on disk, so the guard could name a profile that no longer existed. | Medium | They are removed on install and launch (folder names compared without case). |
| F13 | Loading 20 profiles took over 10 seconds. | Medium | The duplicate-name check now does linear work instead of comparing every pair. |
| F14 | An unexpected failure (a broken profile gitconfig, GitHub Desktop failing to start) ended a launcher silently. | Medium–Low | Clear messages with a next step, shown in a dialog from launchers. |
| F15 | An SSH host alias remote (`work-github:org/repo`) had no owner, so the owner check was skipped. | Low–Medium | Host-alias URLs are understood. An owner that cannot be read safely stops the commit. |
| F16 | Renaming a profile from `my_work` to `my-work` left the old launcher behind. | Low | A launcher is kept only if both its bundle id and its path match a current profile. |
| F17 | Guard files were rewritten by delete-then-write, leaving a moment with no hook. A folder planted at a hook's path was not refused. | Low | Each file is written in full and moved into place in one step; folders in the way are refused. |
| F18 | A cancelled or failed import left a partial copy that later counted as profile data. | Low | The copy goes to a temporary folder, which is moved into place only when complete. profiles.json is written after it. |
| F19 | A local backup remote with a space in its path was refused. Merge commits skipped the commit checks. `~/Applications` writable by others was not refused. | Low | All three are fixed. |
| F20 | A refusal message suggests a command to copy (`ghdp allow …`) and takes the repo name from the remote URL. A name like `x;rm -rf ~` could have ended up in a command the user pastes. | Medium | The repo name is shown only if it has plain characters (letters, numbers, `. _ - /`); otherwise a placeholder is shown. The allow list matches whole `owner/name` text only, never patterns. Tested. |
| F21 | Removing a profile cleans up its guard rules. If its folder had been replaced by a link, that cleanup could delete a file named `guard.rules` in the folder the link points to. | Low | Linked profile folders are skipped. Tested, including a check that the test fails without the fix. |

## Accepted risks

| Risk | Why it is accepted |
|---|---|
| Malware running as you can read GitHub Desktop's tokens. | True without this tool too, because of GitHub Desktop's Electron switches. |
| Someone with write access to `/Applications` swaps in an **older** genuine GitHub Desktop. | Needs admin or same-user access. A minimum-version check may come later. |
| A profile signed in to the wrong account. | The guard never touches tokens, so it cannot see this. Check Settings → Accounts after signing in. |
| The guard hook uses tools from GitHub Desktop's `PATH`. | Only malware running as you could change that `PATH`. |
| `NODE_EXTRA_CA_CERTS` set for your whole session could help intercept GitHub Desktop's HTTPS. | Company proxies use it legitimately. Only someone already on your account can set it. |
| GitHub Desktop's Git hooks support (Settings → Git → Hooks, added in 3.5.5) might change which hooks folder Git uses, which could skip the guard. | **Not verified.** GitHub's pages do not say it sets a hooks path, and the guard did stop a commit in GitHub Desktop 3.6.11 during our hand tests. Plain Git does let a hooks path set through `GIT_CONFIG_PARAMETERS` win over ours, so this stays on the list until it is tested with the setting on and off. Identity (name and email) does not depend on it. |
