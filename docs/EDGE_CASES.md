# Edge cases handled

Every row below is handled on purpose. Almost all are covered by automated tests; the rest
(like a double-click on a launcher) were checked by hand.

<details open>
<summary><b> Git and GitHub</b></summary>

| Situation | What happens |
|---|---|
| A repo uses its own hooks folder (husky) | The guard can't be switched off by it, and the repo's hooks still run. |
| You merge `main` into your branch, or merge pull requests on github.com | Never flagged: only your **new** commits (not on GitHub yet) are checked. |
| Merge commits | Checked like normal commits. |
| SSH host aliases (`work-github:company/repo`) | Understood; the owner is checked as usual. |
| A force-push the guard can't fully see | The push is stopped instead of guessed. |
| A token hidden in a remote URL (`https://user:token@…`) | Never shown on screen. |
| A remote URL with a newline or odd characters | Refused safely, never run. |
| A remote URL with tricks (`../`, `%2f`, `?`, `#`, spaces) meant to look like another owner | Refused: the guard only trusts URLs it can read exactly as Git will use them. |
| A local backup remote with spaces in its path | Works. |
| A repo opened from a browser link lands in the wrong profile | The first commit is stopped, naming the right profile. |

</details>

<details open>
<summary><b> Profiles and setup</b></summary>

| Situation | What happens |
|---|---|
| Two names that differ only in capitals (`Work` vs `work`) | Treated as the same, because Mac folders ignore case. |
| A profile renamed (`my_work` → `my-work`) or removed | Its old launcher and guard rules are cleaned up. |
| A typo in a setting (`gitEmial`) | Refused with a clear message, never silently ignored. |
| Wrong types, nested objects, line breaks in settings | Each is refused with a message that says what to fix (21 broken-config cases tested). |
| Setup run twice | Nothing breaks or doubles up. Settings GitHub Desktop added to a profile are kept. |
| You add a profile later | Your other profiles are not asked about again and not changed: logins, repos, settings and guard rules stay. |
| You remove a profile | Its launcher and guard rules go. Its data stays on your Mac unless you choose the Trash, and never while its window is open. |
| A removed profile's name is added again | Refused while its old data is still there, so a new account can never inherit an old login by accident. |
| Setup cancelled before you confirm | Nothing is written. |
| A copy interrupted halfway | The partial copy never counts as profile data. |
| GitHub Desktop still open while copying | Setup waits until it's closed, so the data is complete. |
| A profile app clicked twice, or clicked while its window is hidden | No second window: the existing one comes to the front. |
| 20 profiles | Still fast: settings load in about a second. |

</details>

<details open>
<summary><b> Safety</b></summary>

| Situation | What happens |
|---|---|
| A damaged or fake GitHub Desktop | Its digital signature (proof that GitHub made it) fails the check, so nothing opens. |
| A risky setting (`NODE_OPTIONS`) is on for your whole Mac session | The launch is refused, with steps to fix it. |
| A shortcut (symlink) planted to trick the tool into writing somewhere else | Refused, or replaced, never followed. |
| Another user can write to `~/Applications` | Launchers are not installed there until it's fixed. |
| A profile folder with loose permissions | Fixed to owner-only on the next run. |
| An empty variable in a delete | Impossible: every recursive delete is guarded. |

</details>

---
