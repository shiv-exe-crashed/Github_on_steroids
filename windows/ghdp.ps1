#Requires -Version 5.1
<#
.SYNOPSIS
    gh-desktop-profiles for Windows.

.DESCRIPTION
    Opens the official GitHub Desktop with a separate profile per GitHub
    account. Each profile has its own login, its own repo list, its own
    settings, its own taskbar button and its own colored icon, and a guard
    that stops wrong-account commits and pushes. Windows PowerShell 5.1.
    No admin rights, no downloads, no network calls.

    Security promises (details in THREAT_MODEL.md):
      - never reads, stores, logs or prints tokens or passwords
      - makes no network calls
      - needs no admin rights and never edits your global Git config

    Commands:
      ghdp.ps1 setup                      guided setup (a menu if you already have profiles)
      ghdp.ps1 add                        add one more profile; the others stay as they are
      ghdp.ps1 remove [name]              remove a profile (its data is kept unless you say so)
      ghdp.ps1 init                       create your profiles.json from the example
      ghdp.ps1 install                    set up profile folders, icons and Start menu shortcuts
      ghdp.ps1 launch <name> [-DryRun]    open GitHub Desktop with a profile
      ghdp.ps1 launch <name> -Plain       open the normal GitHub Desktop window setup (no own taskbar icon)
      ghdp.ps1 list                       show your profiles and their status
      ghdp.ps1 allow <name> <owner/repo>  let a profile use one repo of another owner
      ghdp.ps1 uninstall                  remove shortcuts and the tool (profile data: you choose)
      ghdp.ps1 help                       show this help
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'add', 'remove', 'init', 'install', 'launch', 'list', 'allow', 'uninstall', 'handle', 'help', 'version')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Name = '',

    [Parameter(Position = 2)]
    [string]$Extra = '',

    # Show what launch would run, without changing or opening anything.
    [switch]$DryRun,

    # Open the normal GitHub Desktop window, without the profile's own taskbar icon.
    [switch]$Plain,

    # Set by the shortcuts: also show errors in a dialog box.
    [switch]$Gui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Version = '0.2.0'
$script:MaxProfiles = 20
$script:MaxRules = 10
$script:OnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$script:Publisher = 'GitHub, Inc.'
$script:ToolId = 'io.github.gh-desktop-profiles'
$script:ProtocolKey = 'HKEY_CURRENT_USER\Software\Classes\x-github-desktop-auth\shell\open\command'
$script:NativeVersion = '2'

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

# "owner/name" as written on GitHub, without ".git".
function Test-Repo([string]$Value) {
    if ($Value -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}\z') { return $false }
    $repoName = $Value.Substring($Value.IndexOf('/') + 1)
    return (-not ($repoName -eq '.' -or $repoName -eq '..' -or $repoName.EndsWith('.git')))
}

