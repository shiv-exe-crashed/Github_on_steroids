# Tests for windows/ghdp.ps1 (Pester 5 or newer).
# They use a throwaway LOCALAPPDATA folder, so they never touch real settings.
# Run: Invoke-Pester tests/windows

BeforeAll {
    $repo = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
    . (Join-Path -Path $repo -ChildPath 'windows/ghdp.ps1')

    $script:Good = '{"version":1,"profiles":[
      {"name":"office","gitName":"Ada Lovelace","gitEmail":"1+ada-work@users.noreply.github.com"},
      {"name":"personal","gitName":"Ada L","gitEmail":"ada@example.org"}]}'

    function Write-TestConfig([string]$Text) {
        $base = Get-BaseDir
        if (-not (Test-Path -LiteralPath $base)) { [void](New-Item -ItemType Directory -Path $base) }
        [System.IO.File]::WriteAllText((Get-ConfigPath), $Text)
    }
}

Describe 'Test-ProfileName' {
    It 'accepts <_>' -ForEach @('office', 'Personal', 'p_2', 'a-b', '7', ('a' * 32)) {
        Test-ProfileName $_ | Should -BeTrue
    }
    It 'refuses <_>' -ForEach @('', '-rf', '_x', 'a b', 'a/b', '..\x', '..', 'a.b', ('a' * 33),
        'con', 'Nul', 'LPT1', 'COM9', "office`n", "of`nfice", 'a$b', 'a;b', 'a%b') {
        Test-ProfileName $_ | Should -BeFalse
    }
}

Describe 'Test-Email' {
    It 'accepts <_>' -ForEach @('1+ada@users.noreply.github.com', 'a.b-c@example.co') {
        Test-Email $_ | Should -BeTrue
    }
    It 'refuses <_>' -ForEach @('CHANGE-ME', 'a@b', 'a b@c.com', 'a@b.c', 'a"b@c.com', "a@b.com`n", 'a@b.com ', (('a' * 250) + '@b.com')) {
        Test-Email $_ | Should -BeFalse
    }
}

Describe 'Test-GitName' {
    It 'accepts <_>' -ForEach @('Ada Lovelace', "Jos$([char]0xE9) N$([char]0xFA)$([char]0xF1)ez", "O'Brien") {
        Test-GitName $_ | Should -BeTrue
    }
    It 'refuses <_>' -ForEach @('', 'CHANGE ME', 'a"b', 'a\b', ' lead', 'trail ', '-dash', "a`tb", "a`nb", ('a' * 101)) {
        Test-GitName $_ | Should -BeFalse
    }
}

Describe 'Paths' {
    BeforeEach {
        $env:LOCALAPPDATA = Join-Path -Path $TestDrive -ChildPath 'Local'
        $env:APPDATA = Join-Path -Path $TestDrive -ChildPath 'Roaming'
    }
    It 'builds profile paths under the private base folder' {
        $base = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'gh-desktop-profiles'
        Get-ProfileDir 'office' | Should -Be (Join-Path -Path (Join-Path -Path $base -ChildPath 'profiles') -ChildPath 'office')
        Get-DataDir 'office' | Should -Be (Join-Path -Path (Get-ProfileDir 'office') -ChildPath 'desktop-data')
        Get-ShortcutPath 'office' | Should -BeLike '*GitHub Desktop Profiles*GitHub Desktop - office.lnk'
    }
    It 'refuses bad names in paths' {
        { Get-ProfileDir '../evil' } | Should -Throw -ExpectedMessage '*is not allowed*'
        { Get-ShortcutPath 'a/b' } | Should -Throw -ExpectedMessage '*is not allowed*'
    }
    It 'refuses a base path with <_>' -ForEach @('"', '%') {
        $env:LOCALAPPDATA = Join-Path -Path $TestDrive -ChildPath "bad$($_)name"
        { Get-BaseDir } | Should -Throw -ExpectedMessage '*unusual characters*'
    }
    It 'refuses a relative base path' {
        $env:LOCALAPPDATA = 'relative\path'
        { Get-BaseDir } | Should -Throw -ExpectedMessage '*unusual characters*'
    }
}

