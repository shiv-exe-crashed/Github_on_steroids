#Requires -Version 5.1
<#
.SYNOPSIS
    gh-desktop-profiles for Windows.

.DESCRIPTION
    Opens the official GitHub Desktop with a separate profile per GitHub
    account. Each profile has its own login, its own repo list and its own
    settings. Plain Windows PowerShell 5.1. No dependencies.

    Security promises (details in THREAT_MODEL.md):
      - never reads, stores, logs or prints tokens or passwords
      - makes no network calls
      - needs no admin rights and never edits your global Git config

    Commands:
      ghdp.ps1 setup                      guided setup: asks for your profiles
      ghdp.ps1 init                       create your profiles.json from the example
      ghdp.ps1 install                    set up profile folders and Start menu shortcuts
      ghdp.ps1 launch <name> [-DryRun]    open GitHub Desktop with a profile
      ghdp.ps1 list                       show your profiles and their status
      ghdp.ps1 help                       show this help
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'init', 'install', 'launch', 'list', 'help')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Name = '',

    # Show what launch would run, without changing or opening anything.
    [switch]$DryRun,

    # Set by the shortcuts: also show errors in a dialog box.
    [switch]$Gui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Version = '0.1.0-dev'
$script:MaxProfiles = 20
$script:OnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$script:Publisher = 'GitHub, Inc.'

# ------------------------------------------------------------------ messages

function Write-Line([string]$Text) { [Console]::Out.WriteLine($Text) }

# Stop with a simple message and the next step to fix it.
function Fail([string]$Problem, [string]$Next) {
    $err = New-Object System.Exception $Problem
    $err.Data['Next'] = $Next
    throw $err
}

function Show-ErrorDialog([string]$Text) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($Text, 'GitHub Desktop Profiles', 'OK', 'Error')
    } catch {
        [Console]::Error.WriteLine($Text)
    }
}

# ---------------------------------------------------------------- validation
# Note: "\z" means the true end of the text. In .NET, "$" would also match
# before a final newline, which would let "office<newline>" through.

# Profile name: 1-32 letters, numbers, - or _, starting with a letter or
# number. Windows device names are refused.
function Test-ProfileName([string]$Value) {
    if ($Value -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_-]{0,31}\z') { return $false }
    return ($Value.ToUpperInvariant() -cnotmatch '\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z')
}

function Test-Email([string]$Value) {
    return ($Value.Length -le 254 -and $Value -cmatch '\A[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\z')
}