function Assert-ProfileName([string]$Value) {
    if (-not (Test-ProfileName $Value)) {
        Fail "Profile name `"$Value`" is not allowed." 'Use 1-32 letters, numbers, - or _, starting with a letter or number.'
    }
}

# A folder rule as the guard reads it: full path with forward slashes.
function Expand-Folder([string]$Value) {
    if ($Value -cmatch '\A~[\\/]') { $Value = Join-Path -Path $env:USERPROFILE -ChildPath $Value.Substring(2) }
    return ($Value -replace '\\', '/').TrimEnd('/')
}

# The GitHub username inside a noreply email: "12345+name@users..." or
# "name@users...". Empty for any other email.
function Get-OwnerFromEmail([string]$Email) {
    $suffix = '@users.noreply.github.com'
    if (-not $Email.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    $local = $Email.Substring(0, $Email.Length - $suffix.Length)
    $plus = $local.IndexOf('+')
    if ($plus -ge 0) { $local = $local.Substring($plus + 1) }
    if (Test-Owner $local) { return $local }
    return ''
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
function Get-BinDir { return (Join-Path -Path (Get-BaseDir) -ChildPath 'bin') }
function Get-BinPath { return (Join-Path -Path (Get-BinDir) -ChildPath 'ghdp.ps1') }
function Get-RunnerPath { return (Join-Path -Path (Get-BinDir) -ChildPath 'ghdp-run.exe') }
function Get-NativePath { return (Join-Path -Path (Get-BinDir) -ChildPath 'ghdp-native.dll') }
function Get-ActivePath { return (Join-Path -Path (Get-BaseDir) -ChildPath 'active.txt') }
function Get-ProfilesRoot { return (Join-Path -Path (Get-BaseDir) -ChildPath 'profiles') }
function Get-ProfileDir([string]$ProfileName) {
    Assert-ProfileName $ProfileName
    return (Join-Path -Path (Get-ProfilesRoot) -ChildPath $ProfileName)
}
function Get-DataDir([string]$ProfileName) { return (Join-Path -Path (Get-ProfileDir $ProfileName) -ChildPath 'desktop-data') }
function Get-GitConfigPath([string]$ProfileName) { return (Join-Path -Path (Get-ProfileDir $ProfileName) -ChildPath 'gitconfig') }
function Get-HooksDir([string]$ProfileName) { return (Join-Path -Path (Get-ProfileDir $ProfileName) -ChildPath 'hooks') }
function Get-GuardPath([string]$ProfileName) { return (Join-Path -Path (Get-ProfileDir $ProfileName) -ChildPath 'guard.rules') }
function Get-IconPath([string]$ProfileName) { return (Join-Path -Path (Get-ProfileDir $ProfileName) -ChildPath 'icon.ico') }
function Get-Aumid([string]$ProfileName) { return "$($script:ToolId).$(Get-NormalName $ProfileName)" }
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

# Put a finished file in place in one step, so a commit made while this runs
# never finds a missing or half-written file. Skipped when nothing changed.
function Write-FileAtomic([string]$Path, [string]$Text) {
    if (Test-Path -LiteralPath $Path -PathType Container) { Fail "`"$Path`" is a folder." 'Move it somewhere else, then try again.' }
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not (Test-ReparsePoint $Path) -and
        ([System.IO.File]::ReadAllText($Path) -ceq $Text)) { return }
    $tmp = "$Path.tmp$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    Write-TextFile $tmp $Text
    Move-Item -LiteralPath $tmp -Destination $Path -Force
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

# Read an optional list of strings (folders, owners or repos). Returns an array.
function Get-ConfigList($Object, [string]$Key, [string]$Where, [string]$Hint) {
    $prop = $Object.PSObject.Properties[$Key]
    if ($null -eq $prop) { return ,@() }
    if ($prop.Value -isnot [array]) { Fail "In profiles.json, $Where needs `"$Key`" as a list in [ ]." "Example: `"$Key`": [`"$Hint`"]" }
    $items = @($prop.Value)
    if ($items.Count -gt $script:MaxRules) { Fail "In profiles.json, $Where has more than $($script:MaxRules) $Key." "Keep at most $($script:MaxRules)." }
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
        Assert-KnownKey -Object $p -Allowed @('name', 'gitName', 'gitEmail', 'folders', 'owners', 'repos') -Where $where
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
        $repos = Get-ConfigList -Object $p -Key 'repos' -Where $where -Hint 'owner/repo-name'
        foreach ($r in $repos) { if (-not (Test-Repo $r)) { Fail "In profiles.json, $where has a `"repos`" item that is not allowed: `"$r`"." 'Example: "owner/repo-name"' } }
        $result.Add([pscustomobject]@{ Name = $pName; GitName = $gitName; GitEmail = $gitEmail; Folders = $folders; Owners = $owners; Repos = $repos })
    }
    return , $result.ToArray()
}

function Find-Profile([object[]]$Profiles, [string]$ProfileName) {
    foreach ($p in $Profiles) { if ($p.Name -ceq $ProfileName) { return $p } }
    Fail "There is no profile called `"$ProfileName`" in profiles.json." 'Run: ghdp.ps1 list'
}

function Get-ProfileIndex([object[]]$Profiles, [string]$ProfileName) {
    for ($i = 0; $i -lt $Profiles.Count; $i++) { if ($Profiles[$i].Name -ceq $ProfileName) { return $i } }
    return 0
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

function Get-DesktopGit([string]$Exe) {
    return (Join-Path -Path (Split-Path -Path $Exe -Parent) -ChildPath 'resources\app\git\cmd\git.exe')
}

# ----------------------------------------------------- native helper programs
# Two tiny programs are built once at install time with the C# compiler that
# ships with Windows (no download):
#   ghdp-run.exe     starts this script with no console window flashing, for the
#                    shortcuts and for the sign-in link.
#   ghdp-native.dll  window helpers: a separate taskbar button and icon per
#                    profile, and the badge icon drawing.
# Both are plain code from this file; nothing is fetched from anywhere.

$script:RunnerSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

static class GhdpRun
{
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "ghdp.ps1");
        if (!File.Exists(script)) return 2;
        StringBuilder sb = new StringBuilder();
        sb.Append("-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File \"").Append(script).Append("\"");
        foreach (string a in args)
        {
            if (a.IndexOf('"') >= 0 || a.IndexOf('\r') >= 0 || a.IndexOf('\n') >= 0 || a.EndsWith("\\")) return 3;
            sb.Append(" \"").Append(a).Append("\"");
        }
        sb.Append(" -Gui");
        string root = Environment.GetEnvironmentVariable("SystemRoot");
        ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(root, @"System32\WindowsPowerShell\v1.0\powershell.exe"), sb.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        Process.Start(psi);
        return 0;
    }
}
'@

$script:NativeSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class GhdpNative
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PropertyKey { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    struct PropVariant
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr ptr;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint c);
        [PreserveSig] int GetAt(uint i, out PropertyKey k);
        [PreserveSig] int GetValue(ref PropertyKey k, out PropVariant v);
        [PreserveSig] int SetValue(ref PropertyKey k, ref PropVariant v);
        [PreserveSig] int Commit();
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class CShellLink { }

    [ComImport, Guid("0000010B-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPersistFile
    {
        [PreserveSig] int GetClassID(out Guid g);
        [PreserveSig] int IsDirty();
        [PreserveSig] int Load([MarshalAs(UnmanagedType.LPWStr)] string f, uint mode);
        [PreserveSig] int Save([MarshalAs(UnmanagedType.LPWStr)] string f, [MarshalAs(UnmanagedType.Bool)] bool remember);
        [PreserveSig] int SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string f);
        [PreserveSig] int GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string f);
    }

    delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore ppv);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool SetWindowText(IntPtr h, string text);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr LoadImage(IntPtr inst, string name, uint type, int cx, int cy, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] phicon, uint[] piconid, uint n, uint flags);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);

    static readonly Guid AppUserModelFmt = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    static readonly Dictionary<string, IntPtr[]> iconCache = new Dictionary<string, IntPtr[]>();

    static void SetStr(IPropertyStore ps, uint pid, string value)
    {
        PropertyKey k = new PropertyKey();
        k.fmtid = AppUserModelFmt;
        k.pid = pid;
        PropVariant pv = new PropVariant();
        pv.vt = 31; // VT_LPWSTR
        pv.ptr = Marshal.StringToCoTaskMemUni(value);
        try { ps.SetValue(ref k, ref pv); }
        finally { Marshal.FreeCoTaskMem(pv.ptr); }
    }

    // Give one window its own taskbar identity: its own button (not grouped with
    // other GitHub Desktop windows), and what "pin to taskbar" should start.
    public static bool ApplyIdentity(IntPtr hwnd, string aumid, string relaunchCmd, string iconResource, string displayName)
    {
        Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        IPropertyStore ps;
        if (SHGetPropertyStoreForWindow(hwnd, ref iid, out ps) != 0 || ps == null) return false;
        try
        {
            SetStr(ps, 5, aumid);
            SetStr(ps, 2, relaunchCmd);
            SetStr(ps, 3, iconResource);
            SetStr(ps, 4, displayName);
            return ps.Commit() == 0;
        }
        finally { Marshal.ReleaseComObject(ps); }
    }

    // Same identity for a shortcut file, so a pinned shortcut and the running
    // window share one taskbar button.
    public static bool SetLinkAppId(string lnkPath, string aumid)
    {
        object o = new CShellLink();
        try
        {
            IPersistFile pf = (IPersistFile)o;
            if (pf.Load(lnkPath, 2) != 0) return false;
            IPropertyStore ps = (IPropertyStore)o;
            SetStr(ps, 5, aumid);
            if (ps.Commit() != 0) return false;
            return pf.Save(lnkPath, true) == 0;
        }
        finally { Marshal.ReleaseComObject(o); }
    }

    public static void SetIcons(IntPtr hwnd, string icoPath)
    {
        IntPtr[] pair;
        if (!iconCache.TryGetValue(icoPath, out pair))
        {
            pair = new IntPtr[2];
            pair[0] = LoadImage(IntPtr.Zero, icoPath, 1, 64, 64, 0x10);
            pair[1] = LoadImage(IntPtr.Zero, icoPath, 1, 32, 32, 0x10);
            iconCache[icoPath] = pair;
        }
        if (pair[0] != IntPtr.Zero) SendMessage(hwnd, 0x80, (IntPtr)1, pair[0]);
        if (pair[1] != IntPtr.Zero) SendMessage(hwnd, 0x80, (IntPtr)0, pair[1]);
    }

    public static string GetTitle(IntPtr hwnd)
    {
        StringBuilder sb = new StringBuilder(256);
        GetWindowText(hwnd, sb, 256);
        return sb.ToString();
    }

    public static void SetTitle(IntPtr hwnd, string text) { SetWindowText(hwnd, text); }

    // The main window of a program: visible, no owner, an Electron window.
    public static IntPtr FindMainWindow(uint pid)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr h, IntPtr l)
        {
            uint p;
            GetWindowThreadProcessId(h, out p);
            if (p != pid || !IsWindowVisible(h) || GetWindow(h, 4) != IntPtr.Zero) return true;
            StringBuilder cls = new StringBuilder(64);
            GetClassName(h, cls, 64);
            if (cls.ToString() != "Chrome_WidgetWin_1") return true;
            found = h;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static uint ForegroundPid()
    {
        uint p;
        GetWindowThreadProcessId(GetForegroundWindow(), out p);
        return p;
    }

    public static void BringToFront(IntPtr hwnd)
    {
        if (IsIconic(hwnd)) ShowWindow(hwnd, 9);
        SetForegroundWindow(hwnd);
    }

    static Bitmap ExtractExeIcon(string exe, int size)
    {
        IntPtr[] h = new IntPtr[1];
        uint[] id = new uint[1];
        uint n = PrivateExtractIcons(exe, 0, size, size, h, id, 1, 0);
        if (n == 0 || h[0] == IntPtr.Zero)
        {
            Icon ai = Icon.ExtractAssociatedIcon(exe);
            if (ai == null) throw new InvalidOperationException("cannot read the GitHub Desktop icon");
            return new Bitmap(ai.ToBitmap());
        }
        try { using (Icon ic = Icon.FromHandle(h[0])) { return new Bitmap(ic.ToBitmap()); } }
        finally { DestroyIcon(h[0]); }
    }

    // GitHub Desktop's icon with a colored circle and the profile's first letter.
    public static void BuildBadgeIcon(string exe, string outPath, string letter, int r, int g, int b)
    {
        const int S = 256;
        using (Bitmap src = ExtractExeIcon(exe, S))
        using (Bitmap canvas = new Bitmap(S, S, PixelFormat.Format32bppArgb))
        {
            using (Graphics gr = Graphics.FromImage(canvas))
            {
                gr.SmoothingMode = SmoothingMode.AntiAlias;
                gr.InterpolationMode = InterpolationMode.HighQualityBicubic;
                gr.PixelOffsetMode = PixelOffsetMode.HighQuality;
                gr.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
                gr.Clear(Color.Transparent);
                gr.DrawImage(src, 0, 0, S, S);
                float d = S * 0.5f;
                float x = S - d - S * 0.01f, y = S - d - S * 0.01f;
                using (SolidBrush fill = new SolidBrush(Color.FromArgb(r, g, b)))
                    gr.FillEllipse(fill, x, y, d, d);
                using (Pen ring = new Pen(Color.White, S * 0.03f))
                    gr.DrawEllipse(ring, x, y, d, d);
                using (Font f = new Font("Segoe UI", d * 0.6f, FontStyle.Bold, GraphicsUnit.Pixel))
                using (StringFormat sf = new StringFormat())
                {
                    sf.Alignment = StringAlignment.Center;
                    sf.LineAlignment = StringAlignment.Center;
                    gr.DrawString(letter, f, Brushes.White, new RectangleF(x, y + d * 0.03f, d, d), sf);
                }
            }
            int[] sizes = new int[] { 256, 128, 64, 48, 32, 24, 16 };
            List<byte[]> pngs = new List<byte[]>();
            foreach (int s in sizes)
            {
                using (Bitmap bmp = new Bitmap(s, s, PixelFormat.Format32bppArgb))
                {
                    using (Graphics gs = Graphics.FromImage(bmp))
                    {
                        gs.InterpolationMode = InterpolationMode.HighQualityBicubic;
                        gs.PixelOffsetMode = PixelOffsetMode.HighQuality;
                        gs.Clear(Color.Transparent);
                        gs.DrawImage(canvas, 0, 0, s, s);
                    }
                    using (MemoryStream ms = new MemoryStream())
                    {
                        bmp.Save(ms, ImageFormat.Png);
                        pngs.Add(ms.ToArray());
                    }
                }
            }
            using (MemoryStream ico = new MemoryStream())
            using (BinaryWriter w = new BinaryWriter(ico))
            {
                w.Write((ushort)0); w.Write((ushort)1); w.Write((ushort)sizes.Length);
                int offset = 6 + 16 * sizes.Length;
                for (int i = 0; i < sizes.Length; i++)
                {
                    byte dim = (byte)(sizes[i] >= 256 ? 0 : sizes[i]);
                    w.Write(dim); w.Write(dim); w.Write((byte)0); w.Write((byte)0);
                    w.Write((ushort)1); w.Write((ushort)32);
                    w.Write((uint)pngs[i].Length); w.Write((uint)offset);
                    offset += pngs[i].Length;
                }
                foreach (byte[] p in pngs) w.Write(p);
                w.Flush();
                File.WriteAllBytes(outPath, ico.ToArray());
            }
        }
    }
}
'@

function Test-NativeCurrent {
    $ver = Join-Path -Path (Get-BinDir) -ChildPath 'native.ver'
    return ((Test-Path -LiteralPath (Get-RunnerPath) -PathType Leaf) -and
        (Test-Path -LiteralPath (Get-NativePath) -PathType Leaf) -and
        (Test-Path -LiteralPath $ver -PathType Leaf) -and
        ([System.IO.File]::ReadAllText($ver).Trim() -ceq $script:NativeVersion))
}

# Build the two helper programs with the C# compiler that ships with Windows.
function Build-NativeTools {
    $csc = Join-Path -Path ([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) -ChildPath 'csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
        Fail 'The C# compiler that comes with Windows (.NET Framework 4) was not found.' 'Turn on .NET Framework 4.8 in Windows Features, then run: ghdp.ps1 install'
    }
    $bin = Get-BinDir
    Initialize-PrivateDir (Get-BaseDir)
    Initialize-PrivateDir $bin
    $tmp = Join-Path -Path $bin -ChildPath ('build-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tmp)
    try {
        Write-TextFile (Join-Path -Path $tmp -ChildPath 'native.cs') $script:NativeSource
        Write-TextFile (Join-Path -Path $tmp -ChildPath 'run.cs') $script:RunnerSource
        $out = @(& $csc /nologo /target:library /optimize "/out:$tmp\ghdp-native.dll" /reference:System.Drawing.dll "$tmp\native.cs")
        if ($LASTEXITCODE -ne 0) { Fail "Could not build the window helper: $($out -join ' ')" 'Please open an issue on the project page.' }
        $out = @(& $csc /nologo /target:winexe /optimize "/out:$tmp\ghdp-run.exe" "$tmp\run.cs")
        if ($LASTEXITCODE -ne 0) { Fail "Could not build the start helper: $($out -join ' ')" 'Please open an issue on the project page.' }
        Move-Item -LiteralPath "$tmp\ghdp-native.dll" -Destination (Get-NativePath) -Force
        Move-Item -LiteralPath "$tmp\ghdp-run.exe" -Destination (Get-RunnerPath) -Force
        Protect-PrivatePath (Get-NativePath) -IsFile
        Protect-PrivatePath (Get-RunnerPath) -IsFile
        Write-TextFile (Join-Path -Path $bin -ChildPath 'native.ver') $script:NativeVersion
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Load the window helpers. The file is read into memory, so it is never locked
# and can be rebuilt while a profile is open.
function Import-Native {
    if ($null -ne ('GhdpNative' -as [type])) { return }
    Add-Type -AssemblyName System.Drawing
    if (-not (Test-NativeCurrent)) { Build-NativeTools }
    # Only code that is a real file, owned by you and private is loaded.
    Assert-PrivateFile (Get-NativePath)
    [void][System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes((Get-NativePath)))
}

# Refuse to run if the installed tool or its helpers could have been changed by
# someone else (not yours, a link, or readable/writable by others). The Mac
# version does the same for its own file.
function Assert-ToolFilesPrivate {
    Initialize-PrivateDir (Get-BinDir)
    Assert-PrivateFile (Get-BinPath)
    Assert-PrivateFile (Get-RunnerPath)
    Assert-PrivateFile (Get-NativePath)
}

# ------------------------------------------------------------- wrong-account guard
# Each profile gets a hooks folder. Launching points Git at it with
# GIT_CONFIG_COUNT (core.hooksPath), which beats repo settings, so the guard
# also runs in repos that set their own hooks folder (for example husky).
# Every hook then runs the repo's own hook, so repo hooks keep working.
# The hooks are plain sh scripts: GitHub Desktop's own Git runs them.

$script:GuardHooks = @('applypatch-msg', 'pre-applypatch', 'post-applypatch', 'pre-commit', 'pre-merge-commit',
    'prepare-commit-msg', 'commit-msg', 'post-commit', 'pre-rebase', 'post-checkout', 'post-merge', 'pre-push',
    'post-rewrite', 'pre-auto-gc', 'sendemail-validate')

$script:HookScript = @'
#!/bin/sh
# Made by gh-desktop-profiles. Rewritten on every launch; do not edit.
#
# pre-commit and pre-push: stop commits and pushes that look like the wrong
# account (wrong email, a repo outside this profile's folders, or a GitHub
# owner this profile does not use). Every hook: then run the repo's own hook.
# Repo values (paths, remote URLs) are only compared as text, never run.

hook=$(basename "$0")
here=$(cd "$(dirname "$0")" && pwd -P)
profile_home=$(cd "$here/.." && pwd -P)
rules="$profile_home/guard.rules"

rule() { if [ -f "$rules" ]; then grep "^$1=" "$rules" | cut -d= -f2-; fi; }
lower() { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }
# A folder as a Windows path with forward slashes (C:/Users/you/work), so it
# compares with what Git prints.
real_dir() { if [ -d "$1" ]; then (cd "$1" && { pwd -W 2>/dev/null || pwd -P; }); else printf '%s' "$1"; fi; }
here_w=$(real_dir "$here")

# Print why we stopped and fail the hook. Control characters (which could
# come from a folder name or URL) are removed so they cannot mess up the
# screen.
stop() {
  {
    printf '\ngh-desktop-profiles stopped this in the "%s" profile:\n' "$(rule profile)"
    for line in "$@"; do printf '  %s\n' "$line"; done
    printf '\n'
  } | tr -d '\001-\010\013-\037\177' >&2
  exit 1
}

# Is path $1 inside folder $2? Compared without capital letters, because
# Windows folder names ignore them.
inside() {
  inside_path=$(lower "$1")
  inside_dir=$(lower "$2")
  case "$inside_path/" in "$inside_dir"/*) return 0 ;; esac
  return 1
}

# The part of a remote URL after the host: "owner/repo..." (nothing for a
# local path). Understands https://host/owner/repo, ssh://user@host/owner/repo,
# user@host:owner/repo, or an SSH host alias like work-github:owner/repo.
path_of() {
  u=$1
  case $u in
    [A-Za-z]:[\\/]* | \\\\*) return 0 ;; # a Windows folder (C:\repo, C:/repo, \\server\share): local
  esac
  case $u in
    *://*) u=${u#*://} ;;
    *)
      host=${u%%:*}
      case $host in
        "$u" | '' | */*) return 0 ;; # no ":" before a "/": a local path
      esac
      printf '%s' "${u#*:}"
      return 0
      ;;
  esac
  host=${u%%/*}
  [ -n "$host" ] || return 0
  case $host in *@*) u=${u#*@} ;; esac
  printf '%s' "${u#*/}"
}

owner_of() {
  rpath=$(path_of "$1")
  lower "${rpath%%/*}"
}

# "owner/name" in lower case, without ".git". Nothing unless the path is
# exactly owner/name (a trailing slash is fine).
repo_of() {
  rpath=$(path_of "$1")
  rpath=${rpath%/}
  case $rpath in */*/*) return 0 ;; */*) ;; *) return 0 ;; esac
  rname=${rpath#*/}
  rname=${rname%.git}
  lower "${rpath%%/*}/$rname"
}

# True if a remote URL has a shape that could make the text we read differ
# from the place Git really contacts: "." or ".." segments, %-escapes, ? and #,
# backslashes, spaces, or non-ASCII characters.
odd_url() {
  case $1 in *\\*) return 0 ;; esac
  rcheck="/$2/"
  case $rcheck in
    */./* | */../* | *%* | *\?* | *'#'* | *\\* | *' '*) return 0 ;;
  esac
  case $(printf '%s' "$2" | LC_ALL=C tr -d ' -~') in '') return 1 ;; *) return 0 ;; esac
}

# A remote URL without any "user:token@" part, safe to show on screen.
safe_url() {
  case $1 in
    *://*@*)
      scheme=${1%%://*}
      rest=${1#*://}
      host=${rest%%/*}
      case $host in *@*) rest=${rest#*@} ;; esac
      printf '%s://%s' "$scheme" "$rest"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

check_identity() {
  want=$(rule email)
  [ -n "$want" ] || return 0
  for who in GIT_AUTHOR_IDENT GIT_COMMITTER_IDENT; do
    got=$(git var "$who" 2>/dev/null | sed -n 's/.*<\(.*\)>.*/\1/p')
    if [ "$(lower "$got")" != "$(lower "$want")" ]; then
      stop "This commit would use the email \"$got\", but this profile uses \"$want\"." \
        "Check that you opened the right GitHub Desktop profile."
    fi
  done
}

other_profile_for() {
  for r in "$profile_home"/../*/guard.rules; do
    [ -f "$r" ] || continue
    [ "$(cd "$(dirname "$r")" && pwd -P)" = "$profile_home" ] && continue
    p=$(grep '^profile=' "$r" | cut -d= -f2-)
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if inside "$1" "$(real_dir "$f")"; then
        printf '%s' "$p"
        return 0
      fi
    done <<EOF
$(grep '^folder=' "$r" | cut -d= -f2-)
EOF
  done
  return 0
}

# The repo must not be in another profile's folders, and if this profile
# has folders, it must be inside one of them.
check_folder() {
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  top=$(real_dir "$top")
  folders=$(rule folder)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if inside "$top" "$(real_dir "$f")"; then return 0; fi
  done <<EOF
$folders
EOF
  other=$(other_profile_for "$top")
  if [ -n "$other" ]; then
    stop "This repo ($top) belongs to the \"$other\" profile." \
      "Open it in \"GitHub Desktop - $other\" instead."
  fi
  if [ -n "$folders" ]; then
    stop "This repo ($top) is outside the folders set for this profile." \
      "If it belongs here, add its folder to this profile (run setup again), then try again."
  fi
}

other_profile_for_owner() {
  for r in "$profile_home"/../*/guard.rules; do
    [ -f "$r" ] || continue
    [ "$(cd "$(dirname "$r")" && pwd -P)" = "$profile_home" ] && continue
    if grep -qxF -- "owner=$1" "$r"; then
      grep '^profile=' "$r" | cut -d= -f2-
      return 0
    fi
  done
  return 0
}

# The remote's GitHub owner must not be another profile's owner, and if
# this profile has owners, it must be one of them.
check_owner() {
  # Fail closed on anything that cannot be read safely.
  case $1 in
    *[[:cntrl:]]*) stop "The remote URL of this repo has unusual characters, so it could not be checked." \
      "Fix the remote URL in this repo, then try again." ;;
  esac
  rpath=$(path_of "$1")
  if [ -n "$rpath" ] && odd_url "$1" "$rpath"; then
    stop "The remote $(safe_url "$1") has an unusual shape (for example \"..\", a % sign, a space or odd letters), so it could not be checked safely." \
      "Fix the remote URL in this repo, then try again."
  fi
  o=$(owner_of "$1")
  [ -n "$o" ] || return 0
  case $o in
    *[!a-z0-9-]*) stop "Could not read the GitHub owner of the remote $(safe_url "$1")." \
      "Fix the remote URL in this repo, then try again." ;;
  esac
  shown=${rpath%%/*}
  # A repo the user allowed for this profile with "ghdp.ps1 allow".
  repo=$(repo_of "$1")
  if [ -n "$repo" ] && rule repo | grep -qxF -- "$repo"; then return 0; fi
  case $repo in *[!a-z0-9._/-]*) repo="" ;; esac
  hint="Or allow just this repo for this profile (in PowerShell, from the gh-desktop-profiles folder): windows\\ghdp.ps1 allow $(rule profile) ${repo:-owner/repo}"
  owners=$(rule owner)
  if [ -n "$owners" ] && printf '%s\n' "$owners" | grep -qxF -- "$o"; then return 0; fi
  other=$(other_profile_for_owner "$o")
  if [ -n "$other" ]; then
    stop "The remote $(safe_url "$1") belongs to \"$shown\", which is set for the \"$other\" profile." \
      "Open this repo in \"GitHub Desktop - $other\" instead." \
      "$hint"
  fi
  if [ -n "$owners" ]; then
    stop "The remote $(safe_url "$1") belongs to \"$shown\", which this profile does not use." \
      "This profile is for: $(printf '%s' "$owners" | tr '\n' ' ')" \
      "Open the right GitHub Desktop profile." \
      "$hint"
  fi
}

# New commits being pushed must have been made with this profile's email.
# Only commits that are on no remote yet count: work already on GitHub (a
# teammate's commits, pull requests merged on github.com) is never flagged.
# If the commits cannot be listed, the push is stopped (fail closed).
check_pushed_commits() {
  want=$(lower "$(rule email)")
  [ -n "$want" ] || return 0
  zero=$(git hash-object --stdin </dev/null | sed 's/./0/g')
  while read -r _ lsha _ rsha; do
    [ -n "$lsha" ] || continue
    [ "$lsha" = "$zero" ] && continue # deleting a branch
    if [ "$rsha" != "$zero" ] && git cat-file -e "$rsha^{commit}" 2>/dev/null; then
      found=$(git log --format=%ce "$lsha" "^$rsha" --not --remotes 2>/dev/null) ||
        stop "Could not list the commits being pushed." "Fetch, then try the push again."
    else
      found=$(git log --format=%ce "$lsha" --not --remotes 2>/dev/null) ||
        stop "Could not list the commits being pushed." "Fetch, then try the push again."
    fi
    bad=$(printf '%s\n' "$found" | tr '[:upper:]' '[:lower:]' | grep -v -x -F -e "$want" -e '' | sort -u | head -n 3 | tr '\n' ' ')
    if [ -n "$bad" ]; then
      stop "Some new commits you are pushing were made with another email: $bad" \
        "This profile uses \"$(rule email)\". Check that these commits belong to this account." \
        "If they are other people's work (for example a project you copied), push once from" \
        "a terminal in this repo with: git push --no-verify"
    fi
  done <<EOF
$1
EOF
}

input=''
case "$hook" in
  pre-commit | pre-merge-commit)
    check_identity
    check_folder
    check_owner "$(git remote get-url origin 2>/dev/null)"
    ;;
  pre-push)
    input=$(cat)
    check_owner "$2"
    check_folder
    check_pushed_commits "$input"
    ;;
esac

# Run the repo's own hook for this event: the hooks folder the repo (or your
# normal Git settings) chose, else .git/hooks.
hooks_path=$(env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 git config --get core.hooksPath 2>/dev/null)
if [ -n "$hooks_path" ]; then
  case $hooks_path in
    "~/"*) hooks_path="$HOME/${hooks_path#\~/}" ;;
  esac
else
  hooks_path="$(git rev-parse --git-common-dir 2>/dev/null)/hooks"
fi
target="$hooks_path/$hook"
if [ ! -f "$target" ] || [ ! -x "$target" ]; then exit 0; fi
tdir=$(real_dir "$(dirname "$target")")
if [ "$tdir" = "$here" ] || [ "$tdir" = "$here_w" ]; then exit 0; fi # never call ourselves
if [ "$hook" = "pre-push" ]; then
  if [ -n "$input" ]; then printf '%s\n' "$input"; fi | "$target" "$@"
  exit $?
fi
exec "$target" "$@"
'@

# Write this profile's guard rules (from profiles.json) and the hook scripts.
function Write-Guard($ProfileItem) {
    $name = $ProfileItem.Name
    $hooks = Get-HooksDir $name
    Initialize-PrivateDir $hooks
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Made by gh-desktop-profiles from profiles.json. Rewritten on every launch.')
    $lines.Add("profile=$name")
    $lines.Add("email=$($ProfileItem.GitEmail)")
    foreach ($f in $ProfileItem.Folders) { $lines.Add("folder=$(Expand-Folder $f)") }
    foreach ($o in $ProfileItem.Owners) { $lines.Add("owner=$($o.ToLowerInvariant())") }
    foreach ($r in $ProfileItem.Repos) { $lines.Add("repo=$($r.ToLowerInvariant())") }
    Write-FileAtomic (Get-GuardPath $name) (($lines -join "`n") + "`n")
    $hookText = $script:HookScript -replace "`r`n", "`n"
    foreach ($h in $script:GuardHooks) {
        Write-FileAtomic (Join-Path -Path $hooks -ChildPath $h) $hookText
    }
}

# Guard rules of profiles that are no longer in profiles.json are removed, so
# the guard never points people at a profile that does not exist.
function Remove-StaleGuards([object[]]$Profiles) {
    $root = Get-ProfilesRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
    $keep = @($Profiles | ForEach-Object { Get-NormalName $_.Name })
    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory) {
        if ($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $rules = Join-Path -Path $dir.FullName -ChildPath 'guard.rules'
        if ((Test-Path -LiteralPath $rules -PathType Leaf) -and ($keep -notcontains (Get-NormalName $dir.Name))) {
            Remove-Item -LiteralPath $rules -Force
        }
    }
}

# ----------------------------------------------------------- profile set-up

# One badge color per profile position, so each icon looks different.
function Get-BadgeColor([int]$Index) {
    $palette = @(
        @(37, 99, 235),   # blue
        @(22, 163, 74),   # green
        @(234, 88, 12),   # orange
        @(219, 39, 119),  # pink
        @(13, 148, 136),  # teal
        @(202, 138, 4),   # amber
        @(220, 38, 38),   # red
        @(79, 70, 229)    # indigo
    )
    return $palette[$Index % 8]
}

# Draw the profile's icon again only when its letter, color or the GitHub
# Desktop version changed.
function Update-ProfileIcon($ProfileItem, [string]$Exe, [int]$Index) {
    Import-Native
    $ico = Get-IconPath $ProfileItem.Name
    $keyFile = "$ico.key"
    $rgb = Get-BadgeColor $Index
    $letter = $ProfileItem.Name.Substring(0, 1).ToUpperInvariant()
    $key = "$letter-$($rgb -join ',')-$Exe"
    if ((Test-Path -LiteralPath $ico -PathType Leaf) -and (Test-Path -LiteralPath $keyFile -PathType Leaf) -and
        ([System.IO.File]::ReadAllText($keyFile) -ceq $key)) { return }
    [GhdpNative]::BuildBadgeIcon($Exe, $ico, $letter, $rgb[0], $rgb[1], $rgb[2])
    Write-TextFile $keyFile $key
}

# Create the profile's private folders, Git settings file, guard and icon, and
# keep the name and email in step with profiles.json. Uses the Git that ships
# inside GitHub Desktop (no extra dependency).
function Initialize-Profile($ProfileItem, [string]$Exe, [int]$Index = 0, [switch]$NoIcon) {
    $gitConfig = Get-GitConfigPath $ProfileItem.Name
    Initialize-PrivateDir (Get-BaseDir)
    Initialize-PrivateDir (Get-ProfilesRoot)
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
    $git = Get-DesktopGit $Exe
    if (Test-Path -LiteralPath $git -PathType Leaf) {
        & $git config --file $gitConfig --replace-all user.name $ProfileItem.GitName
        if ($LASTEXITCODE -ne 0) { Fail 'Could not write the Git name for this profile.' 'Run: ghdp.ps1 install' }
        & $git config --file $gitConfig --replace-all user.email $ProfileItem.GitEmail
        if ($LASTEXITCODE -ne 0) { Fail 'Could not write the Git email for this profile.' 'Run: ghdp.ps1 install' }
    }
    Write-Guard $ProfileItem
    if (-not $NoIcon) { Update-ProfileIcon $ProfileItem $Exe $Index }
}

# Copy this script to a fixed private place. Shortcuts run that copy, so a
# later change in the project folder never runs until you install again.
# Reading and writing the bytes (not copying the file) leaves out the
# "downloaded from the internet" mark, so RemoteSigned can run the copy.
function Install-Self {
    $dst = Get-BinPath
    Initialize-PrivateDir (Split-Path -Path $dst -Parent)
    if ($PSCommandPath -ne $dst) {
        [System.IO.File]::WriteAllBytes($dst, [System.IO.File]::ReadAllBytes($PSCommandPath))
    }
    Assert-PrivateFile $dst
    if (-not (Test-NativeCurrent)) { Build-NativeTools }
}

# --------------------------------------------------------------- shortcuts

# True if a shortcut is one this tool made (current or older style), for any profile.
function Get-OurShortcutProfile($Shell, [string]$LnkPath) {
    $lnk = $Shell.CreateShortcut($LnkPath)
    $runner = Get-RunnerPath
    if ($lnk.TargetPath -ieq $runner -and $lnk.Arguments -cmatch '\Alaunch ([A-Za-z0-9][A-Za-z0-9_-]{0,31})\z') { return $Matches[1] }
    if ($lnk.Arguments -cmatch '-File "[^"]*gh-desktop-profiles[\\/]bin[\\/]ghdp\.ps1" launch ([A-Za-z0-9][A-Za-z0-9_-]{0,31}) -Gui\z') { return $Matches[1] }
    return $null
}

# Create (or refresh) a Start menu shortcut for one profile. It has the
# profile's own icon and taskbar identity, so you can pin it to the taskbar.
function Add-ProfileShortcut([string]$ProfileName) {
    Import-Native
    $dir = Get-ShortcutDir
    if (Test-Path -LiteralPath $dir) {
        if (Test-ReparsePoint $dir) { Fail "`"$dir`" is a link, not a real folder." 'Remove the link, then try again.' }
    } else {
        [void](New-Item -ItemType Directory -Path $dir)
    }
    $runner = Get-RunnerPath
    $lnkPath = Get-ShortcutPath $ProfileName
    $shell = New-Object -ComObject WScript.Shell
    if (Test-Path -LiteralPath $lnkPath) {
        $owner = Get-OurShortcutProfile $shell $lnkPath
        if ($null -eq $owner -or (Get-NormalName $owner) -ne (Get-NormalName $ProfileName)) {
            Fail "`"$lnkPath`" already exists and was not made by this tool." 'Rename or remove it, then run: ghdp.ps1 install'
        }
    }
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = $runner
    $lnk.Arguments = "launch $ProfileName"
    $lnk.WorkingDirectory = Split-Path -Path $runner -Parent
    $lnk.WindowStyle = 1
    $lnk.IconLocation = "$(Get-IconPath $ProfileName),0"
    $lnk.Description = "Open GitHub Desktop with the $ProfileName profile"
    $lnk.Save()
    if (-not [GhdpNative]::SetLinkAppId($lnkPath, (Get-Aumid $ProfileName))) {
        Write-Line "  (Could not set the taskbar identity of the $ProfileName shortcut. It still works.)"
    }
}

# Remove shortcuts this tool made for profiles that are no longer in profiles.json.
function Remove-StaleShortcuts([object[]]$Profiles) {
    $dir = Get-ShortcutDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container) -or (Test-ReparsePoint $dir)) { return }
    $keep = @($Profiles | ForEach-Object { Get-NormalName $_.Name })
    $shell = New-Object -ComObject WScript.Shell
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File) {
        $owner = Get-OurShortcutProfile $shell $file.FullName
        if ($null -ne $owner -and ($keep -notcontains (Get-NormalName $owner))) {
            Remove-Item -LiteralPath $file.FullName -Force
            Write-Line "Removed the shortcut of an old profile: $($file.Name)"
        }
    }
}