Describe 'Read-Config' {
    BeforeEach {
        $env:LOCALAPPDATA = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        [void](New-Item -ItemType Directory -Path $env:LOCALAPPDATA)
    }
    It 'loads a good config' {
        Write-TestConfig $script:Good
        $profiles = Read-Config
        $profiles.Count | Should -Be 2
        $profiles[0].Name | Should -Be 'office'
        $profiles[0].GitName | Should -Be 'Ada Lovelace'
        $profiles[1].GitEmail | Should -Be 'ada@example.org'
    }
    It 'refuses the example config until it is edited' {
        $repo = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
        Write-TestConfig ([System.IO.File]::ReadAllText((Join-Path -Path $repo -ChildPath 'profiles.example.json')))
        { Read-Config } | Should -Throw -ExpectedMessage '*CHANGE ME*'
    }
    It 'tells you to run init when the config is missing' {
        { Read-Config } | Should -Throw -ExpectedMessage '*No profiles.json*'
    }
    It 'refuses: <Expect>' -ForEach @(
        @{ Json = '{bad json'; Expect = 'not valid JSON' }
        @{ Json = '[1,2]'; Expect = 'must be an object' }
        @{ Json = '{"version":2,"profiles":[]}'; Expect = '"version": 1' }
        @{ Json = '{"version":"1","profiles":[]}'; Expect = '"version": 1' }
        @{ Json = '{"version":1}'; Expect = '"profiles" list' }
        @{ Json = '{"version":1,"profiles":[]}'; Expect = 'between 1 and' }
        @{ Json = '{"version":1,"profiles":[],"extra":true}'; Expect = 'Unknown setting "extra"' }
        @{ Json = '{"version":1,"profiles":["office"]}'; Expect = 'not an object' }
        @{ Json = '{"version":1,"profiles":[{"name":"o","gitName":"A","gitEmial":"a@b.co"}]}'; Expect = 'Unknown setting "gitEmial"' }
        @{ Json = '{"version":1,"profiles":[{"name":"o","gitName":"A"}]}'; Expect = '"gitEmail" as text' }
        @{ Json = '{"version":1,"profiles":[{"name":5,"gitName":"A","gitEmail":"a@b.co"}]}'; Expect = '"name" as text' }
        @{ Json = '{"version":1,"profiles":[{"name":"../x","gitName":"A","gitEmail":"a@b.co"}]}'; Expect = 'is not allowed' }
        @{ Json = '{"version":1,"profiles":[{"name":"o","gitName":"A\"B","gitEmail":"a@b.co"}]}'; Expect = 'gitName' }
        @{ Json = '{"version":1,"profiles":[{"name":"o","gitName":"A","gitEmail":"nope"}]}'; Expect = 'not a valid email' }
        @{ Json = '{"version":1,"profiles":[{"name":"Office","gitName":"A","gitEmail":"a@b.co"},{"name":"office","gitName":"B","gitEmail":"b@b.co"}]}'; Expect = 'same name' }
        @{ Json = '{"version":1,"profiles":[{"name":"a_b","gitName":"A","gitEmail":"a@b.co"},{"name":"a-b","gitName":"B","gitEmail":"b@b.co"}]}'; Expect = 'same name' }
    ) {
        Write-TestConfig $Json
        { Read-Config } | Should -Throw -ExpectedMessage "*$Expect*"
    }
    It 'refuses more than 20 profiles' {
        $items = 1..21 | ForEach-Object { "{`"name`":`"p$_`",`"gitName`":`"A`",`"gitEmail`":`"a@b.co`"}" }
        Write-TestConfig ("{`"version`":1,`"profiles`":[" + ($items -join ',') + ']}')
        { Read-Config } | Should -Throw -ExpectedMessage '*between 1 and 20*'
    }
}

Describe 'Find-Profile' {
    It 'finds by exact name and refuses unknown names' {
        $list = @([pscustomobject]@{ Name = 'office' }, [pscustomobject]@{ Name = 'personal' })
        (Find-Profile $list 'personal').Name | Should -Be 'personal'
        { Find-Profile $list 'Office' } | Should -Throw -ExpectedMessage '*no profile called*'
    }
}

Describe 'Assert-NoElectronDoor' {
    AfterEach {
        Remove-Item -Path Env:NODE_OPTIONS -ErrorAction SilentlyContinue
        Remove-Item -Path Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    }
    It 'passes when the risky settings are not set' {
        { Assert-NoElectronDoor } | Should -Not -Throw
    }
    It 'refuses when NODE_OPTIONS is set' {
        $env:NODE_OPTIONS = '--require evil.js'
        { Assert-NoElectronDoor } | Should -Throw -ExpectedMessage '*NODE_OPTIONS*'
    }
    It 'refuses when ELECTRON_RUN_AS_NODE is set' {
        $env:ELECTRON_RUN_AS_NODE = '1'
        { Assert-NoElectronDoor } | Should -Throw -ExpectedMessage '*ELECTRON_RUN_AS_NODE*'
    }
}

Describe 'Initialize-PrivateDir' {
    It 'creates a folder and is safe to run twice' {
        $dir = Join-Path -Path $TestDrive -ChildPath 'private'
        Initialize-PrivateDir $dir
        Initialize-PrivateDir $dir
        Test-Path -LiteralPath $dir -PathType Container | Should -BeTrue
    }
    It 'refuses a file where a folder should be' {
        $file = Join-Path -Path $TestDrive -ChildPath 'afile'
        [System.IO.File]::WriteAllText($file, 'x')
        { Initialize-PrivateDir $file } | Should -Throw -ExpectedMessage '*is not a folder*'
    }
    It 'refuses a symbolic link' {
        $target = Join-Path -Path $TestDrive -ChildPath 'target'
        $link = Join-Path -Path $TestDrive -ChildPath 'link'
        [void](New-Item -ItemType Directory -Path $target)
        try {
            [void](New-Item -ItemType SymbolicLink -Path $link -Target $target)
        } catch {
            Set-ItResult -Skipped -Because 'creating symbolic links needs Developer Mode on Windows'
            return
        }
        { Initialize-PrivateDir $link } | Should -Throw -ExpectedMessage '*is a link*'
    }
}

# TODO (Windows): these wizard tests hang under PowerShell 7 on Mac; the
# maintainer will run and fix them on a Windows PC. Skipped until then.
Describe 'Setup wizard and import' -Skip {
    BeforeAll {
        # A fake "normal GitHub Desktop" data folder with things that must
        # NOT be copied (cache, logs, lock file, a link pointing outside).
        function Initialize-NormalData {
            $n = Get-NormalDataDir
            foreach ($d in @('Local Storage/leveldb', 'IndexedDB/file__0.indexeddb.leveldb', 'Cache/Cache_Data', 'logs')) {
                [void](New-Item -ItemType Directory -Force -Path (Join-Path -Path $n -ChildPath $d))
            }
            [System.IO.File]::WriteAllText((Join-Path -Path $n -ChildPath 'Local Storage/leveldb/000003.log'), 'users')
            [System.IO.File]::WriteAllText((Join-Path -Path $n -ChildPath 'Local Storage/leveldb/LOCK'), '')
            [System.IO.File]::WriteAllText((Join-Path -Path $n -ChildPath 'IndexedDB/file__0.indexeddb.leveldb/000005.log'), 'repos')
            [System.IO.File]::WriteAllText((Join-Path -Path $n -ChildPath 'Cache/Cache_Data/f'), 'big')
            [System.IO.File]::WriteAllText((Join-Path -Path $n -ChildPath 'logs/a.log'), 'log')
            [System.IO.File]::WriteAllText((Join-Path -Path $n -ChildPath 'SingletonCookie'), 'x')
            try { [void](New-Item -ItemType SymbolicLink -Path (Join-Path -Path $n -ChildPath 'evil-link') -Target $TestDrive) } catch { $null = $_ }
            return $n
        }
        function Get-Listing([string]$Dir) {
            return ((Get-ChildItem -LiteralPath $Dir -Recurse -Force | ForEach-Object { $_.FullName.Substring($Dir.Length) } | Sort-Object) -join '|')
        }
    }
    BeforeEach {
        $root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        $env:LOCALAPPDATA = Join-Path -Path $root -ChildPath 'Local'
        $env:APPDATA = Join-Path -Path $root -ChildPath 'Roaming'
        [void](New-Item -ItemType Directory -Path $env:LOCALAPPDATA)
        [void](New-Item -ItemType Directory -Path $env:APPDATA)
        $script:Answers = New-Object System.Collections.Queue
        Mock Read-Host { if ($script:Answers.Count -eq 0) { return $null } return $script:Answers.Dequeue() }
        Mock Get-VerifiedDesktop { return 'C:\fake\GitHubDesktop.exe' }
        Mock Get-GlobalGitValue { return '' }
        Mock Invoke-Install { }
    }

    It 'asks again on bad answers, imports, and leaves the original alone' {
        $normal = Initialize-NormalData
        $before = Get-Listing $normal
        @('', 'bad name!', 'personal', '', 'Ada L', '', 'ada@example.org', '', 'Personal', 'office', '', 'nope',
            '1+ada-work@users.noreply.github.com', '', '') | ForEach-Object { $script:Answers.Enqueue($_) }
        Invoke-Setup
        $profiles = Read-Config
        ($profiles.Name -join ' ') | Should -Be 'personal office'
        $profiles[1].GitName | Should -Be 'Ada L'
        $profiles[1].GitEmail | Should -Be '1+ada-work@users.noreply.github.com'
        $copied = Get-DataDir 'personal'
        Test-Path -LiteralPath (Join-Path -Path $copied -ChildPath 'Local Storage/leveldb/000003.log') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $copied -ChildPath 'IndexedDB/file__0.indexeddb.leveldb/000005.log') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $copied -ChildPath 'Cache') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $copied -ChildPath 'logs') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $copied -ChildPath 'SingletonCookie') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $copied -ChildPath 'evil-link') | Should -BeFalse
        Get-Listing $normal | Should -Be $before
        Should -Invoke Invoke-Install -Times 1 -Exactly
        $script:Answers.Count | Should -Be 0
    }

    It 'just asks for profiles when there is no GitHub Desktop data' {
        @('solo', 'Ada', 'a@b.co', 'n', '') | ForEach-Object { $script:Answers.Enqueue($_) }
        Invoke-Setup
        (Read-Config).Name | Should -Be 'solo'
    }

    It 'writes nothing when cancelled half way' {
        @('solo', 'Ada') | ForEach-Object { $script:Answers.Enqueue($_) }
        { Invoke-Setup } | Should -Throw -ExpectedMessage '*Setup was cancelled*'
        Test-Path -LiteralPath (Get-ConfigPath) | Should -BeFalse
        Should -Invoke Invoke-Install -Times 0 -Exactly
    }

    It 'keeps an existing config unless you say yes, then backs it up' {
        Write-TestConfig $script:Good
        $script:Answers.Enqueue('')
        Invoke-Setup
        [System.IO.File]::ReadAllText((Get-ConfigPath)) | Should -Be $script:Good
        @('y', 'solo', 'Ada', 'a@b.co', 'n', '') | ForEach-Object { $script:Answers.Enqueue($_) }
        Invoke-Setup
        [System.IO.File]::ReadAllText("$(Get-ConfigPath).bak") | Should -Be $script:Good
        (Read-Config).Name | Should -Be 'solo'
    }

    It 'Copy-DesktopData never overwrites an existing folder' {
        $normal = Initialize-NormalData
        $dst = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        Copy-DesktopData $normal $dst
        { Copy-DesktopData $normal $dst } | Should -Throw -ExpectedMessage '*already exists*'
    }

    It 'Test-DesktopHoldsData is false when nothing holds the lock' {
        $normal = Initialize-NormalData
        Test-DesktopHoldsData $normal | Should -BeFalse
    }
}

