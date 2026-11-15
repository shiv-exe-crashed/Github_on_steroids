# Threat model

What we protect, who might attack, how each attack is stopped, and what
this tool honestly cannot protect against. This covers the macOS version.

## What we protect

| Asset | Why it matters |
|---|---|
| Login tokens of each GitHub account | Whoever has a token can act as you on GitHub. |
| Private repo code | Work code must never reach a personal account, or the other way round. |
| Which account and email is used | A wrong commit email or wrong push leaks your identity and can break company rules. |
| Profile data (repo lists, account names) | Shows what you work on. |
| Your normal GitHub Desktop setup | The tool must never break or change it. |

## Who might attack

| Attacker | Example |
|---|---|
| Malware running as you | A bad package or a fake app. |
| A malicious repository | Tricky remote URLs, folder names or hooks. |
| A malicious download | A fake copy of this tool, or a tampered GitHub Desktop. |
| A wrong click | Committing work code in the personal profile, in a hurry. |
| Another user on the same Mac | A second macOS user account. |
| A bad contribution | A pull request that sneaks in a network call or a secret. |

## Attacks and defences

| # | Attack | Defence |
|---|---|---|
| T1 | The tool leaks a token. | The tool has no code that reads, stores, logs, prints or sends tokens. They stay in the macOS Keychain, managed by GitHub Desktop. There are no network calls; `scripts/check-policy.sh` fails the build if a network command or `eval` appears. |
| T2 | A fake GitHub Desktop steals tokens. | Before every launch: `codesign --verify --deep --strict`, pinned to GitHub's Team ID `VEKTX9H2N7` and bundle id `com.github.GitHubClient`. If it fails, nothing opens. |
| T3 | Electron debug switches. GitHub Desktop ships with `RunAsNode`, `NODE_OPTIONS` and `--inspect` enabled, so code can be run inside it. | Only fixed arguments are passed. Launch is refused if `NODE_OPTIONS` or `ELECTRON_RUN_AS_NODE` is set (checks both the environment and `launchctl getenv`). The hardened runtime blocks `DYLD_*` injection. |
| T4 | Launcher hijack (a fake `codesign` or `open` on `PATH`, an edited launcher). | Tools are called by absolute path and `PATH` is reset. Launchers run an installed copy of the tool in a private folder, which refuses to run if it is not yours or is writable by others. Launchers are owner-only. |
| T5 | Path tricks and injection through names or config (`../`, `$(...)`, `;`, a leading `-`). | Strict patterns for profile names, emails, Git names, folders and owners. Unknown config keys are refused. Values are never pasted into commands; every path is quoted. There is no `eval`. A home path with unusual characters stops the tool. |
| T6 | A symlink planted to redirect a write. | Folders must be real folders. Files the tool owns are removed before being rewritten, so a planted link is never written through. |
| T7 | Another macOS user reads profile data. | Folders are `700` and files `600`, extra ACL rules are removed, and this is checked and fixed on every run. Data lives in `~/Library/Application Support`, outside iCloud Drive. |
| T8 | Malicious repo values in the guard (remote URL, folder name). | The guard (plain POSIX sh) only compares and prints repo values. It never runs them. URLs are shown without `user:token@`, control characters are removed, and a URL with spaces or control characters is refused (fail closed). |
| T9 | Wrong account, wrong email. | Identity is forced per profile (`GIT_AUTHOR_*`, `GIT_COMMITTER_*`). The guard stops commits and pushes with another email, and repos in another profile's folders or owned by another profile's GitHub owner. A repo's own hooks setting (husky) cannot turn it off. A person can still click past the guard on purpose in GitHub Desktop (see README, "Good to know"). `ghdp allow` opens one named repo (exact `owner/name` match, nothing broader). Launchers have different names and colored badges. |
| T10 | Signing a profile in with the wrong account. | Setup and the docs say: check the browser account first, then Settings → Accounts after signing in. The guard catches the email side. |
| T11 | "Open in GitHub Desktop" links open the wrong profile. | The guard stops the first commit or push there and names the right profile. |
| T12 | A fake release, or a bad pull request. | Zero dependencies at run time. CI uses read-only permissions, actions pinned to commit SHAs, and checksum-verified tools. gitleaks and the policy check run in CI, and the pre-commit hook blocks staged secrets. |
| T13 | Importing your current GitHub Desktop copies something harmful or damages it. | Read-only, into a new folder only. Caches, logs, cookies, lock files and outside links are skipped. It waits until GitHub Desktop releases its database locks. |
| T14 | Uninstall deletes data by mistake or breaks your normal GitHub Desktop. | It asks first and removes only this tool's launchers (matched by bundle id) and its installed copy. Profile data goes to the Trash only if you say yes. It never touches the normal GitHub Desktop data or the Keychain. Every `rm -rf` is guarded against empty paths. |
| T15 | GitHub Desktop's own usage stats: each new profile looks like a new install. | Not our code. Setup tips say: untick usage stats in Settings → Advanced in each profile. |
| T16 | The one-line install downloads a ZIP of the `main` branch from github.com and starts the setup, so whoever controls that branch controls what runs. | The line uses HTTPS to github.com only, is explained in the README, asks for no password, and offers other ways for people who want to read the code first. A release tag will replace `main`, so everyone gets the same reviewed code. Accepted until then. |
| T17 | `--own-icon` runs a private copy of GitHub Desktop, which could be swapped or tampered with. | The copy is an exact clone of the verified app and must pass the same GitHub signature check (pinned Team ID and bundle id) without `--strict`, which only tolerates the extra icon file macOS adds: a changed, missing or fake file still fails. It is re-checked on every launch and made again if it fails, if GitHub Desktop updated, or if the icon changed. A link in its place is replaced, never followed. Experimental. |

## Honest limits

1. **Malware already running as you can read GitHub Desktop's tokens,
   with or without this tool**, because of the Electron switches in T3. We
   add no new way in, but only GitHub can close this.
2. **Profiles are separate, but not a security wall.** All profiles run the
   same signed app, so the Keychain treats them as one app. Tokens are
   separated by GitHub username. If you sign in to the **same** account in
   two profiles, they share one token: signing out in one signs out the
   other.
3. **Check-then-launch gap.** There is a split second between our signature
   check and the launch. macOS checks signatures again at launch, which
   narrows it.
4. **The guard cannot see which account a profile is signed in to.** It
   never touches tokens, by design. Check Settings → Accounts once after
   signing in.
5. **Bugs in GitHub Desktop, Git or GitHub**, and an administrator on your
   Mac, are outside what this tool can control.