# ---------------------------------------------------------- sign-in link
# GitHub Desktop signs in through your browser. GitHub then calls a link
# (x-github-desktop-auth://...). Windows normally starts a NEW plain GitHub
# Desktop for it, which has none of your profiles, so the profile that is
# waiting never hears back and sign-in fails.
# This tool takes over that one link: it hands the reply to the profile you
# were just using, so the right window completes the sign-in.

function Get-HandlerCommand { return "`"$(Get-RunnerPath)`" handle `"%1`"" }

function Get-ProtocolHandler {
    return [Microsoft.Win32.Registry]::GetValue($script:ProtocolKey, '', $null)
}

function Test-ProtocolHandlerOurs {
    $value = Get-ProtocolHandler
    return ($null -ne $value -and $value -ceq (Get-HandlerCommand))
}

function Register-ProtocolHandler {
    if (-not $script:OnWindows) { return }
    if (-not (Test-Path -LiteralPath (Get-RunnerPath) -PathType Leaf)) { return }
    if (Test-ProtocolHandlerOurs) { return }
    [Microsoft.Win32.Registry]::SetValue($script:ProtocolKey, '', (Get-HandlerCommand))
}

# Give the link back to GitHub Desktop itself (what its installer registers).
function Unregister-ProtocolHandler {
    $value = Get-ProtocolHandler
    if ($null -eq $value -or $value -cne (Get-HandlerCommand)) { return }
    $exe = Find-DesktopExe
    if ($null -ne $exe) {
        [Microsoft.Win32.Registry]::SetValue($script:ProtocolKey, '', "`"$exe`" --protocol-launcher `"%1`"")
    }
}

# Running GitHub Desktop main programs that belong to one of our profiles.
function Get-ProfileProcesses {
    $found = New-Object System.Collections.Generic.List[object]
    $root = (Get-ProfilesRoot).TrimEnd('\')
    $query = Get-CimInstance Win32_Process -Filter "Name='GitHubDesktop.exe'" -ErrorAction SilentlyContinue
    foreach ($proc in @($query)) {
        $cl = $proc.CommandLine
        if (-not $cl -or $cl -match '--type=' -or $cl -match '--protocol-launcher') { continue }
        if ($cl -notmatch '--user-data-dir="([^"]+)"') { continue }
        $dir = $Matches[1]
        if ($dir.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $rest = $dir.Substring($root.Length + 1)
            if ($rest -match '\A([^\\]+)\\desktop-data\z') {
                $found.Add([pscustomobject]@{ Name = $Matches[1]; ProcessId = [int]$proc.ProcessId; DataDir = $dir })
            }
        }
    }
    return $found.ToArray()
}

function Find-ProfileProcess([string]$ProfileName) {
    foreach ($p in (Get-ProfileProcesses)) { if ($p.Name -ieq $ProfileName) { return $p } }
    return $null
}

function Show-ProfileChooser([string[]]$Names) {
    Add-Type -AssemblyName System.Windows.Forms
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'GitHub Desktop Profiles'
    $form.StartPosition = 'CenterScreen'
    $form.AutoSize = $true
    $form.AutoSizeMode = 'GrowAndShrink'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.FlowDirection = 'TopDown'
    $panel.AutoSize = $true
    $panel.Padding = New-Object System.Windows.Forms.Padding(16)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Which profile is signing in?'
    $label.AutoSize = $true
    $panel.Controls.Add($label)
    $script:ChosenProfile = $null
    foreach ($n in $Names) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $n
        $b.Width = 260
        $b.Tag = $n
        $b.Add_Click({ param($s, $e) $script:ChosenProfile = [string]$s.Tag; $form.Close() })
        $panel.Controls.Add($b)
    }
    $form.Controls.Add($panel)
    [void]$form.ShowDialog()
    return $script:ChosenProfile
}

# The sign-in link, run by Windows. Strictly checked, then handed to the
# profile you were just using.
function Invoke-Handle([string]$Url) {
    if ($Url -cnotmatch '\Ax-github-desktop-auth://[A-Za-z0-9._~%+/=&?:-]{1,2000}\z') {
        Fail 'The sign-in link looks unusual, so it was ignored.' 'Start the sign-in again from GitHub Desktop.'
    }
    Assert-ToolFilesPrivate
    $running = @(Get-ProfileProcesses)
    if ($running.Count -eq 0) {
        Fail 'No GitHub Desktop profile is open to finish the sign-in.' 'Open your profile from the Start menu, click Sign in again, and finish in the browser.'
    }
    $target = $null
    $active = Get-ActiveProfileName
    if ($active) { $target = $running | Where-Object { $_.Name -ieq $active } | Select-Object -First 1 }
    if ($null -eq $target -and $running.Count -eq 1) { $target = $running[0] }
    if ($null -eq $target) {
        $chosen = Show-ProfileChooser @($running | ForEach-Object { $_.Name })
        if (-not $chosen) { return }
        $target = $running | Where-Object { $_.Name -ceq $chosen } | Select-Object -First 1
    }
    $exe = Get-VerifiedDesktop
    # The program is started like Windows would, plus this profile's data
    # folder: Electron then passes the link on to the window already open there.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "--protocol-launcher `"$Url`" --user-data-dir=`"$($target.DataDir)`""
    $psi.WorkingDirectory = Split-Path -Path $exe -Parent
    $psi.UseShellExecute = $false
    [void][System.Diagnostics.Process]::Start($psi)
    Import-Native
    $hwnd = [GhdpNative]::FindMainWindow([uint32]$target.ProcessId)
    if ($hwnd -ne [IntPtr]::Zero) { [GhdpNative]::BringToFront($hwnd) }
}

# Remember which profile window you used last: that is the one waiting for the
# sign-in reply.
function Get-ActiveProfileName {
    $path = Get-ActivePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Test-ReparsePoint $path)) { return '' }
    $value = [System.IO.File]::ReadAllText($path).Trim()
    if (Test-ProfileName $value) { return $value }
    return ''
}