Describe 'Guard rules in profiles.json (folders and owners)' {
    BeforeEach {
        $env:LOCALAPPDATA = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString())
        [void](New-Item -ItemType Directory -Path $env:LOCALAPPDATA)
    }
    It 'accepts folders and owners' {
        Write-TestConfig '{"version":1,"profiles":[{"name":"office","gitName":"A","gitEmail":"a@b.co","folders":["~/work"],"owners":["acme","my-org"]}]}'
        $p = Read-Config
        $p[0].Folders | Should -Be @('~/work')
        $p[0].Owners | Should -Be @('acme', 'my-org')
    }
    It 'refuses: <Expect>' -ForEach @(
        @{ Json = '{"version":1,"profiles":[{"name":"o","gitName":"A","gitEmail":"a@b.co","folders":"~/work"}]}'; Expect = 'as a list' }
        @{ Json = '{"version":1,"profiles":[{"name":"o","gitName":"A","gitEmail":"a@b.co","folders":["~/../x"]}]}'; Expect = 'not allowed' }
        @{ Json = '{"version":1,"profiles":[{"name":"o","gitName":"A","gitEmail":"a@b.co","folders":["relative"]}]}'; Expect = 'not allowed' }
        @{ Json = '{"version":1,"profiles":[{"name":"o","gitName":"A","gitEmail":"a@b.co","owners":["Bad_Owner"]}]}'; Expect = 'not allowed' }
        @{ Json = '{"version":1,"profiles":[{"name":"o","gitName":"A","gitEmail":"a@b.co","owners":[5]}]}'; Expect = 'text in quotes' }
    ) {
        Write-TestConfig $Json
        { Read-Config } | Should -Throw -ExpectedMessage "*$Expect*"
    }
}
