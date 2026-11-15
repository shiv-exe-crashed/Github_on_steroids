# Using it day to day

The [README](../README.md) covers install and the basics. This page holds the details.

## What each setup question means

Press **Return** to accept the value shown in `[brackets]`. Never type a
password here: you sign in later, inside GitHub Desktop.

| The wizard asks | What it means | What to type |
|---|---|---|
| **What do you want to do?** *(only if you already have profiles)* | A small menu: **1** adds a profile (only the new one is asked about), **2** removes one, **3** starts over and replaces all, **4** just refreshes the launchers. | **1** to add an account |
| **Does this look right?** *(quick setup, only if GitHub Desktop is signed in and your Git email is a GitHub noreply email)* | A summary of the guessed answers: profile `personal`, your name and email, and your GitHub username as the guard's owner. | **y** (press **Return**). **n** lets you answer each question yourself. |
| **Copy them into your first profile…?** *(only if GitHub Desktop is already set up)* | Turn your current GitHub Desktop (its login and repo list) into your first profile, so that account doesn't sign in again. The original is never changed. | **y** (recommended) |
| **Name for profile 1** | A short name for this profile. It becomes the launcher name, e.g. "GitHub Desktop - work". | `work`, `personal`, `opensource`… (letters, numbers, `-` and `_`) |
| **Name on commits** | The author name shown on commits from this profile. | Your name |
| **Email on commits for this account** | The email on commits from this profile. | That account's email, e.g. its GitHub **noreply** email (github.com → Settings → Emails). |
| **Folders used ONLY for this account's repos** *(optional)* | Where this account's repos live. The guard then knows a repo there belongs to this profile. | e.g. `~/work`. **Skip** it if work and personal repos share a folder. |
| **GitHub owners for this account** *(recommended)* | The GitHub username and organizations this account works with: the part after `github.com/` in a repo link. | e.g. `my-company, my-work-username` |
| **Add GitHub owners now?** *(only if you skipped both)* | Without folders or owners, the guard can only check the email. | **y** (recommended) |
| **Add another profile?** | Set up your next account. | **y** for each extra account, then **n** |
| **Create these profiles?** | A last look at the summary. | **y** |
| **Open "GitHub Desktop - …" now?** *(at the end)* | Opens the new profile for you, so you don't have to find it in Finder. | **y** (press **Return**) |
| **Please quit GitHub Desktop now** *(when copying)* | The copy needs GitHub Desktop closed, so its data is complete. | Press **Cmd + Q** in GitHub Desktop, then **Return** |

> [!TIP]
> If you used to switch accounts inside one GitHub Desktop, the copied profile
> also gets the other account's repos. Setup reminds you to remove them there
> (right-click → **Remove**; the files stay on your disk) and to add them in
> the right profile (**File → Add Local Repository**).

---

## Add or remove an account

Double-click **`install-mac.command`** again and press **Return** (the first
choice, **1) Add a profile**). You are asked only about the new account: a
name, its commit email, and its GitHub owner. **Your other profiles are not
asked about and not changed.** Then open the new launcher and sign in once.

Terminal users: `mac/ghdp add`. To take an account away: choose **2** in the
same menu, or run `mac/ghdp remove <name>` (its data is kept unless you ask
for the Trash).

---

## Share one repo with another account

Teams share repos: a teammate's personal account, a client's organization, or
your own other account added as a **collaborator**. The guard blocks these by
default, because the owner is not one of the profile's owners. Allow **just
that one repo** for the profile that should use it:

```bash
mac/ghdp allow work some-owner/shared-repo
```

- It takes effect at once. No restart, no setup.
- Only that repo is allowed. Other repos of `some-owner` stay protected, and
  the email check still applies.
- You can paste the repo link too: `mac/ghdp allow work https://github.com/some-owner/shared-repo`.
- See what you allowed with `mac/ghdp list`. Undo it by deleting the repo from
  `"repos"` in `profiles.json`, then run `mac/ghdp install`.

> [!NOTE]
> The guard is only a safety net on your Mac. Whether an account **may** push
> to a repo is decided by GitHub: add the account as a collaborator there first.

---

## All commands

The launchers are all you need day to day. For everything else:

| Command | What it does |
|---|---|
| `bash install-mac.command` | Guided setup. With profiles already there it shows a menu: add, remove, start over, refresh. |
| `mac/ghdp add` | Add one more profile; the others stay as they are |
| `mac/ghdp remove [name]` | Remove a profile (its data is kept unless you choose the Trash) |
| `mac/ghdp list` | Your profiles, their guard rules, and a health check |
| `mac/ghdp allow <name> <owner/repo>` | Let a profile use one repo of an owner it doesn't use |
| `mac/ghdp install` | Rebuild launchers after editing your profiles by hand |
| `mac/ghdp launch <name>` | Open a profile from Terminal (add `--dry-run` to only show the command) |
| `bash uninstall-mac.command` | Remove everything this tool made (it asks first) |

<details>
<summary><b> Prefer editing settings by hand?</b></summary>

Profiles live in `~/Library/Application Support/gh-desktop-profiles/profiles.json`.
Edit it, then run `mac/ghdp install`:

```json
{
  "version": 1,
  "profiles": [
    { "name": "work", "gitName": "Your Name", "gitEmail": "you@company.com",
      "owners": ["my-company", "my-work-username"] },
    { "name": "personal", "gitName": "Your Name", "gitEmail": "12345+you@users.noreply.github.com",
      "owners": ["my-personal-username"] }
  ]
}
```

Optional per profile: `"folders": ["~/work"]`, `"owners": [...]` and
`"repos": ["some-owner/shared-repo"]` (single repos of other owners; see
[`mac/ghdp allow`](#share-one-repo-with-another-account)).
</details>

## Updating

 run the [one-line install](../README.md#install)
again (or, if you cloned it, **Fetch** → **Pull** in GitHub Desktop). Then,
when the setup shows its menu, choose **4** ("Nothing, just refresh the
launchers"). Your launchers are refreshed and your profiles stay.