# --------------------------------------------------- one taskbar icon per profile

# Runs for as long as the profile's window is open (inside the hidden program
# the shortcut starts). It gives the window its own taskbar button, icon and
# title, remembers which profile you used last, and keeps the sign-in link ours.
function Watch-Profile([System.Diagnostics.Process]$Proc, $ProfileItem) {
    Import-Native
    $name = $ProfileItem.Name
    $ico = Get-IconPath $name
    $aumid = Get-Aumid $name
    $relaunch = "`"$(Get-RunnerPath)`" launch $name"
    $display = "GitHub Desktop - $name"
    $applied = [IntPtr]::Zero
    $lastActive = ''
    $tick = 0
    Register-ProtocolHandler
    while (-not $Proc.HasExited) {
        $hwnd = [GhdpNative]::FindMainWindow([uint32]$Proc.Id)
        if ($hwnd -ne [IntPtr]::Zero) {
            if ($hwnd -ne $applied) {
                [void][GhdpNative]::ApplyIdentity($hwnd, $aumid, $relaunch, "$ico,0", $display)
                [GhdpNative]::SetIcons($hwnd, $ico)
                $applied = $hwnd
            }
            if ($tick % 10 -eq 0) { [GhdpNative]::SetIcons($hwnd, $ico) }
            if ([GhdpNative]::GetTitle($hwnd) -cne $display) { [GhdpNative]::SetTitle($hwnd, $display) }
        }
        if ([GhdpNative]::ForegroundPid() -eq [uint32]$Proc.Id -and $lastActive -cne $name) {
            Write-TextFile (Get-ActivePath) $name
            $lastActive = $name
        } elseif ([GhdpNative]::ForegroundPid() -ne [uint32]$Proc.Id) {
            $lastActive = ''
        }
        if ($tick % 10 -eq 5) { Register-ProtocolHandler } # GitHub Desktop sets it back to itself when it starts
        $tick++
        Start-Sleep -Milliseconds 300
    }
}

# ---------------------------------------------------------- setup wizard and import

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
    $partial = "$Destination.partial"
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $partial)
    Protect-PrivatePath $partial
    Copy-Tree $Source $partial
    # Moved into place only when complete, so a failed copy never counts as real data.
    Move-Item -LiteralPath $partial -Destination $Destination
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

# Ask for an optional, comma-separated list. Returns the valid items.
function Read-List([string]$Question, [scriptblock]$Test, [string]$Hint) {
    while ($true) {
        $answer = Read-Answer $Question
        $items = New-Object System.Collections.Generic.List[string]
        $ok = $true
        foreach ($raw in ($answer -split ',')) {
            $item = $raw.Trim()
            if ($item.Length -gt 3) { $item = $item.TrimEnd('/', '\') }
            if (-not $item) { continue }
            if (-not (& $Test $item)) {
                Write-Line "  `"$item`" is not allowed. $Hint"
                $ok = $false
                break
            }
            $items.Add($item)
        }
        if ($ok -and $items.Count -gt $script:MaxRules) {
            Write-Line "  Please give at most $($script:MaxRules)."
            $ok = $false
        }
        if ($ok) { return , $items.ToArray() }
    }
}