# Git author name: 1-100 bytes. No control characters, quotes or
# backslashes. No space or "-" at the start, no space at the end.
function Test-GitName([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    if ([System.Text.Encoding]::UTF8.GetByteCount($Value) -gt 100) { return $false }
    if ($Value -match '[\x00-\x1F\x7F"\\]') { return $false }
    if ($Value.StartsWith(' ') -or $Value.EndsWith(' ') -or $Value.StartsWith('-')) { return $false }
    return ($Value -cne 'CHANGE ME')
}

# Names that differ only in capital letters or "-" vs "_" count as the same.
function Get-NormalName([string]$Value) { return $Value.ToLowerInvariant().Replace('_', '-') }

# A folder rule: "~/..." or a full path, no "..", "." or empty parts.
function Test-Folder([string]$Value) {
    if ([string]::IsNullOrEmpty($Value) -or $Value.Length -gt 200 -or $Value -match '["%\x00-\x1F]') { return $false }
    if (-not ($Value -cmatch '\A~[\\/]' -or [System.IO.Path]::IsPathRooted($Value))) { return $false }
    $parts = @($Value -split '[\\/]' | Select-Object -Skip 1)
    return (-not ($parts -contains '..' -or $parts -contains '.' -or $parts -contains ''))
}

# A GitHub user or organization name.
function Test-Owner([string]$Value) { return ($Value -cmatch '\A[A-Za-z0-9][A-Za-z0-9-]{0,38}\z') }

function Assert-ProfileName([string]$Value) {
    if (-not (Test-ProfileName $Value)) {
        Fail "Profile name `"$Value`" is not allowed." 'Use 1-32 letters, numbers, - or _, starting with a letter or number.'
    }
}

# --------------------------------------------------------------------- paths
# Every path is built only from LOCALAPPDATA / APPDATA and a validated name.

# Refuse paths with characters that could change meaning inside a shortcut
# or a command line (quotes, %VAR% expansion, control characters).
function Assert-SafePath([string]$Path, [string]$What) {
    if ([string]::IsNullOrEmpty($Path) -or -not [System.IO.Path]::IsPathRooted($Path) -or $Path -match '["%\x00-\x1F]') {
        Fail "The $What path has unusual characters, so this tool stopped to stay safe." 'Please open an issue on the project page.'
    }
}

function Get-BaseDir {
    Assert-SafePath $env:LOCALAPPDATA 'LOCALAPPDATA'
    return (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'gh-desktop-profiles')
}
function Get-ConfigPath { return (Join-Path -Path (Get-BaseDir) -ChildPath 'profiles.json') }
function Get-BinPath { return (Join-Path -Path (Join-Path -Path (Get-BaseDir) -ChildPath 'bin') -ChildPath 'ghdp.ps1') }
function Get-ProfileDir([string]$ProfileName) {
    Assert-ProfileName $ProfileName
    return (Join-Path -Path (Join-Path -Path (Get-BaseDir) -ChildPath 'profiles') -ChildPath $ProfileName)
}
function Get-DataDir([string]$ProfileName) { return (Join-Path -Path (Get-ProfileDir $ProfileName) -ChildPath 'desktop-data') }
function Get-GitConfigPath([string]$ProfileName) { return (Join-Path -Path (Get-ProfileDir $ProfileName) -ChildPath 'gitconfig') }
function Get-ShortcutDir {
    Assert-SafePath $env:APPDATA 'APPDATA'
    return (Join-Path -Path $env:APPDATA -ChildPath 'Microsoft\Windows\Start Menu\Programs\GitHub Desktop Profiles')
}
function Get-ShortcutPath([string]$ProfileName) {
    Assert-ProfileName $ProfileName
    return (Join-Path -Path (Get-ShortcutDir) -ChildPath "GitHub Desktop - $ProfileName.lnk")
}

# --------------------------------------------------------------- permissions

function Test-ReparsePoint([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

# Owner-only access: only your Windows account, with inherited rules turned
# off. Checked and fixed on every run. (Skipped when the tests run on Mac.)
function Protect-PrivatePath([string]$Path, [switch]$IsFile) {
    if (-not $script:OnWindows) { return }
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    if ($acl.GetOwner([System.Security.Principal.SecurityIdentifier]) -ne $me) {
        Fail "`"$Path`" is not owned by you." 'Move it somewhere else, then try again.'
    }
    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    $ok = $acl.AreAccessRulesProtected -and $rules.Count -eq 1 -and
        $rules[0].IdentityReference -eq $me -and
        $rules[0].AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
        ($rules[0].FileSystemRights -band $full) -eq $full
    if ($ok) { return }

    if ($IsFile) {
        $new = New-Object System.Security.AccessControl.FileSecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]::None
    } else {
        $new = New-Object System.Security.AccessControl.DirectorySecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    }
    $new.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($me, $full, $inherit,
        [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
    $new.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $new
}

# A real folder (not a link), owned by you, owner-only. Created if missing.
function Initialize-PrivateDir([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        if (Test-ReparsePoint $Path) { Fail "`"$Path`" is a link, not a real folder." 'Remove the link, then try again.' }
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Fail "`"$Path`" is not a folder." 'Move it somewhere else, then try again.' }
    } else {
        [void](New-Item -ItemType Directory -Path $Path)
    }
    Protect-PrivatePath $Path
}

function Assert-PrivateFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "`"$Path`" is missing or is not a file." 'Run: ghdp.ps1 install' }
    if (Test-ReparsePoint $Path) { Fail "`"$Path`" is a link, not a real file." 'Remove the link, then try again.' }
    Protect-PrivatePath $Path -IsFile
}

# Write text as UTF-8 without a byte order mark (Git prefers that).
function Write-TextFile([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

# -------------------------------------------------------------------- config

function Assert-KnownKey($Object, [string[]]$Allowed, [string]$Where) {
    foreach ($key in $Object.PSObject.Properties.Name) {
        if ($Allowed -cnotcontains $key) {
            Fail "Unknown setting `"$key`" in $Where of profiles.json." "Allowed settings: $($Allowed -join ', '). Check the spelling."
        }
    }
}

function Get-ConfigString($Object, [string]$Key, [string]$Where) {
    $prop = $Object.PSObject.Properties[$Key]
    if ($null -eq $prop -or $prop.Value -isnot [string]) {
        Fail "In profiles.json, $Where needs `"$Key`" as text in quotes." 'Compare your file with profiles.example.json.'
    }
    return $prop.Value
}

# Read an optional list of strings (folders or owners). Returns an array.
function Get-ConfigList($Object, [string]$Key, [string]$Where, [string]$Hint) {
    $prop = $Object.PSObject.Properties[$Key]
    if ($null -eq $prop) { return ,@() }
    if ($prop.Value -isnot [array]) { Fail "In profiles.json, $Where needs `"$Key`" as a list in [ ]." "Example: `"$Key`": [`"$Hint`"]" }
    $items = @($prop.Value)
    if ($items.Count -gt 10) { Fail "In profiles.json, $Where has more than 10 $Key." 'Keep at most 10.' }
    foreach ($item in $items) {
        if ($item -isnot [string]) { Fail "In profiles.json, every item in `"$Key`" of $Where must be text in quotes." "Example: `"$Key`": [`"$Hint`"]" }
    }
    return ,[string[]]$items
}

# Read and strictly check profiles.json. Returns a list of profiles.
function Read-Config {
    $path = Get-ConfigPath
    if (-not (Test-Path -LiteralPath $path)) { Fail "No profiles.json found at `"$path`"." 'Run: ghdp.ps1 init' }
    Assert-PrivateFile $path
    try {
        $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Fail 'profiles.json is not valid JSON.' 'Open it in a text editor and fix it. Often it is a missing comma or quote.'
    }
    if ($json -isnot [System.Management.Automation.PSCustomObject]) {
        Fail 'profiles.json must be an object { }.' 'Compare your file with profiles.example.json.'
    }
    Assert-KnownKey -Object $json -Allowed @('version', 'profiles') -Where 'the top level'
    $version = $json.PSObject.Properties['version']
    if ($null -eq $version -or -not ($version.Value -is [int] -or $version.Value -is [long]) -or $version.Value -ne 1) {
        Fail 'profiles.json must contain "version": 1.' 'Compare your file with profiles.example.json.'
    }
    $list = $json.PSObject.Properties['profiles']
    if ($null -eq $list -or $list.Value -isnot [array]) {
        Fail 'profiles.json must contain a "profiles" list.' 'Compare your file with profiles.example.json.'
    }
    $items = @($list.Value)
    if ($items.Count -lt 1 -or $items.Count -gt $script:MaxProfiles) {
        Fail "profiles.json must have between 1 and $($script:MaxProfiles) profiles." 'Add or remove profiles.'
    }

    $result = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    for ($i = 0; $i -lt $items.Count; $i++) {
        $where = "profile $($i + 1)"
        $p = $items[$i]
        if ($p -isnot [System.Management.Automation.PSCustomObject]) {
            Fail "In profiles.json, $where is not an object { }." 'Compare your file with profiles.example.json.'
        }
        Assert-KnownKey -Object $p -Allowed @('name', 'gitName', 'gitEmail', 'folders', 'owners') -Where $where
        $pName = Get-ConfigString -Object $p -Key 'name' -Where $where
        Assert-ProfileName $pName
        $gitName = Get-ConfigString -Object $p -Key 'gitName' -Where $where
        if (-not (Test-GitName $gitName)) {
            Fail "The gitName of profile `"$pName`" is not allowed: `"$gitName`"." 'Use your name without quotes or backslashes, and replace CHANGE ME.'
        }
        $gitEmail = Get-ConfigString -Object $p -Key 'gitEmail' -Where $where
        if (-not (Test-Email $gitEmail)) {
            Fail "The gitEmail of profile `"$pName`" is not a valid email: `"$gitEmail`"." 'Use the email for this account, for example its GitHub noreply email.'
        }
        $key = Get-NormalName $pName
        if ($seen.ContainsKey($key)) {
            Fail "Two profiles have the same name: `"$($seen[$key])`" and `"$pName`"." 'Give each profile a different name. Capital letters and - versus _ do not count as different.'
        }
        $seen[$key] = $pName
        $folders = Get-ConfigList -Object $p -Key 'folders' -Where $where -Hint '~/work'
        foreach ($f in $folders) { if (-not (Test-Folder $f)) { Fail "In profiles.json, $where has a `"folders`" item that is not allowed: `"$f`"." 'Example: "~/work"' } }
        $owners = Get-ConfigList -Object $p -Key 'owners' -Where $where -Hint 'your-github-username'
        foreach ($o in $owners) { if (-not (Test-Owner $o)) { Fail "In profiles.json, $where has an `"owners`" item that is not allowed: `"$o`"." 'Example: "your-github-username"' } }
        $result.Add([pscustomobject]@{ Name = $pName; GitName = $gitName; GitEmail = $gitEmail; Folders = $folders; Owners = $owners })
    }
    return , $result.ToArray()
}

function Find-Profile([object[]]$Profiles, [string]$ProfileName) {
    foreach ($p in $Profiles) { if ($p.Name -ceq $ProfileName) { return $p } }
    Fail "There is no profile called `"$ProfileName`" in profiles.json." 'Run: ghdp.ps1 list'
}

# ------------------------------------------------------------- safety checks

# GitHub Desktop leaves these Electron switches on. If either variable is
# set, another program could run code inside GitHub Desktop and read its
# tokens. We refuse to open it rather than take that risk.
function Assert-NoElectronDoor {
    foreach ($var in 'NODE_OPTIONS', 'ELECTRON_RUN_AS_NODE') {
        foreach ($scope in 'Process', 'User', 'Machine') {
            if ([Environment]::GetEnvironmentVariable($var, $scope)) {
                Fail "The setting $var is turned on ($scope). It lets other programs run code inside GitHub Desktop, so this tool will not open it." "Remove $var in Windows Settings > System > About > Advanced system settings > Environment Variables, then try again."
            }
        }
    }
}

# The real GitHub Desktop program is in %LOCALAPPDATA%\GitHubDesktop\app-<version>.
# We pick the newest version and later launch exactly that file.
function Find-DesktopExe {
    Assert-SafePath $env:LOCALAPPDATA 'LOCALAPPDATA'
    $root = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'GitHubDesktop'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    $best = $null
    $bestVersion = $null
    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -Filter 'app-*') {
        $parsed = $null
        if (-not [version]::TryParse(($dir.Name.Substring(4) -replace '-.*$', ''), [ref]$parsed)) { continue }
        $exe = Join-Path -Path $dir.FullName -ChildPath 'GitHubDesktop.exe'
        if ((Test-Path -LiteralPath $exe -PathType Leaf) -and ($null -eq $bestVersion -or $parsed -gt $bestVersion)) {
            $best = $exe
            $bestVersion = $parsed
        }
    }
    return $best
}

# Pass only if Windows says the signature is valid and the signer is GitHub.
function Test-DesktopSignature([string]$Exe) {
    if (Test-ReparsePoint $Exe) { return $false }
    $sig = Get-AuthenticodeSignature -LiteralPath $Exe
    if ($sig.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or $null -eq $sig.SignerCertificate) { return $false }
    $flags = [System.Security.Cryptography.X509Certificates.X500DistinguishedNameFlags]::UseNewLines
    $parts = $sig.SignerCertificate.SubjectName.Decode($flags) -split "\r?\n"
    return ($parts -ccontains "O=$($script:Publisher)" -or $parts -ccontains "O=`"$($script:Publisher)`"")
}

function Get-VerifiedDesktop {
    $exe = Find-DesktopExe
    if ($null -eq $exe) { Fail 'GitHub Desktop is not installed for this Windows user.' 'Install it from https://desktop.github.com, then try again.' }
    if (-not (Test-DesktopSignature $exe)) {
        Fail "GitHub Desktop at `"$exe`" failed the signature check, so it was not opened. It may be damaged or not the real app." 'Reinstall GitHub Desktop from https://desktop.github.com, then try again.'
    }
    return $exe
}

# ----------------------------------------------------------- profile set-up

# Create the profile's private folders and Git settings file, and keep the
# name and email in that file in step with profiles.json. Uses the Git that
# ships inside GitHub Desktop (no extra dependency).
function Initialize-Profile($ProfileItem, [string]$Exe) {
    $gitConfig = Get-GitConfigPath $ProfileItem.Name
    Initialize-PrivateDir (Get-BaseDir)
    Initialize-PrivateDir (Join-Path -Path (Get-BaseDir) -ChildPath 'profiles')
    Initialize-PrivateDir (Get-ProfileDir $ProfileItem.Name)
    Initialize-PrivateDir (Get-DataDir $ProfileItem.Name)
    if (-not (Test-Path -LiteralPath $gitConfig)) {
        $header = @(
            "# Git settings for the `"$($ProfileItem.Name)`" profile (made by gh-desktop-profiles).",
            '# GitHub Desktop uses this file instead of ~/.gitconfig for this profile.',
            '# It loads your normal Git settings first. The name and email below are',
            '# reset from profiles.json on every launch.',
            '[include]',
            "`tpath = ~/.config/git/config",
            "`tpath = ~/.gitconfig",
            ''
        ) -join "`n"
        Write-TextFile $gitConfig $header
    }
    Assert-PrivateFile $gitConfig
    $git = Join-Path -Path (Split-Path -Path $Exe -Parent) -ChildPath 'resources\app\git\cmd\git.exe'
    if (Test-Path -LiteralPath $git -PathType Leaf) {
        & $git config --file $gitConfig --replace-all user.name $ProfileItem.GitName
        if ($LASTEXITCODE -ne 0) { Fail 'Could not write the Git name for this profile.' 'Run: ghdp.ps1 install' }
        & $git config --file $gitConfig --replace-all user.email $ProfileItem.GitEmail
        if ($LASTEXITCODE -ne 0) { Fail 'Could not write the Git email for this profile.' 'Run: ghdp.ps1 install' }
    }
}

# Copy this script to a fixed private place. Shortcuts run that copy, so a
# later change in the project folder never runs until you install again.
# Reading and writing the bytes (not copying the file) leaves out the
# "downloaded from the internet" mark, so RemoteSigned can run the copy.
function Install-Self {
    $dst = Get-BinPath
    Initialize-PrivateDir (Split-Path -Path $dst -Parent)
    if ($PSCommandPath -eq $dst) { return }
    [System.IO.File]::WriteAllBytes($dst, [System.IO.File]::ReadAllBytes($PSCommandPath))
    Assert-PrivateFile $dst
}

# Create (or refresh) a Start menu shortcut for one profile.
function Add-ProfileShortcut([string]$ProfileName, [string]$Exe) {
    $dir = Get-ShortcutDir
    if (Test-Path -LiteralPath $dir) {
        if (Test-ReparsePoint $dir) { Fail "`"$dir`" is a link, not a real folder." 'Remove the link, then try again.' }
    } else {
        [void](New-Item -ItemType Directory -Path $dir)
    }
    $bin = Get-BinPath
    $lnkPath = Get-ShortcutPath $ProfileName
    $arguments = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File `"$bin`" launch $ProfileName -Gui"
    $shell = New-Object -ComObject WScript.Shell
    if (Test-Path -LiteralPath $lnkPath) {
        $old = $shell.CreateShortcut($lnkPath)
        if ($old.Arguments -cne $arguments) {
            Fail "`"$lnkPath`" already exists and was not made by this tool." 'Rename or remove it, then run: ghdp.ps1 install'
        }
    }
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = $arguments
    $lnk.WorkingDirectory = Split-Path -Path $bin -Parent
    $lnk.WindowStyle = 7 # start minimized, so no window flashes
    $lnk.IconLocation = "$Exe,0"
    $lnk.Description = "Open GitHub Desktop with the $ProfileName profile"
    $lnk.Save()
}

# --------------------------------------------------- setup wizard and import

# Your normal GitHub Desktop data. This tool only ever reads it.
function Get-NormalDataDir {
    Assert-SafePath $env:APPDATA 'APPDATA'
    return (Join-Path -Path $env:APPDATA -ChildPath 'GitHub Desktop')
}

# True if a running program has GitHub Desktop's database open in this
# folder. GitHub Desktop keeps its LOCK files open for as long as it runs,
# so opening one with no sharing fails.
function Test-DesktopHoldsData([string]$Dir) {
    $locks = @(Join-Path -Path (Join-Path -Path (Join-Path -Path $Dir -ChildPath 'Local Storage') -ChildPath 'leveldb') -ChildPath 'LOCK')
    $indexed = Join-Path -Path $Dir -ChildPath 'IndexedDB'
    if (Test-Path -LiteralPath $indexed -PathType Container) {
        $locks += @(Get-ChildItem -LiteralPath $indexed -Directory | ForEach-Object { Join-Path -Path $_.FullName -ChildPath 'LOCK' })
    }
    foreach ($lock in $locks) {
        if (-not (Test-Path -LiteralPath $lock -PathType Leaf)) { continue }
        try {
            $stream = [System.IO.File]::Open($lock, 'Open', 'Read', 'None')
            $stream.Dispose()
        } catch [System.IO.IOException] {
            return $true
        }
    }
    return $false
}

$script:SkipNames = @('Cache', 'Code Cache', 'GPUCache', 'GPUPersistentCache', 'ShaderCache', 'Crashpad', 'logs')

function Test-SkipName([string]$ItemName) {
    return ($script:SkipNames -contains $ItemName -or $ItemName -like '*Dawn*Cache' -or $ItemName -like 'Singleton*' -or $ItemName -like 'Cookies*')
}

function Copy-Tree([string]$From, [string]$To) {
    foreach ($item in Get-ChildItem -LiteralPath $From -Force) {
        if (Test-SkipName $item.Name) { continue }
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue } # links, junctions
        $target = Join-Path -Path $To -ChildPath $item.Name
        if ($item.PSIsContainer) {
            [void](New-Item -ItemType Directory -Path $target)
            Copy-Tree $item.FullName $target
        } else {
            # A new file (not a file copy), so it gets the owner-only rights
            # of the profile folder and no "downloaded" mark.
            $in = [System.IO.File]::OpenRead($item.FullName)
            try {
                $out = [System.IO.File]::Open($target, 'CreateNew', 'Write', 'None')
                try { $in.CopyTo($out) } finally { $out.Dispose() }
            } finally {
                $in.Dispose()
            }
        }
    }
}

# Copy your normal GitHub Desktop data (login, repo list, settings) into a
# NEW profile folder. Caches, logs, lock files and links are left out. The
# original is only read. Tokens are not in this folder; they stay in
# Windows Credential Manager.
function Copy-DesktopData([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container) -or (Test-ReparsePoint $Source)) {
        Fail 'Your GitHub Desktop data folder was not found.' 'Run setup again and choose not to copy.'
    }
    if (Test-Path -LiteralPath $Destination) {
        Fail "`"$Destination`" already exists, so nothing was copied." 'Choose another profile name.'
    }
    [void](New-Item -ItemType Directory -Path $Destination)
    Protect-PrivatePath $Destination
    Copy-Tree $Source $Destination
}

# Ask a question. An empty answer means the default. Stops on end of input.
function Read-Answer([string]$Question, [string]$Default = '') {
    $prompt = if ($Default) { "$Question [$Default]" } else { $Question }
    $answer = Read-Host -Prompt $prompt
    if ($null -eq $answer) { Fail 'Setup was cancelled. Nothing was changed.' 'Run setup again when you are ready.' }
    if ($answer -eq '') { return $Default }
    return $answer
}

function Read-YesNo([string]$Question, [string]$Default) {
    while ($true) {
        $answer = Read-Answer "$Question (y/n)" $Default
        if ($answer -in @('y', 'yes')) { return $true }
        if ($answer -in @('n', 'no')) { return $false }
        Write-Line '  Please type y or n.'
    }
}

# Ask for a profile name that is valid and not used yet. With -MustBeNew,
# also refuse names that already have profile data (an import needs a new
# folder).
function Read-ProfileName([int]$Number, [object[]]$Taken, [switch]$MustBeNew) {
    while ($true) {
        $answer = Read-Answer "Name for profile $Number (letters, numbers, - or _; for example office or personal)"
        if (-not (Test-ProfileName $answer)) {
            Write-Line '  That name is not allowed. Use 1-32 letters, numbers, - or _, starting with a letter or number.'
            continue
        }
        if (@($Taken | Where-Object { (Get-NormalName $_.Name) -eq (Get-NormalName $answer) }).Count -gt 0) {
            Write-Line '  You already have a profile with that name.'
            continue
        }
        if ($MustBeNew -and (Test-Path -LiteralPath (Get-DataDir $answer))) {
            Write-Line "  A profile called `"$answer`" already has data on this PC. Choose another name."
            continue
        }
        return $answer
    }
}

function Read-GitName([string]$Default) {
    while ($true) {
        $answer = Read-Answer '  Name on commits' $Default
        if (Test-GitName $answer) { return $answer }
        Write-Line '  Please type your name (no quotes or backslashes).'
    }
}

function Read-Email([string]$Default) {
    while ($true) {
        $answer = Read-Answer '  Email on commits for this account' $Default
        if (Test-Email $answer) { return $answer }
        Write-Line '  That does not look like an email address.'
    }
}

# Read one value from your normal Git settings, to offer it as a default.
# Uses the Git inside GitHub Desktop; never changes anything.
function Get-GlobalGitValue([string]$Key, [string]$Exe) {
    $git = Join-Path -Path (Split-Path -Path $Exe -Parent) -ChildPath 'resources\app\git\cmd\git.exe'
    if (-not (Test-Path -LiteralPath $git -PathType Leaf)) { return '' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $git
    $psi.Arguments = "config --global --get $Key"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    [void]$psi.EnvironmentVariables.Remove('GIT_CONFIG_GLOBAL')
    $process = [System.Diagnostics.Process]::Start($psi)
    $value = $process.StandardOutput.ReadToEnd().Trim()
    $process.WaitForExit()
    return $value
}

# Write the wizard's answers as profiles.json. The old file is kept as
# profiles.json.bak.
function Write-ProfilesJson([object[]]$Items) {
    $cfg = Get-ConfigPath
    if ((Test-Path -LiteralPath $cfg) -and (Test-ReparsePoint $cfg)) {
        Fail "`"$cfg`" is a link, not a real file." 'Remove the link, then run setup again.'
    }
    $list = @($Items | ForEach-Object { [ordered]@{ name = $_.Name; gitName = $_.GitName; gitEmail = $_.GitEmail } })
    $json = ConvertTo-Json -InputObject ([ordered]@{ version = 1; profiles = $list }) -Depth 4
    if (Test-Path -LiteralPath $cfg -PathType Leaf) {
        $backup = "$cfg.bak"
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force } # never write through a planted link
        Write-TextFile $backup ([System.IO.File]::ReadAllText($cfg))
        Assert-PrivateFile $backup
    }
    Write-TextFile $cfg $json
    Assert-PrivateFile $cfg
}

# ------------------------------------------------------------------ commands

# Guided setup: asks for your profiles, can copy your current GitHub Desktop
# into the first one, writes profiles.json and installs the shortcuts.
function Invoke-Setup {
    Write-Line 'GitHub Desktop Profiles setup'
    Write-Line 'You will get one GitHub Desktop shortcut per GitHub account.'
    Write-Line 'Never type a password here. You sign in later, inside GitHub Desktop.'
    Write-Line ''
    $exe = Get-VerifiedDesktop
    Write-Line 'GitHub Desktop: found, and signed by GitHub.'
    Initialize-PrivateDir (Get-BaseDir)
    if (Test-Path -LiteralPath (Get-ConfigPath)) {
        Write-Line 'You already have profiles. A new setup replaces them (your old profiles.json is kept as a backup).'
        Write-Line 'If you say no, your profiles are kept and their shortcuts are installed again.'
        if (-not (Read-YesNo 'Start a new setup?' 'n')) {
            Write-Line ''
            Invoke-Install
            return
        }
    }

    $items = New-Object System.Collections.Generic.List[object]
    $defaultName = Get-GlobalGitValue 'user.name' $exe
    if (-not (Test-GitName $defaultName)) { $defaultName = '' }
    $defaultEmail = Get-GlobalGitValue 'user.email' $exe
    if (-not (Test-Email $defaultEmail)) { $defaultEmail = '' }
    $import = ''

    $normal = Get-NormalDataDir
    if ((Test-Path -LiteralPath $normal -PathType Container) -and -not (Test-ReparsePoint $normal)) {
        Write-Line ''
        Write-Line 'Your current GitHub Desktop already has a login and a repo list.'
        Write-Line '(Its WHOLE repo list is copied. If it holds repos of another account, you'
        Write-Line 'remove them from this profile afterwards; setup tells you how.)'
        if (Read-YesNo 'Copy them into your first profile, so that account does not need to sign in again?' 'y') {
            $pName = Read-ProfileName -Number 1 -Taken $items.ToArray() -MustBeNew
            $items.Add([pscustomobject]@{ Name = $pName; GitName = (Read-GitName $defaultName); GitEmail = (Read-Email $defaultEmail) })
            $import = $pName
        }
    }

    while ($items.Count -lt $script:MaxProfiles) {
        Write-Line ''
        if ($items.Count -gt 0) {
            $default = if ($items.Count -eq 1) { 'y' } else { 'n' }
            if (-not (Read-YesNo 'Add another profile (another GitHub account)?' $default)) { break }
            $lastName = $items[$items.Count - 1].GitName
        } else {
            $lastName = $defaultName
        }
        $pName = Read-ProfileName -Number ($items.Count + 1) -Taken $items.ToArray()
        $items.Add([pscustomobject]@{ Name = $pName; GitName = (Read-GitName $lastName); GitEmail = (Read-Email '') })
    }

    Write-Line ''
    Write-Line 'Your profiles:'
    foreach ($p in $items) {
        $how = if ($p.Name -ceq $import) { 'copied from your current GitHub Desktop' } else { 'new: sign in once' }
        Write-Line "  $($p.Name): $($p.GitName) <$($p.GitEmail)> ($how)"
    }
    if (-not (Read-YesNo 'Create these profiles?' 'y')) {
        Write-Line 'Nothing changed.'
        return
    }

    Write-ProfilesJson $items.ToArray()
    if ($import) {
        while (Test-DesktopHoldsData $normal) {
            Write-Line 'Please close GitHub Desktop now (File > Exit).'
            [void](Read-Answer 'Then press Enter to continue')
        }
        Initialize-PrivateDir (Join-Path -Path (Get-BaseDir) -ChildPath 'profiles')
        Initialize-PrivateDir (Get-ProfileDir $import)
        Copy-DesktopData $normal (Get-DataDir $import)
        Write-Line "Copied your GitHub Desktop data into `"$import`". Your normal GitHub Desktop is unchanged."
    }
    Write-Line ''
    Invoke-Install
    if ($import) {
        Write-Line "`"$import`" opens already signed in, with your repos."
        Write-Line ''
        Write-Line "One clean-up step: `"$import`" got the WHOLE repo list of your old GitHub Desktop."
        Write-Line "If it shows repos of another account, open `"GitHub Desktop - $import`","
        Write-Line 'right-click each of them and choose Remove (the files stay on your disk).'
        Write-Line 'Then add them in the right profile: File > Add Local Repository.'
    }
    Write-Line ''
    Write-Line 'Do not sign out of an account in one window: the same account in another window would be signed out too.'
}

function Invoke-Init {
    Initialize-PrivateDir (Get-BaseDir)
    $cfg = Get-ConfigPath
    if (Test-Path -LiteralPath $cfg) {
        Write-Line "You already have a profiles.json: $cfg"
        Write-Line 'Edit it, then run: ghdp.ps1 install'
        return
    }
    $example = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'profiles.example.json'
    if (-not (Test-Path -LiteralPath $example -PathType Leaf)) {
        Fail 'Could not find profiles.example.json.' 'Run init from the project folder: windows\ghdp.ps1 init'
    }
    Write-TextFile $cfg ([System.IO.File]::ReadAllText($example))
    Assert-PrivateFile $cfg
    Write-Line "Created: $cfg"
    Write-Line 'Next: replace every CHANGE ME with your details, then run: windows\ghdp.ps1 install'
    Write-Line "To open it in Notepad, run: notepad `"$cfg`""
}

function Invoke-Install {
    $profiles = Read-Config
    $exe = Get-VerifiedDesktop
    Initialize-PrivateDir (Get-BaseDir)
    Install-Self
    foreach ($p in $profiles) {
        Initialize-Profile $p $exe
        Add-ProfileShortcut $p.Name $exe
        Write-Line "Ready: $($p.Name) -> $(Get-ShortcutPath $p.Name)"
    }
    Write-Line ''
    Write-Line "Done. Open the Start menu and search for `"GitHub Desktop - $($profiles[0].Name)`"."
    Write-Line 'Tip: sign in to each profile while it is the only GitHub Desktop window open.'
}

function Invoke-Launch([string]$ProfileName, [switch]$DryRun) {
    if ([string]::IsNullOrEmpty($ProfileName)) { Fail 'Which profile should open?' 'Example: ghdp.ps1 launch office' }
    Assert-ProfileName $ProfileName
    $profiles = Read-Config
    $p = Find-Profile $profiles $ProfileName
    Assert-NoElectronDoor
    $exe = Get-VerifiedDesktop

    # Fixed arguments only. The settings below reach only this GitHub Desktop
    # (not other programs). GIT_AUTHOR_* and GIT_COMMITTER_* beat every Git
    # config file, so commits always use this profile's identity.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "--user-data-dir=`"$(Get-DataDir $ProfileName)`""
    $psi.WorkingDirectory = Split-Path -Path $exe -Parent
    $psi.UseShellExecute = $false
    $settings = [ordered]@{
        GIT_CONFIG_GLOBAL   = Get-GitConfigPath $ProfileName
        GIT_AUTHOR_NAME     = $p.GitName
        GIT_AUTHOR_EMAIL    = $p.GitEmail
        GIT_COMMITTER_NAME  = $p.GitName
        GIT_COMMITTER_EMAIL = $p.GitEmail
        GHDP_PROFILE        = $ProfileName
    }
    foreach ($k in $settings.Keys) { $psi.EnvironmentVariables[$k] = $settings[$k] }

    if ($DryRun) {
        Write-Line 'Dry run: all checks passed. Nothing was changed. This would run:'
        Write-Line "  $($psi.FileName) $($psi.Arguments)"
        foreach ($k in $settings.Keys) { Write-Line "  with $k=$($settings[$k])" }
        return
    }
    Initialize-Profile $p $exe
    [void][System.Diagnostics.Process]::Start($psi)
}

function Invoke-List {
    $profiles = Read-Config
    Write-Line "Config file: $(Get-ConfigPath)"
    $exe = Find-DesktopExe
    if ($null -eq $exe) {
        Write-Line 'GitHub Desktop: not found'
    } elseif (Test-DesktopSignature $exe) {
        Write-Line "GitHub Desktop: $exe (signature OK)"
    } else {
        Write-Line "GitHub Desktop: $exe (SIGNATURE CHECK FAILED)"
    }
    Write-Line ''
    foreach ($p in $profiles) {
        $status = if (Test-Path -LiteralPath (Get-ShortcutPath $p.Name)) { 'shortcut OK' } else { 'no shortcut yet (run: ghdp.ps1 install)' }
        Write-Line "$($p.Name)  <$($p.GitEmail)>  $status"
        Write-Line "  data: $(Get-DataDir $p.Name)"
    }
}

function Show-Help {
    Write-Line "gh-desktop-profiles $($script:Version) for Windows"
    Write-Line '  ghdp.ps1 setup                      guided setup: asks for your profiles'
    Write-Line '  ghdp.ps1 init                       create your profiles.json from the example'
    Write-Line '  ghdp.ps1 install                    set up profile folders and Start menu shortcuts'
    Write-Line '  ghdp.ps1 launch <name> [-DryRun]    open GitHub Desktop with a profile'
    Write-Line '  ghdp.ps1 list                       show your profiles and their status'
}

function Invoke-Main([string]$Cmd, [string]$ProfileName, [switch]$DryRun, [switch]$Gui) {
    try {
        switch ($Cmd) {
            'setup' { Invoke-Setup }
            'init' { Invoke-Init }
            'install' { Invoke-Install }
            'launch' { Invoke-Launch -ProfileName $ProfileName -DryRun:$DryRun }
            'list' { Invoke-List }
            default { Show-Help }
        }
    } catch {
        $message = "Error: $($_.Exception.Message)"
        $next = $_.Exception.Data['Next']
        if ($next) { $message += "`nNext step: $next" }
        [Console]::Error.WriteLine($message)
        if ($Gui) { Show-ErrorDialog $message }
        exit 1
    }
}

# Run only when executed, not when loaded by the tests.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main -Cmd $Command -ProfileName $Name -DryRun:$DryRun -Gui:$Gui
}
