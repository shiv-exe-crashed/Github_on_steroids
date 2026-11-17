# Windows

The Windows version does the same job as the Mac one: one GitHub Desktop per
GitHub account, each with its own login, repo list and settings, its own
taskbar icon, and a guard against wrong-account commits and pushes.

You need Windows 10 or 11 and [GitHub Desktop](https://desktop.github.com)
installed for your Windows user. Nothing else: no admin rights, no downloads.

## Install

1. Get the project (clone it, or download the ZIP and unzip it).
2. Double-click **`install-windows.cmd`**, or in PowerShell:

   ```powershell
   powershell -ExecutionPolicy Bypass -File windows\ghdp.ps1 setup
   ```

3. Answer the questions. They are the same as on the Mac, see
   [USAGE.md](USAGE.md#what-each-setup-question-means). Press **Enter** to accept
   the value shown in `[brackets]`.
4. Open the shortcut from the **Start menu** (folder *GitHub Desktop Profiles*)
   and sign in once per profile.

### Sign in to a profile

1. In your browser, check you are on the right GitHub account.
2. Open the profile's Start menu shortcut and click **Sign in to GitHub.com**,
   then **Continue With Browser**, then **Authorize**.
3. On **Configure Git** choose **Configure manually**, then **Finish**.
4. Check **File > Options > Accounts** shows the right account.
5. In **File > Options > Git**, keep "Load Git hook environment variables from
   shell" unticked.

Windows hands the browser's reply to a link, `x-github-desktop-auth://`. Normally
that starts a *new plain* GitHub Desktop, which is why a second account cannot
sign in. This tool takes over that one link and passes the reply to the profile
you were just using. It also puts the link back the way GitHub Desktop had it
when you uninstall.

## One taskbar icon per account

Each profile window gets its own taskbar button, so you can tell them apart and
switch between them:

- its own **icon**: GitHub Desktop with a colored badge and the profile's first letter
- its own **title**: "GitHub Desktop - work"
- clicking the Start menu shortcut of a profile that is already open just brings
  its window to the front

To keep a profile on the taskbar, open it, right-click its taskbar button and
choose **Pin to taskbar**. The pinned button keeps its icon and opens that same
profile next time.

## Commands

| Command | What it does |
|---|---|
| `install-windows.cmd` | Guided setup. With profiles already there it shows a menu: add, remove, start over, refresh. |
| `windows\ghdp.ps1 add` | Add one more profile; the others stay as they are |
| `windows\ghdp.ps1 remove [name]` | Remove a profile (its data is kept unless you choose the Recycle Bin) |
| `windows\ghdp.ps1 list` | Your profiles, their guard rules, and a health check |
| `windows\ghdp.ps1 allow <name> <owner/repo>` | Let a profile use one repo of an owner it doesn't use |
| `windows\ghdp.ps1 install` | Rebuild shortcuts and icons after editing `profiles.json` by hand |
| `windows\ghdp.ps1 launch <name>` | Open a profile (add `-DryRun` to only show the command, `-Plain` for no own taskbar icon) |
| `uninstall-windows.cmd` | Remove everything this tool made (it asks first) |

`profiles.json` has the same format as on the Mac and lives in
`%LOCALAPPDATA%\gh-desktop-profiles\profiles.json`. Folder rules can be
`~/work` or a full path such as `D:\work`.

## What is on your PC

```
%LOCALAPPDATA%\gh-desktop-profiles\          (only you can open it)
├── profiles.json            your profiles
├── active.txt               the profile you used last (where a sign-in reply goes)
├── bin\
│   ├── ghdp.ps1             the installed copy of the tool that shortcuts run
│   ├── ghdp-run.exe         tiny helper: starts the tool without a console window
│   └── ghdp-native.dll      tiny helper: taskbar identity, window icon, badge drawing
└── profiles\<name>\
    ├── desktop-data\        GitHub Desktop's data for this profile
    ├── gitconfig            this profile's Git settings
    ├── guard.rules          this profile's guard rules
    ├── hooks\               the wrong-account guard
    └── icon.ico             this profile's badge icon

%APPDATA%\Microsoft\Windows\Start Menu\Programs\GitHub Desktop Profiles\
    GitHub Desktop - <name>.lnk                one shortcut per profile
```

The two helper programs are built once, on your PC, from the source inside
`ghdp.ps1`, with the C# compiler that ships with Windows. Nothing is downloaded.
The tool also sets one per-user registry value: the command for the
`x-github-desktop-auth` link (`HKCU\Software\Classes\x-github-desktop-auth`).

## How it differs from the Mac version

| Mac | Windows |
|---|---|
| A copy of GitHub Desktop per profile in `~/Applications`, one Dock icon each | One Start menu shortcut per profile; each running window gets its own taskbar button, icon and title |
| Sign-in reply reaches the running profile window by itself | The tool routes the `x-github-desktop-auth` reply to the profile you last used |
| Logins in the Keychain | Logins in Windows Credential Manager (never touched) |
| `launch <name> --plain` | `launch <name> -Plain` |
| Trash | Recycle Bin |

The guard, the folder/owner/repo rules, `allow`, `add`, `remove`, `list`,
`uninstall` and the setup questions work the same way.