# The guard rules for one profile. Owners are recommended: without folders
# or owners, the guard can only check the email, so we say so and offer to
# add owners once more.
function Read-Rules($Item) {
    $Item.Folders = Read-List "  Folders used ONLY for this account's repos, comma separated (optional, e.g. ~/work or D:\work)" { param($v) Test-Folder $v } 'Use ~/folder or a full path like D:\work.'
    $Item.Owners = Read-List '  GitHub owners for this account: your username and organizations, comma separated (recommended; the part after github.com/ in a repo link)' { param($v) Test-Owner $v } 'Use a GitHub username or organization name.'
    if (@($Item.Folders).Count -eq 0 -and @($Item.Owners).Count -eq 0) {
        Write-Line '  Without folders or owners, the guard can only check the email. It cannot'
        Write-Line '  tell that a repo belongs to another account.'
        if (Read-YesNo '  Add GitHub owners for this account now (recommended)?' 'y') {
            $Item.Owners = Read-List '  GitHub owners for this account, comma separated' { param($v) Test-Owner $v } 'Use a GitHub username or organization name.'
        }
    }
}

function New-WizardItem([string]$ProfileName, [string]$GitName, [string]$GitEmail) {
    return [pscustomobject]@{ Name = $ProfileName; GitName = $GitName; GitEmail = $GitEmail; Folders = [string[]]@(); Owners = [string[]]@(); Repos = [string[]]@() }
}

# Start from the profiles already in profiles.json, so the wizard can add to
# them or take one away without asking for the rest.
function Copy-ProfilesToWizard([object[]]$Profiles) {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Profiles) {
        $list.Add([pscustomobject]@{ Name = $p.Name; GitName = $p.GitName; GitEmail = $p.GitEmail
                Folders = [string[]]@($p.Folders); Owners = [string[]]@($p.Owners); Repos = [string[]]@($p.Repos) })
    }
    return , $list
}

# Read one value from your normal Git settings, to offer it as a default.
# Uses the Git inside GitHub Desktop; never changes anything.
function Get-GlobalGitValue([string]$Key, [string]$Exe) {
    $git = Get-DesktopGit $Exe
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
    $list = @($Items | ForEach-Object {
            $entry = [ordered]@{ name = $_.Name; gitName = $_.GitName; gitEmail = $_.GitEmail }
            if (@($_.Folders).Count -gt 0) { $entry['folders'] = [string[]]@($_.Folders) }
            if (@($_.Owners).Count -gt 0) { $entry['owners'] = [string[]]@($_.Owners) }
            if (@($_.Repos).Count -gt 0) { $entry['repos'] = [string[]]@($_.Repos) }
            $entry
        })
    $json = ConvertTo-Json -InputObject ([ordered]@{ version = 1; profiles = $list }) -Depth 5
    Initialize-PrivateDir (Get-BaseDir)
    if (Test-Path -LiteralPath $cfg -PathType Leaf) {
        $backup = "$cfg.bak"
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force } # never write through a planted link
        Write-TextFile $backup ([System.IO.File]::ReadAllText($cfg))
        Assert-PrivateFile $backup
    }
    Write-TextFile $cfg $json
    Assert-PrivateFile $cfg
}

# Move a folder to the Recycle Bin (so it can be put back). Never deletes permanently.
function Move-ToRecycleBin([string]$Path) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    } catch {
        Fail "Could not move `"$Path`" to the Recycle Bin automatically." 'Delete that folder yourself in File Explorer.'
    }
}

function Get-ProfileNames([object[]]$Profiles) { return (($Profiles | ForEach-Object { $_.Name }) -join ', ') }

function Test-Interactive { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) }

# Start a profile the same way its shortcut does, without waiting for it.
function Start-ProfileWindow([string]$ProfileName) {
    $runner = Get-RunnerPath
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { Fail 'The start helper is missing.' 'Run: ghdp.ps1 install' }
    [void][System.Diagnostics.Process]::Start($runner, "launch $ProfileName")
}

# The last step of setup and add: offer to open the profile, and say where the shortcut is.
function Show-AfterSetup([string]$ProfileName) {
    Write-Line ''
    Write-Line "Your shortcuts are in the Start menu, in the folder `"GitHub Desktop Profiles`"."
    Write-Line 'Open one, then right-click its taskbar button and choose "Pin to taskbar":'
    Write-Line 'each profile keeps its own taskbar icon, with its own colored badge.'
    if (Test-Interactive) {
        Write-Line ''
        if (Read-YesNo "Open `"GitHub Desktop - $ProfileName`" now?" 'y') { Start-ProfileWindow $ProfileName }
    }
}

# ------------------------------------------------------------------ commands

# Guided setup: asks for your profiles, can copy your current GitHub Desktop
# into the first one, writes profiles.json and installs the shortcuts.
function Invoke-Setup {
    Write-Line 'GitHub Desktop Profiles setup'
    Write-Line 'You will get one GitHub Desktop icon per GitHub account.'
    Write-Line 'Never type a password here. You sign in later, inside GitHub Desktop.'
    Write-Line ''
    $exe = Get-VerifiedDesktop
    Write-Line 'GitHub Desktop: found, and signed by GitHub.'
    Initialize-PrivateDir (Get-BaseDir)
    if (Test-Path -LiteralPath (Get-ConfigPath)) {
        $existing = $null
        try { $existing = Read-Config } catch { $existing = $null }
        if ($null -ne $existing) {
            if (-not (Show-SetupMenu $existing)) { return }
        } else {
            Write-Line 'You already have a profiles.json, but it has a problem.'
            Write-Line 'A new setup replaces it (your old profiles.json is kept as a backup).'
            Write-Line 'If you say no, nothing is replaced and the problem is shown.'
            if (-not (Read-YesNo 'Start a new setup?' 'n')) {
                Write-Line ''
                Invoke-Install
                return
            }
        }
    }

    $items = New-Object System.Collections.Generic.List[object]
    $defaultName = Get-GlobalGitValue 'user.name' $exe
    if (-not (Test-GitName $defaultName)) { $defaultName = '' }
    $defaultEmail = Get-GlobalGitValue 'user.email' $exe
    if (-not (Test-Email $defaultEmail)) { $defaultEmail = '' }
    $copyEmail = $defaultEmail
    $spareEmail = ''
    $import = ''

    $normal = Get-NormalDataDir
    if ((Test-Path -LiteralPath (Join-Path -Path $normal -ChildPath 'Local Storage')) -and -not (Test-ReparsePoint $normal)) {
        Write-Line ''
        Write-Line 'Your current GitHub Desktop already has a login and a repo list.'
        Write-Line 'To see which GitHub account it uses: open GitHub Desktop > File > Options > Accounts.'
        Write-Line '(Its WHOLE repo list is copied. If it holds repos of another account, you'
        Write-Line 'remove them from this profile afterwards; setup tells you how.)'
        if (Read-YesNo 'Copy them into your first profile, so that account does not need to sign in again?' 'y') {
            $quick = $false
            $owner = Get-OwnerFromEmail $defaultEmail
            if ($owner) {
                Write-Line ''
                Write-Line "Your Git email $defaultEmail belongs to the GitHub account `"$owner`"."
                if (Read-YesNo "Is your current GitHub Desktop signed in to `"$owner`"? Check in GitHub Desktop > File > Options > Accounts" '') {
                    if ($defaultName -and (Test-ProfileName $owner) -and -not (Test-Path -LiteralPath (Get-DataDir $owner))) {
                        Write-Line ''
                        Write-Line 'Quick setup. Your current GitHub Desktop becomes your first profile:'
                        Write-Line "  account:  $owner (the account your GitHub Desktop is signed in to)"
                        Write-Line "  name:     $owner   (the shortcut will be called `"GitHub Desktop - $owner`")"
                        Write-Line "  commits:  $defaultName <$defaultEmail>"
                        Write-Line "  guard:    keeps the GitHub owner `"$owner`" apart from your other accounts"
                        if (Read-YesNo 'Does this look right? (say n to choose these yourself)' 'y') { $quick = $true }
                    }
                } else {
                    Write-Line 'Then give this profile the email of the account GitHub Desktop is signed in to.'
                    Write-Line 'Your Git email is offered for your next profile instead.'
                    $copyEmail = ''
                    $spareEmail = $defaultEmail
                }
            }
            if ($quick) {
                $item = New-WizardItem $owner $defaultName $defaultEmail
                $item.Owners = [string[]]@($owner)
                $items.Add($item)
                $import = $owner
            } else {
                $pName = Read-ProfileName -Number 1 -Taken $items.ToArray() -MustBeNew
                $item = New-WizardItem $pName (Read-GitName $defaultName) (Read-Email $copyEmail)
                if ($item.GitEmail -ceq $spareEmail) { $spareEmail = '' }
                Read-Rules $item
                $items.Add($item)
                $import = $pName
            }
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
        $item = New-WizardItem $pName (Read-GitName $lastName) (Read-Email $spareEmail)
        $spareEmail = ''
        Read-Rules $item
        $items.Add($item)
    }

    Write-Line ''
    Write-Line 'Your profiles:'
    foreach ($p in $items) {
        $how = if ($p.Name -ceq $import) { 'copied from your current GitHub Desktop' } else { 'new: sign in once' }
        Write-Line "  $($p.Name): $($p.GitName) <$($p.GitEmail)> ($how)"
        if (@($p.Folders).Count -gt 0) { Write-Line "      folders: $(@($p.Folders) -join ' ')" }
        if (@($p.Owners).Count -gt 0) { Write-Line "      owners: $(@($p.Owners) -join ' ')" }
        if (@($p.Folders).Count -eq 0 -and @($p.Owners).Count -eq 0) { Write-Line '      guard: email check only (no folders or owners)' }
    }
    if (-not (Read-YesNo 'Create these profiles?' 'y')) {
        Write-Line 'Nothing changed.'
        return
    }

    if ($import) {
        while (Test-DesktopHoldsData $normal) {
            Write-Line 'Please close GitHub Desktop now (File > Exit).'
            [void](Read-Answer 'Then press Enter to continue')
        }
        Initialize-PrivateDir (Get-ProfilesRoot)
        Initialize-PrivateDir (Get-ProfileDir $import)
        Copy-DesktopData $normal (Get-DataDir $import)
        Write-Line "Copied your GitHub Desktop data into `"$import`". Your normal GitHub Desktop is unchanged."
    }
    # Written only now, after any copy succeeded.
    Write-ProfilesJson $items.ToArray()
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
    Show-AfterSetup $items[0].Name
}

# What to do when you already have profiles. Returns $true only for "start
# over" (the caller then runs the full wizard); the other choices do their
# work here and return $false.
function Show-SetupMenu([object[]]$Profiles) {
    Write-Line "You have $($Profiles.Count) profile(s): $(Get-ProfileNames $Profiles)."
    Write-Line 'What do you want to do?'
    Write-Line '  1) Add a profile'
    Write-Line '  2) Remove a profile'
    Write-Line '  3) Start over (replaces ALL profiles; profiles.json is backed up)'
    Write-Line '  4) Nothing, just refresh the shortcuts'
    while ($true) {
        $choice = Read-Answer 'Choose 1-4' '1'
        switch ($choice) {
            '1' { Write-Line ''; Invoke-Add; return $false }
            '2' { Write-Line ''; Invoke-Remove ''; return $false }
            '3' { return $true }
            '4' { Write-Line ''; Invoke-Install; return $false }
        }
        Write-Line '  Please type 1, 2, 3 or 4.'
    }
}

# Add one profile. The profiles you already have are not asked about and
# not changed. Nothing is written until you confirm.
function Invoke-Add {
    $profiles = Read-Config
    if ($profiles.Count -ge $script:MaxProfiles) { Fail "You already have $($script:MaxProfiles) profiles, which is the limit." 'Remove one first: ghdp.ps1 remove <name>' }
    [void](Get-VerifiedDesktop)
    Initialize-PrivateDir (Get-BaseDir)
    $before = [System.IO.File]::ReadAllText((Get-ConfigPath))
    Write-Line "Add a profile. Your other profiles ($(Get-ProfileNames $profiles)) are not changed."
    $items = Copy-ProfilesToWizard $profiles
    $pName = Read-ProfileName -Number ($items.Count + 1) -Taken $items.ToArray() -MustBeNew
    $item = New-WizardItem $pName (Read-GitName $items[$items.Count - 1].GitName) (Read-Email '')
    Read-Rules $item
    Write-Line ''
    Write-Line "New profile: $($item.Name): $($item.GitName) <$($item.GitEmail)>"
    if (@($item.Folders).Count -gt 0) { Write-Line "  folders: $(@($item.Folders) -join ' ')" }
    if (@($item.Owners).Count -gt 0) { Write-Line "  owners: $(@($item.Owners) -join ' ')" }
    if (-not (Read-YesNo 'Add this profile?' 'y')) {
        Write-Line 'Nothing changed.'
        return
    }
    if ([System.IO.File]::ReadAllText((Get-ConfigPath)) -cne $before) {
        Fail 'profiles.json changed while you were answering, so nothing was saved.' 'Run the command again.'
    }
    $items.Add($item)
    Write-ProfilesJson $items.ToArray()
    Invoke-Install -Quiet
    Write-Line ''
    Write-Line "Added `"$($item.Name)`": $(Get-ShortcutPath $item.Name)"
    Write-Line "Next: open `"GitHub Desktop - $($item.Name)`" and sign in to its account. Keep it the"
    Write-Line 'only GitHub Desktop window open while you sign in.'
    Show-AfterSetup $item.Name
}

# Remove one profile: its shortcut and guard rules go. Its data (login,
# repo list, settings) stays on your PC unless you ask for the Recycle Bin.
# The sign-in itself lives in Windows Credential Manager and is never touched here.
function Invoke-Remove([string]$ProfileName) {
    $profiles = Read-Config
    if ($profiles.Count -le 1) { Fail "`"$($profiles[0].Name)`" is your only profile." 'To remove everything, run: ghdp.ps1 uninstall' }
    $before = [System.IO.File]::ReadAllText((Get-ConfigPath))
    if (-not $ProfileName) {
        Write-Line "Your profiles: $(Get-ProfileNames $profiles)."
        $ProfileName = Read-Answer 'Name of the profile to remove'
    }
    $match = @($profiles | Where-Object { $_.Name -ceq $ProfileName })
    if ($match.Count -eq 0) { Fail "There is no profile called `"$ProfileName`"." "Your profiles: $(Get-ProfileNames $profiles)" }
    $name = $match[0].Name
    $pd = Get-ProfileDir $name
    Write-Line "This removes the shortcut `"GitHub Desktop - $name`" and its guard rules."
    Write-Line 'Its login, repo list and settings stay on your PC unless you choose the Recycle Bin.'
    Write-Line 'Tip: to sign this account out, do it inside that profile BEFORE removing it.'
    if (-not (Read-YesNo "Remove the profile `"$name`"?" 'n')) {
        Write-Line 'Nothing changed.'
        return
    }
    $trash = $false
    if ((Test-Path -LiteralPath $pd -PathType Container) -and (Read-YesNo 'Also move its data to the Recycle Bin?' 'n')) {
        $trash = $true
        while ($null -ne (Find-ProfileProcess $name)) {
            Write-Line "Please close the `"$name`" GitHub Desktop window first (File > Exit in it)."
            [void](Read-Answer 'Then press Enter to continue')
        }
    }
    $rest = New-Object System.Collections.Generic.List[object]
    foreach ($p in (Copy-ProfilesToWizard $profiles)) { if ($p.Name -cne $name) { $rest.Add($p) } }
    if ([System.IO.File]::ReadAllText((Get-ConfigPath)) -cne $before) {
        Fail 'profiles.json changed while you were answering, so nothing was saved.' 'Run the command again.'
    }
    Write-ProfilesJson $rest.ToArray()
    Invoke-Install -Quiet
    Write-Line ''
    if ($trash) {
        Move-ToRecycleBin $pd
        Write-Line "Moved its data to the Recycle Bin: $pd"
    } elseif (Test-Path -LiteralPath $pd) {
        Write-Line "Its data is still here (you can delete the folder yourself): $pd"
    }
    Write-Line "Removed `"$name`"."
}

# Let one profile commit and push to one repo whose owner it does not use
# (for example a repo you share with a teammate). Only that repo is allowed:
# the rest of that owner stays protected. Saved in profiles.json and in the
# profile's guard rules, so it works at once, without reopening anything.
function Invoke-Allow([string]$ProfileName, [string]$Repo) {
    if (-not $ProfileName -or -not $Repo) { Fail 'allow needs a profile name and a repo.' 'Example: ghdp.ps1 allow work some-owner/some-repo' }
    $profiles = Read-Config
    $p = Find-Profile $profiles $ProfileName
    $repoName = $Repo -replace '\Ahttps://github\.com/', ''
    $repoName = $repoName.TrimEnd('/').ToLowerInvariant()
    if ($repoName.EndsWith('.git')) { $repoName = $repoName.Substring(0, $repoName.Length - 4) }
    if (-not (Test-Repo $repoName)) {
        Fail "`"$Repo`" is not a GitHub repo in the form owner/name." 'Use the part after github.com/ in the repo link, for example some-owner/some-repo.'
    }
    if (@($p.Repos) -contains $repoName) {
        Write-Line "`"$ProfileName`" can already use $repoName. Nothing changed."
        return
    }
    if (@($p.Repos).Count -ge $script:MaxRules) {
        Fail "`"$ProfileName`" already has $($script:MaxRules) allowed repos, which is the limit." 'Remove one from "repos" in profiles.json first.'
    }
    $items = Copy-ProfilesToWizard $profiles
    foreach ($w in $items) { if ($w.Name -ceq $ProfileName) { $w.Repos = [string[]](@($w.Repos) + $repoName) } }
    Write-ProfilesJson $items.ToArray()
    Initialize-PrivateDir (Get-ProfilesRoot)
    Initialize-PrivateDir (Get-ProfileDir $ProfileName)
    $updated = (Read-Config) | Where-Object { $_.Name -ceq $ProfileName }
    Write-Guard $updated
    Write-Line "Done. `"$ProfileName`" can now commit and push to $repoName."
    Write-Line 'Other repos of that owner stay protected. The guard still checks the email.'
    Write-Line '(Your old profiles.json is kept as a backup: profiles.json.bak)'
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

function Invoke-Install([switch]$Quiet) {
    $profiles = Read-Config
    $exe = Get-VerifiedDesktop
    Initialize-PrivateDir (Get-BaseDir)
    Install-Self
    # Old shortcuts and guard rules go first, so a failure later on never
    # leaves a removed profile's rules behind.
    Remove-StaleShortcuts $profiles
    Remove-StaleGuards $profiles
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $p = $profiles[$i]
        Initialize-Profile $p $exe $i
        Add-ProfileShortcut $p.Name
        if (-not $Quiet) { Write-Line "Ready: $($p.Name) -> $(Get-ShortcutPath $p.Name)" }
    }
    Register-ProtocolHandler
    if (-not $Quiet) {
        Write-Line ''
        Write-Line "Done. Open the Start menu and search for `"GitHub Desktop - $($profiles[0].Name)`"."
        Write-Line 'Tip: sign in to each profile while it is the only GitHub Desktop window open.'
    }
}

function Invoke-Launch([string]$ProfileName, [switch]$DryRun, [switch]$Plain, [switch]$FromRunner) {
    if ([string]::IsNullOrEmpty($ProfileName)) { Fail 'Which profile should open?' 'Example: ghdp.ps1 launch office' }
    Assert-ProfileName $ProfileName
    if ($FromRunner -and -not $DryRun) { Assert-ToolFilesPrivate }
    $profiles = Read-Config
    $p = Find-Profile $profiles $ProfileName
    $index = Get-ProfileIndex $profiles $ProfileName
    Assert-NoElectronDoor
    $exe = Get-VerifiedDesktop
    $dd = Get-DataDir $ProfileName
    $hooks = (Get-HooksDir $ProfileName) -replace '\\', '/'

    # Fixed arguments only. The settings below reach only this GitHub Desktop
    # (not other programs). GIT_AUTHOR_* and GIT_COMMITTER_* beat every Git
    # config file, so commits always use this profile's identity. GIT_CONFIG_*
    # points Git at this profile's guard hooks (see above).
    $settings = [ordered]@{
        GIT_CONFIG_GLOBAL   = Get-GitConfigPath $ProfileName
        GIT_AUTHOR_NAME     = $p.GitName
        GIT_AUTHOR_EMAIL    = $p.GitEmail
        GIT_COMMITTER_NAME  = $p.GitName
        GIT_COMMITTER_EMAIL = $p.GitEmail
        GHDP_PROFILE        = $ProfileName
        GIT_CONFIG_COUNT    = '1'
        GIT_CONFIG_KEY_0    = 'core.hooksPath'
        GIT_CONFIG_VALUE_0  = $hooks
    }

    if ($DryRun) {
        Write-Line 'Dry run: all checks passed. Nothing was changed. This would run:'
        Write-Line "  $exe --user-data-dir=`"$dd`""
        foreach ($k in $settings.Keys) { Write-Line "  with $k=$($settings[$k])" }
        if (-not $Plain) { Write-Line '(The profile gets its own taskbar button, icon and title while it runs.)' }
        return
    }

    # Started from a terminal: hand over to the hidden start helper, exactly
    # like a click on the shortcut would, so no console window stays attached.
    if (-not $FromRunner -and -not $Plain) {
        Install-Self
        Start-ProfileWindow $ProfileName
        return
    }

    Initialize-Profile $p $exe $index -NoIcon:$Plain
    Remove-StaleGuards $profiles

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "--user-data-dir=`"$dd`""
    $psi.WorkingDirectory = Split-Path -Path $exe -Parent
    $psi.UseShellExecute = $false
    foreach ($k in $settings.Keys) { $psi.EnvironmentVariables[$k] = $settings[$k] }

    if ($Plain) {
        [void][System.Diagnostics.Process]::Start($psi)
        return
    }

    # Only one start helper watches a profile. A second click on the shortcut
    # just brings the window that is already open to the front.
    $created = $false
    $mutex = New-Object System.Threading.Mutex($false, "Local\ghdp-watch-$(Get-NormalName $ProfileName)")
    try { $created = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $created = $true }
    Import-Native
    $running = Find-ProfileProcess $ProfileName
    if (-not $created) {
        if ($null -ne $running) {
            $hwnd = [GhdpNative]::FindMainWindow([uint32]$running.ProcessId)
            if ($hwnd -ne [IntPtr]::Zero) { [GhdpNative]::BringToFront($hwnd) }
        }
        return
    }
    try {
        if ($null -ne $running) {
            $proc = [System.Diagnostics.Process]::GetProcessById($running.ProcessId)
        } else {
            $proc = [System.Diagnostics.Process]::Start($psi)
        }
        Watch-Profile $proc $p
    } finally {
        $mutex.ReleaseMutex()
    }
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
    if (Test-ProtocolHandlerOurs) {
        Write-Line 'Sign-in link: handled by this tool (replies reach the right profile)'
    } else {
        Write-Line 'Sign-in link: NOT handled by this tool yet (run: ghdp.ps1 install). Sign-in to a profile would fail.'
    }
    Write-Line ''
    foreach ($p in $profiles) {
        if (-not (Test-Path -LiteralPath (Get-ShortcutPath $p.Name))) {
            $status = 'no shortcut yet (run: ghdp.ps1 install)'
        } elseif (-not (Test-NativeCurrent)) {
            $status = 'helper programs missing (run: ghdp.ps1 install)'
        } else {
            $status = 'shortcut OK'
        }
        if ($null -ne (Find-ProfileProcess $p.Name)) { $status += ', running' }
        Write-Line "$($p.Name)  <$($p.GitEmail)>  $status"
        Write-Line "  data: $(Get-DataDir $p.Name)"
        if (@($p.Folders).Count -gt 0 -or @($p.Owners).Count -gt 0) {
            Write-Line "  guard: email, folders [$(@($p.Folders) -join ' ')], owners [$(@($p.Owners) -join ' ')]"
        } else {
            Write-Line '  guard: email only (no folders or owners set)'
        }
        if (@($p.Repos).Count -gt 0) { Write-Line "  allowed repos: $(@($p.Repos) -join ' ')" }
    }
}

# Remove the shortcuts, the sign-in link takeover and the installed tool.
# Profile data is moved to the Recycle Bin only if you say yes. Never touches
# your normal GitHub Desktop data, your code folders or any saved login.
function Invoke-Uninstall {
    $base = Get-BaseDir
    Write-Line 'GitHub Desktop Profiles uninstall'
    Write-Line 'Your normal GitHub Desktop, your code folders and your GitHub accounts are not touched.'
    if (-not (Read-YesNo 'Remove the profile shortcuts and this tool?' 'n')) {
        Write-Line 'Nothing changed.'
        return
    }
    while (@(Get-ProfileProcesses).Count -gt 0) {
        Write-Line 'Please close every GitHub Desktop profile window first (File > Exit in each).'
        [void](Read-Answer 'Then press Enter to continue')
    }
    Unregister-ProtocolHandler
    Write-Line 'Gave the sign-in link back to GitHub Desktop.'
    $dir = Get-ShortcutDir
    if ((Test-Path -LiteralPath $dir -PathType Container) -and -not (Test-ReparsePoint $dir)) {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -File) {
            if ($null -ne (Get-OurShortcutProfile $shell $file.FullName)) {
                Remove-Item -LiteralPath $file.FullName -Force
                Write-Line "Removed shortcut: $($file.Name)"
            }
        }
        if (@(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) { Remove-Item -LiteralPath $dir -Force }
    }
    $bin = Get-BinDir
    if ((Test-Path -LiteralPath $bin -PathType Container) -and -not (Test-ReparsePoint $bin)) {
        Remove-Item -LiteralPath $bin -Recurse -Force
        Write-Line 'Removed the installed copy of this tool.'
    }
    if ((Test-Path -LiteralPath $base -PathType Container) -and -not (Test-ReparsePoint $base)) {
        Write-Line ''
        Write-Line "Your profile data is still here: $base"
        Write-Line 'It holds profiles.json and, for each profile, its login list, repo list and settings.'
        if (Read-YesNo 'Move your profile data to the Recycle Bin too?' 'n') {
            Move-ToRecycleBin $base
            Write-Line "Moved to the Recycle Bin: $base"
        } else {
            Write-Line 'Kept your profile data. Run uninstall again later to remove it.'
        }
    }
    Write-Line ''
    Write-Line 'Saved logins (tokens) stay in Windows Credential Manager, because GitHub Desktop stores them by account.'
    Write-Line 'To remove one, sign out of that account inside GitHub Desktop, but only if no other window uses it.'
    $project = Split-Path -Path $PSScriptRoot -Parent
    if ((Test-Path -LiteralPath (Join-Path -Path $project -ChildPath 'install-windows.cmd')) -and
        (Test-Path -LiteralPath (Join-Path -Path $project -ChildPath 'uninstall-windows.cmd'))) {
        Write-Line ''
        Write-Line "You can now delete the folder you downloaded or cloned: $project"
    }
}

function Show-Help {
    Write-Line "gh-desktop-profiles $($script:Version) for Windows"
    Write-Line '  ghdp.ps1 setup                      guided setup (a menu if you already have profiles)'
    Write-Line '  ghdp.ps1 add                        add one more profile; the others stay as they are'
    Write-Line '  ghdp.ps1 remove [name]              remove a profile (its data is kept unless you say so)'
    Write-Line '  ghdp.ps1 init                       create your profiles.json from the example'
    Write-Line '  ghdp.ps1 install                    set up profile folders, icons and Start menu shortcuts'
    Write-Line '  ghdp.ps1 launch <name> [-DryRun]    open GitHub Desktop with a profile'
    Write-Line '  ghdp.ps1 launch <name> -Plain       open it without its own taskbar icon'
    Write-Line '  ghdp.ps1 list                       show your profiles and their status'
    Write-Line '  ghdp.ps1 allow <name> <owner/repo>  let a profile use one repo of another owner'
    Write-Line '  ghdp.ps1 uninstall                  remove shortcuts and the tool (profile data: you choose)'
}

function Invoke-Main([string]$Cmd, [string]$ProfileName, [string]$Other, [switch]$DryRun, [switch]$Plain, [switch]$Gui) {
    try {
        switch ($Cmd) {
            'setup' { Invoke-Setup }
            'add' { Invoke-Add }
            'remove' { Invoke-Remove $ProfileName }
            'init' { Invoke-Init }
            'install' { Invoke-Install }
            'launch' { Invoke-Launch -ProfileName $ProfileName -DryRun:$DryRun -Plain:$Plain -FromRunner:$Gui }
            'list' { Invoke-List }
            'allow' { Invoke-Allow $ProfileName $Other }
            'uninstall' { Invoke-Uninstall }
            'handle' { Invoke-Handle $ProfileName }
            'version' { Write-Line $script:Version }
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
    Invoke-Main -Cmd $Command -ProfileName $Name -Other $Extra -DryRun:$DryRun -Plain:$Plain -Gui:$Gui
}
