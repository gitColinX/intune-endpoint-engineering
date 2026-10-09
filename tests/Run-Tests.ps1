<#
.SYNOPSIS
    Test suite for this repo. No Pester dependency, runs in Windows PowerShell 5.1 and PowerShell 7.

.DESCRIPTION
    1. Parses every .ps1 / .psm1 with the PowerShell language parser.
    2. Hygiene: ASCII only (which also rules out en and em dashes), no GUIDs
       outside the synthetic allow-list, no e-mail addresses outside example.com,
       no URLs outside an allow-list of hosts.
    3. Checks that every inline copy of a shared block (OutputBudget, PackedGuid,
       Ensure64Bit, PrivateFolder) matches remediations\lib.
    4. Unit tests for the pure functions in each script, on synthetic input.
    5. MSI module end to end on a synthetic MSI built from scratch in a temp folder.
    6. Smoke runs of the read-only scripts and the dry-run paths on this machine,
       as child processes. Nothing here installs, deletes or calls a tenant.
       Skip with -SkipSmoke.

    Exit code: number of failed checks (0 = all passed).

.EXAMPLE
    pwsh -NoProfile -File .\tests\Run-Tests.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipSmoke,
    [switch]$SkipMsi
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:Pass++ }
    else { $script:Fail++; $script:Failures.Add($Name); Write-Host "  FAIL: $Name" -ForegroundColor Red }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    $ok = ($Expected -eq $Actual) -or ($null -eq $Expected -and $null -eq $Actual)
    Assert-True $ok ("{0} (expected '{1}', got '{2}')" -f $Name, $Expected, $Actual)
}

function Write-Section { param([string]$Text) Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }

# Filter by extension in code: -Include with -LiteralPath is unreliable in Windows PowerShell 5.1.
$psFiles = @(Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') -and $_.FullName -notmatch '\\\.git\\' })
$textFiles = @(Get-ChildItem -LiteralPath $repo -Recurse -File | Where-Object {
        $_.FullName -notmatch '\\(\.git|__pycache__)\\' -and $_.Extension -notin @('.pyc', '.msi', '.mst', '.zip', '.intunewin')
    })

# ---------------------------------------------------------------- 1. parse
Write-Section "Parse ($($psFiles.Count) PowerShell files, PowerShell $($PSVersionTable.PSVersion))"
foreach ($f in $psFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    $rel = $f.FullName.Substring($repo.Length + 1)
    if ($errors -and $errors.Count) {
        foreach ($e in $errors) { Write-Host ("  {0}:{1} {2}" -f $rel, $e.Extent.StartLineNumber, $e.Message) }
    }
    Assert-True (-not ($errors -and $errors.Count)) "parse $rel"
}

# ---------------------------------------------------------------- 2. hygiene
Write-Section "Hygiene ($($textFiles.Count) text files)"
$guidAllow = '^(00000000-0000-0000-0000-[0-9a-f]{12}|11111111-2222-3333-4444-555555555555|66666666-7777-8888-9999-aaaaaaaaaaaa|abcdef01-2345-6789-abcd-ef0123456789|12345678-abcd-ef01-2345-6789abcdef01)$'
$hostAllow = '^(([a-z0-9-]+\.)*example\.(com|org|net)|github\.com|www\.linkedin\.com|learn\.microsoft\.com|www\.w3\.org)$'
foreach ($f in $textFiles) {
    $rel = $f.FullName.Substring($repo.Length + 1)
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
    Assert-True ($nonAscii -eq 0) "ascii-only $rel ($nonAscii non-ASCII bytes)"
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    foreach ($m in [regex]::Matches($text, '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}')) {
        Assert-True ($m.Value.ToLowerInvariant() -match $guidAllow) "guid allow-list $rel : $($m.Value)"
    }
    foreach ($m in [regex]::Matches($text, '[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})')) {
        Assert-True ($m.Groups[1].Value -match '^example\.(com|org|net)$') "email domain $rel : $($m.Groups[1].Value)"
    }
    foreach ($m in [regex]::Matches($text, 'https?://([A-Za-z0-9.-]+)')) {
        Assert-True ($m.Groups[1].Value.ToLowerInvariant() -match $hostAllow) "url host $rel : $($m.Groups[1].Value)"
    }
}

# ---------------------------------------------------------------- 3. shared block sync
Write-Section 'Shared blocks in sync with remediations\lib'
function Get-RegionBody {
    param([string]$Text, [string]$Name)
    $m = [regex]::Match($Text, '(?s)# region ' + $Name + '\r?\n(.*?)# endregion ' + $Name)
    if (-not $m.Success) { return $null }
    return ((($m.Groups[1].Value -split '\r?\n') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`n")
}
foreach ($region in 'OutputBudget', 'PackedGuid', 'Ensure64Bit', 'PrivateFolder') {
    $libText = [System.IO.File]::ReadAllText((Join-Path $repo "remediations\lib\$region.ps1"))
    $libBody = Get-RegionBody -Text $libText -Name $region
    Assert-True ($null -ne $libBody) "lib region $region present"
    foreach ($f in $psFiles) {
        if ($f.DirectoryName -eq (Join-Path $repo 'remediations\lib')) { continue }
        $body = Get-RegionBody -Text ([System.IO.File]::ReadAllText($f.FullName)) -Name $region
        if ($null -ne $body) { Assert-Equal $libBody $body "region $region in $($f.Name) matches lib" }
    }
}

# ---------------------------------------------------------------- 4. unit tests
Write-Section 'Unit: OutputBudget and PackedGuid'
& {
    . (Join-Path $repo 'remediations\lib\OutputBudget.ps1')
    . (Join-Path $repo 'remediations\lib\PackedGuid.ps1')
    Assert-Equal 'a || b' (Format-RemediationOutput -Part @('a', '', $null, 'b')) 'drops empty parts'
    Assert-Equal '' (Format-RemediationOutput -Part @()) 'empty input gives empty string'
    Assert-Equal 'x y z' (Format-RemediationOutput -Part @("x`r`n  y`tz")) 'collapses whitespace and control characters'
    $big = Format-RemediationOutput -Part @('short', ('x' * 5000), ('y' * 300))
    Assert-True ($big.Length -le 2048) "long input fits 2048 (got $($big.Length))"
    Assert-True ($big.StartsWith('short || ')) 'short part kept whole'
    Assert-True ($big.EndsWith('y' * 300)) 'medium part kept whole when budget allows'
    $many = Format-RemediationOutput -Part (1..500 | ForEach-Object { "item $_ " + ('z' * 30) })
    Assert-True ($many.Length -le 2048) "many parts fit 2048 (got $($many.Length))"
    Assert-True ($many -match '\[\+\d+ more\]$') 'many parts end with a +N more marker'
    $small = Format-RemediationOutput -Part @(('a' * 100), ('b' * 100)) -Budget 120
    Assert-True ($small.Length -le 120) 'custom budget respected'

    # Hand-computed vector: groups 1 to 3 reversed, groups 4 and 5 pair-swapped.
    Assert-Equal '10FEDCBA54329876BADCFE1032547698' (ConvertTo-PackedGuid -Guid '{ABCDEF01-2345-6789-ABCD-EF0123456789}') 'packed GUID hand-computed vector'
    Assert-Equal '87654321DCBA10FE32547698BADCFE10' (ConvertTo-PackedGuid -Guid '12345678-abcd-ef01-2345-6789abcdef01') 'packed GUID lower case without braces'
    Assert-Equal '{12345678-ABCD-EF01-2345-6789ABCDEF01}' (ConvertFrom-PackedGuid -PackedGuid '87654321DCBA10FE32547698BADCFE10') 'unpack GUID'
    $roundTripOk = $true
    for ($i = 0; $i -lt 50; $i++) {
        $g = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
        if ((ConvertFrom-PackedGuid -PackedGuid (ConvertTo-PackedGuid -Guid $g)) -ne $g) { $roundTripOk = $false }
    }
    Assert-True $roundTripOk 'packed GUID round trip x50'
    $threw = $false
    try { ConvertTo-PackedGuid -Guid 'not-a-guid' | Out-Null } catch { $threw = $true }
    Assert-True $threw 'packed GUID rejects garbage'
}

Write-Section 'Unit: private work folder'
& {
    . (Join-Path $repo 'remediations\lib\PrivateFolder.ps1')
    $sys = [pscustomobject]@{ Sid = 'S-1-5-18'; Type = 'Allow' }
    $adm = [pscustomobject]@{ Sid = 'S-1-5-32-544'; Type = 'Allow' }
    $usersAllow = [pscustomobject]@{ Sid = 'S-1-5-32-545'; Type = 'Allow' }
    $usersDeny = [pscustomobject]@{ Sid = 'S-1-5-32-545'; Type = 'Deny' }
    Assert-Equal '' (Test-TrustedFolderState -OwnerSid 'S-1-5-32-544' -Rule @($sys, $adm) -Protected $true -IsReparsePoint $false) 'trusted: Administrators owner, SYSTEM and Administrators only'
    Assert-Equal '' (Test-TrustedFolderState -OwnerSid 'S-1-5-18' -Rule @($sys, $adm, $usersDeny) -Protected $true -IsReparsePoint $false) 'trusted: a Deny entry for Users is fine'
    Assert-True ((Test-TrustedFolderState -OwnerSid 'S-1-5-21-1-2-3-1001' -Rule @($sys, $adm) -Protected $true -IsReparsePoint $false) -match 'owner') 'refused: owned by a user'
    Assert-True ((Test-TrustedFolderState -OwnerSid 'S-1-5-32-544' -Rule @($sys, $adm, $usersAllow) -Protected $true -IsReparsePoint $false) -match 'S-1-5-32-545') 'refused: ACL allows Users'
    Assert-True ((Test-TrustedFolderState -OwnerSid 'S-1-5-32-544' -Rule @($sys, $adm) -Protected $false -IsReparsePoint $false) -match 'inherits') 'refused: still inherits'
    Assert-True ((Test-TrustedFolderState -OwnerSid 'S-1-5-32-544' -Rule @($sys, $adm) -Protected $true -IsReparsePoint $true) -match 'reparse') 'refused: junction'

    # Refusal paths on real temporary folders. Nothing here changes an ACL unless the
    # suite runs elevated, and then only on the test's own temporary folder.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('iee-pf-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $target = Join-Path $tmp 'target'
        New-Item -ItemType Directory -Path $target | Out-Null
        $junction = Join-Path $tmp 'junction'
        New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
        $threw = ''
        try { New-PrivateFolder -Path $junction } catch { $threw = $_.Exception.Message }
        Assert-True ($threw -match 'junction') "refuses a work folder that is a junction ($threw)"
        $threw = ''
        try { New-PrivateFolder -Path (Join-Path $junction 'inner') } catch { $threw = $_.Exception.Message }
        Assert-True ($threw -match 'parent') "refuses a work folder below a junction ($threw)"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'inner'))) 'nothing created through the junction'

        $preExisting = Join-Path $tmp 'pre-existing'
        New-Item -ItemType Directory -Path $preExisting | Out-Null
        $owner = (Get-FolderState -Path $preExisting).OwnerSid
        if (@('S-1-5-18', 'S-1-5-32-544') -notcontains $owner) {
            $threw = ''
            try { New-PrivateFolder -Path $preExisting } catch { $threw = $_.Exception.Message }
            Assert-True ($threw -match 'already exists and is owned by') "refuses a pre-existing folder a user created ($threw)"
        }
        else {
            Write-Host '  (elevated run: the user-owned refusal test does not apply)'
        }
    }
    finally {
        if (Test-Path -LiteralPath (Join-Path $tmp 'junction')) { [System.IO.Directory]::Delete((Join-Path $tmp 'junction')) }
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Section 'Unit: agent self-heal decisions'
& {
    . (Join-Path $repo 'remediations\agent-self-heal\Remediate-AgentSelfHeal.ps1')
    $run = [pscustomobject]@{ Name = 'A'; Status = 'Running' }
    $stop = [pscustomobject]@{ Name = 'B'; Status = 'Stopped' }
    Assert-True (Test-AgentHealthy -Service @($run, $run) -MinimumServiceCount 2) 'healthy when all running and enough services'
    Assert-True (-not (Test-AgentHealthy -Service @($run, $stop) -MinimumServiceCount 2)) 'unhealthy when one stopped'
    Assert-True (-not (Test-AgentHealthy -Service @($run) -MinimumServiceCount 2)) 'unhealthy when too few services'
    Assert-True (-not (Test-AgentHealthy -Service @() -MinimumServiceCount 1)) 'unhealthy when none'
    Assert-True (Test-NameInScope -Name 'Contoso RMM Agent' -IncludePattern '^Contoso (RMM Agent|Agent Platform)\b' -ExcludePattern 'Remote Support') 'in scope'
    Assert-True (-not (Test-NameInScope -Name 'Contoso Agent Platform Remote Support' -IncludePattern '^Contoso (RMM Agent|Agent Platform)\b' -ExcludePattern 'Remote Support')) 'exclusion wins'
    Assert-True (-not (Test-NameInScope -Name 'Fabrikam Contoso RMM Agent' -IncludePattern '^Contoso (RMM Agent|Agent Platform)\b' -ExcludePattern '')) 'anchored include'
    Assert-True (Test-SafeRemovalPath -Path 'C:\Program Files (x86)\Contoso\Agent') 'safe path two levels under Program Files (x86)'
    Assert-True (Test-SafeRemovalPath -Path 'C:\ProgramData\Contoso\Agent\') 'safe path with trailing slash'
    Assert-True (-not (Test-SafeRemovalPath -Path 'C:\Program Files\Contoso')) 'refuse one level deep'
    Assert-True (-not (Test-SafeRemovalPath -Path 'C:\')) 'refuse drive root'
    Assert-True (-not (Test-SafeRemovalPath -Path 'C:\Windows\System32\drivers')) 'refuse Windows'
    Assert-True (-not (Test-SafeRemovalPath -Path 'C:\Program Files\Contoso\..\..\Windows')) 'refuse traversal'
    Assert-True (-not (Test-SafeRemovalPath -Path 'Contoso\Agent')) 'refuse relative path'

    # Stage logic with the device-facing functions replaced by fakes (dry run only).
    $script:FakeServices = @()
    $script:FakeStale = @()
    function Get-AgentService { param([hashtable]$Settings) return $script:FakeServices }
    function Get-StaleRegistration { param([hashtable]$Settings) return $script:FakeStale }
    function New-FakeService { param($Name, $Status, $StartType = 'Automatic') [pscustomobject]@{ Name = $Name; Status = $Status; StartType = $StartType } }

    $script:FakeServices = @((New-FakeService 'ContosoAgentA' 'Running'), (New-FakeService 'ContosoAgentB' 'Running'))
    $script:Report.Clear()
    $code = @(Invoke-SelfHeal -DoApply $false)[-1]
    Assert-Equal 0 $code 'stage 0: healthy exits 0'
    Assert-True (($script:Report -join ' ') -match 'NOTHING TOUCHED') 'stage 0: reports NOTHING TOUCHED'

    $script:FakeServices = @((New-FakeService 'ContosoAgentA' 'Running'), (New-FakeService 'ContosoAgentB' 'Stopped' 'Disabled'))
    $script:Report.Clear()
    $code = @(Invoke-SelfHeal -DoApply $false)[-1]
    Assert-Equal 1 $code 'stage 1: a Disabled service is not overridden'
    Assert-True (($script:Report -join ' ') -match 'DISABLED: ContosoAgentB') 'stage 1: names the disabled service'

    $script:FakeServices = @((New-FakeService 'ContosoAgentA' 'Running'), (New-FakeService 'ContosoAgentB' 'Stopped'))
    $script:FakeStale = @([pscustomobject]@{ Kind = 'ARP'; Path = 'x'; RegName = 'x'; Label = 'Contoso RMM Agent v1.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' })
    $script:Report.Clear()
    $code = @(Invoke-SelfHeal -DoApply $false)[-1]
    $text = $script:Report -join ' || '
    Assert-Equal 0 $code 'dry run exits 0'
    Assert-True ($text -match 'WOULD start: ContosoAgentB') 'stage 1 dry run: would start the stopped service'
    Assert-True ($text -match 'WOULD msiexec /x \{11111111-2222-3333-4444-555555555555\}') 'stage 2 dry run: would uninstall by product code'
    Assert-True ($text -match 'WOULD purge ARP') 'stage 2 dry run: would purge after backup'
    Assert-True ($text -notmatch 'PURGED|SVCDEL|DELDIR|UNINSTALL ') 'dry run reports no performed actions'

    # The tokenized installer file name never reaches the report, even in a dry run.
    $Config.InstallerFileName = 'Agent_SITETOKEN0123456789_x64.msi'
    $Config.InstallerUrl = 'https://downloads.example.com/agent/Agent_SITETOKEN0123456789_x64.msi'
    $script:Report.Clear()
    [void](@(Invoke-SelfHeal -DoApply $false))
    $text = $script:Report -join ' || '
    Assert-True ($text -match 'WOULD download') 'dry run still describes the download'
    Assert-True ($text -notmatch 'SITETOKEN') 'dry run output never contains the installer file name or URL'
    $script:Report.Clear()
    Add-Report 'ERROR: Cannot find path C:\Work\Agent_SITETOKEN0123456789_x64.msi because it does not exist.'
    Assert-True (($script:Report -join '') -notmatch 'SITETOKEN' -and ($script:Report -join '') -match '<vendor-installer>') 'exception text quoting the installer path is redacted'

    $lit = @(Get-RedactionList -Settings $Config)
    Assert-Equal $Config.InstallerUrl $lit[0] 'redaction list puts the URL first'
    Assert-True ($lit -contains 'Agent_SITETOKEN0123456789_x64') 'redaction list includes the base name'
    Assert-Equal 'x <vendor-installer> y' (Protect-InstallerName -Text 'x agent_sitetoken0123456789_x64.MSI y' -Literal $lit) 'redaction is case-insensitive'
    Assert-Equal 'TOKEN=<vendor-installer>' (Protect-InstallerName -Text 'TOKEN=abc123def' -Pattern @('(?<=TOKEN=)\w+')) 'redaction applies extra patterns'

    # UpgradeCodes and Features cleanup picks only what belongs to the products in scope.
    $targets = @(Select-InstallerRegistrationTarget -PackedCode @('87654321DCBA10FE32547698BADCFE10') -FeatureKey @('87654321DCBA10FE32547698BADCFE10') -UpgradeCodeValue @{
            '66666666777788889999AAAAAAAAAAAA' = @('87654321DCBA10FE32547698BADCFE10', '10FEDCBA54329876BADCFE1032547698')
            'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF' = @('10FEDCBA54329876BADCFE1032547698')
        })
    Assert-Equal 2 $targets.Count 'registration targets: one Features key and one UpgradeCodes value'
    Assert-Equal 1 @($targets | Where-Object { $_.Kind -eq 'InstallerFeatures' }).Count 'Features key selected by packed code'
    $up = @($targets | Where-Object { $_.Kind -eq 'UpgradeCodeValue' })
    Assert-True ($up.Count -eq 1 -and $up[0].ValueName -eq '87654321DCBA10FE32547698BADCFE10' -and $up[0].Key -eq '66666666777788889999AAAAAAAAAAAA') 'only the in-scope product value under the upgrade code'
    Assert-Equal 0 @(Select-InstallerRegistrationTarget -PackedCode @() -FeatureKey @('X') -UpgradeCodeValue @{ U = @('X') }).Count 'nothing selected without product codes in scope'

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('iee-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $f = Join-Path $tmp 'VENDOR-NAME-WITH-TOKEN.msi'
        [System.IO.File]::WriteAllBytes($f, [byte[]](1..255 + 1..255 + 1..255 + 1..255))
        $hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        Assert-True (Test-InstallerIntegrity -Path $f -ExpectedSha256 $hash -ExpectedSignerSubject '' -MinimumBytes 100).Ok 'integrity: hash match passes'
        Assert-True (-not (Test-InstallerIntegrity -Path $f -ExpectedSha256 ('0' * 64) -ExpectedSignerSubject '' -MinimumBytes 100).Ok) 'integrity: hash mismatch fails'
        Assert-True (-not (Test-InstallerIntegrity -Path $f -ExpectedSha256 '' -ExpectedSignerSubject '' -MinimumBytes 100).Ok) 'integrity: refuses when nothing configured'
        Assert-True (-not (Test-InstallerIntegrity -Path $f -ExpectedSha256 $hash -ExpectedSignerSubject '' -MinimumBytes 1MB).Ok) 'integrity: too small fails'
        Assert-True (-not (Test-InstallerIntegrity -Path $f -ExpectedSha256 '' -ExpectedSignerSubject 'CN=Example' -MinimumBytes 100).Ok) 'integrity: unsigned file fails signer check'
        Assert-True (-not (Test-InstallerIntegrity -Path $f -ExpectedSha256 '' -ExpectedSignerSubject '' -ExpectedSignerThumbprint @('00' * 20) -MinimumBytes 100).Ok) 'integrity: unsigned file fails thumbprint check'

        # Signer checks against a catalog-signed Windows binary: exact subject and
        # thumbprint pass, a longer look-alike subject and a wrong thumbprint fail.
        $signed = Join-Path $env:WINDIR 'System32\whoami.exe'
        $sig = Get-AuthenticodeSignature -LiteralPath $signed
        if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate) {
            $subj = $sig.SignerCertificate.Subject
            Assert-True (Test-InstallerIntegrity -Path $signed -ExpectedSha256 '' -ExpectedSignerSubject $subj -MinimumBytes 100).Ok 'integrity: exact signer subject passes'
            Assert-True (-not (Test-InstallerIntegrity -Path $signed -ExpectedSha256 '' -ExpectedSignerSubject ($subj + ' Evil') -MinimumBytes 100).Ok) 'integrity: look-alike subject fails'
            Assert-True (-not (Test-InstallerIntegrity -Path $signed -ExpectedSha256 '' -ExpectedSignerSubject ('*' + $subj.Substring(0, 10) + '*') -MinimumBytes 100).Ok) 'integrity: a wildcard is not accepted as a subject'
            Assert-True (Test-InstallerIntegrity -Path $signed -ExpectedSha256 '' -ExpectedSignerSubject '' -ExpectedSignerThumbprint @($sig.SignerCertificate.Thumbprint.ToLowerInvariant()) -MinimumBytes 100).Ok 'integrity: pinned thumbprint passes'
            Assert-True (-not (Test-InstallerIntegrity -Path $signed -ExpectedSha256 '' -ExpectedSignerSubject $subj -ExpectedSignerThumbprint @('00' * 20) -MinimumBytes 100).Ok) 'integrity: wrong thumbprint fails even with the right subject'
        }
        else {
            Write-Host '  (no valid catalog signature on whoami.exe here: signer pass tests skipped)'
        }

        # A verbose MSI log is usually UTF-16 with a byte order mark; the staged copy must not carry the name.
        $log = Join-Path $tmp 'msi.log'
        [System.IO.File]::WriteAllText($log, "Package: C:\Work\Agent_SITETOKEN0123456789_x64.msi`r`nPROPERTY CHANGE: PackageName = Agent_SITETOKEN0123456789_x64.msi`r`nReturn value 3`r`n", [System.Text.Encoding]::Unicode)
        $staged = Join-Path $tmp 'staged.log'
        Assert-True (Copy-RedactedLog -Source $log -Destination $staged -Literal $lit) 'redacted log copy written'
        $stagedText = [System.IO.File]::ReadAllText($staged)
        Assert-True ($stagedText -notmatch 'SITETOKEN' -and $stagedText -match 'Return value 3') 'redacted log keeps the content and drops the name'
        Assert-True (-not (Copy-RedactedLog -Source (Join-Path $tmp 'missing.log') -Destination $staged -Literal $lit)) 'missing log reported, not thrown'
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Section 'Unit: WLAN failure summary'
& {
    . (Join-Path $repo 'remediations\wlan-monitor\Detect-WlanFailures.ps1')
    $now = Get-Date
    $ev = @(
        [pscustomobject]@{ Id = 8001; TimeCreated = $now.AddHours(-5); Ssid = 'CONTOSO-CORP'; Reason = '' },
        [pscustomobject]@{ Id = 8001; TimeCreated = $now.AddHours(-4); Ssid = 'HomeNet-1234'; Reason = '' }
    )
    $s = Get-WlanFailureSummary -WlanEvent $ev -ReportSsids @('CONTOSO-CORP') -IgnoreReasonPattern '(?i)disconnected by the user'
    Assert-Equal 0 $s.FailCount 'successful connects (8001) are never failures'
    Assert-Equal 2 $s.Connects 'connects counted'
    $ev += [pscustomobject]@{ Id = 8003; TimeCreated = $now.AddHours(-3); Ssid = 'CONTOSO-CORP'; Reason = 'The network is disconnected by the user.' }
    $ev += [pscustomobject]@{ Id = 8003; TimeCreated = $now.AddHours(-2); Ssid = 'CONTOSO-CORP'; Reason = 'The network is disconnected by the driver.' }
    $ev += [pscustomobject]@{ Id = 8002; TimeCreated = $now.AddHours(-1); Ssid = 'HomeNet-1234'; Reason = 'The specific network is not available.' }
    $s = Get-WlanFailureSummary -WlanEvent $ev -ReportSsids @('CONTOSO-CORP') -IgnoreReasonPattern '(?i)disconnected by the user'
    Assert-Equal 2 $s.FailCount 'failures = 8002 plus non-ignored 8003'
    Assert-Equal 1 $s.Ignored 'user disconnect ignored'
    Assert-True (($s.Recent -join ' ') -notmatch 'HomeNet') 'unlisted SSID masked'
    Assert-True (($s.Recent -join ' ') -match '<other>') 'mask marker present'
    Assert-True (($s.Recent[0]) -match ' 8002 ') 'most recent failure first'
}

Write-Section 'Unit: EDR recon helpers'
& {
    . (Join-Path $repo 'remediations\edr-install-recon\Detect-EdrInstallRecon.ps1')
    Assert-Equal 'C:\Program Files\Fabrikam\agent.exe' (Get-BinaryPathFromCommandLine -CommandLine '"C:\Program Files\Fabrikam\agent.exe" -k svc') 'quoted service path'
    Assert-Equal 'C:\Windows\agent.exe' (Get-BinaryPathFromCommandLine -CommandLine 'C:\Windows\agent.exe -service') 'unquoted service path'
    $flt = @(
        'Filter Name                     Num Instances    Altitude    Frame',
        '------------------------------  -------------  ------------  -----',
        'bindflt                                 1       409800         0',
        'FabrikamMini                            5       389999         0',
        'WdFilter                               10       328010         0',
        'ContosoSensorFlt                        4       321410         0'
    )
    $names = @(Get-MinifilterName -FltmcOutput $flt -Ignore @('bindflt', 'WdFilter'))
    Assert-Equal 2 $names.Count 'minifilters after ignore list'
    Assert-True ($names -contains 'FabrikamMini@389999') 'minifilter with altitude'

    $now = Get-Date
    $ev = @(
        [pscustomobject]@{ Id = 11724; TimeCreated = $now.AddMinutes(-1); Message = 'Product: Contoso Sensor -- Removal completed successfully.' },
        [pscustomobject]@{ Id = 11722; TimeCreated = $now.AddMinutes(-5); Message = 'Product: Contoso Sensor -- Error 1722. There is a problem with this Windows Installer package.' },
        [pscustomobject]@{ Id = 11708; TimeCreated = $now.AddMinutes(-10); Message = 'Product: Contoso Sensor -- Installation failed.' },
        [pscustomobject]@{ Id = 11708; TimeCreated = $now.AddMinutes(-0.5); Message = 'Product: Fabrikam Tool -- Installation failed.' }
    )
    $pick = Select-MsiErrorEvent -EventRecord $ev -Id $Config.MsiErrorEventIds -ProductPattern $Config.NewProductPattern
    Assert-Equal 11722 $pick.Id 'newest failure event for the product wins; a successful removal (11724) is not a failure'
    Assert-True ($Config.MsiErrorEventIds -notcontains 11724) 'default event ids leave out 11724'
    Assert-True ($null -eq (Select-MsiErrorEvent -EventRecord @($ev[0]) -Id $Config.MsiErrorEventIds -ProductPattern $Config.NewProductPattern)) 'only a removal event means no failure event'
}

Write-Section 'Unit: evidence collector helpers'
& {
    . (Join-Path $repo 'remediations\evidence-collector\Remediate-CollectEvidence.ps1')
    Assert-Equal 'Microsoft-Windows-AppLocker_MSI_and_Script' (ConvertTo-SafeFileName -Name 'Microsoft-Windows-AppLocker/MSI and Script') 'channel to file name'
    Assert-Equal '*[System[TimeCreated[timediff(@SystemTime) <= 1209600000]]]' (Get-EventTimeQuery -Days 14) '14 day event query'
    Assert-True ($Config.WorkFolder -like 'C:\Program Files\*') 'evidence work folder sits under Program Files'
}
& {
    . (Join-Path $repo 'remediations\evidence-collector\Detect-EvidenceBundleDue.ps1')
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('iee-ev-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Assert-Equal 0 @(Get-RecentBundle -Folder $tmp -Prefix 'Evidence_Test_' -Hours 20).Count 'empty folder: bundle due'
        $old = Join-Path $tmp 'Evidence_Test_20260101_0000.zip'
        Set-Content -LiteralPath $old -Value 'x'
        (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddHours(-30)
        Assert-Equal 0 @(Get-RecentBundle -Folder $tmp -Prefix 'Evidence_Test_' -Hours 20).Count 'old bundle does not count'
        $note = Join-Path $tmp 'Evidence_Test_20260102_0000_TOOBIG.txt'
        Set-Content -LiteralPath $note -Value 'too big'
        $recent = @(Get-RecentBundle -Folder $tmp -Prefix 'Evidence_Test_' -Hours 20)
        Assert-True ($recent.Count -eq 1 -and $recent[0].Name -like '*_TOOBIG.txt') 'a recent too-big note makes detection back off'
        Set-Content -LiteralPath (Join-Path $tmp 'Evidence_Other_20260102_0000.zip') -Value 'x'
        Assert-Equal 1 @(Get-RecentBundle -Folder $tmp -Prefix 'Evidence_Test_' -Hours 20).Count 'other prefixes ignored'
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Section 'Unit: Win32 detection version logic'
& {
    . (Join-Path $repo 'win32\detection\Detect-UninstallVersion.ps1')
    Assert-Equal ([version]'4.12.0.0') (ConvertTo-ComparableVersion -Text '4.12.0') 'three-part version padded to four'
    Assert-Equal ([version]'4.12.0.7') (ConvertTo-ComparableVersion -Text '4.12.0.7 (x64)') 'version with suffix'
    Assert-Equal ([version]'26.0.0.0') (ConvertTo-ComparableVersion -Text '26') 'single number padded'
    Assert-True ($null -eq (ConvertTo-ComparableVersion -Text 'none')) 'no number gives null'
    $entries = @(
        [pscustomobject]@{ KeyName = 'ContosoDocClient'; DisplayName = 'Contoso Document Client 4'; DisplayVersion = '412.0.6' },
        [pscustomobject]@{ KeyName = '{00000000-0000-0000-0000-000000000001}'; DisplayName = 'Contoso Document Client for Windows'; DisplayVersion = '412.0.7' },
        [pscustomobject]@{ KeyName = 'Other'; DisplayName = 'Fabrikam Tool'; DisplayVersion = '999.0' }
    )
    $hit = Find-UninstallEntry -Entry $entries -DisplayNameLike 'Contoso Document Client*' -MinimumVersion '412.0.7'
    Assert-Equal '412.0.7' $hit.DisplayVersion 'at-or-above finds the current build'
    $none = Find-UninstallEntry -Entry $entries -DisplayNameLike 'Contoso Document Client*' -MinimumVersion '412.1'
    Assert-True ($null -eq $none) 'older builds do not satisfy a higher minimum'
    $newer = Find-UninstallEntry -Entry @([pscustomobject]@{ KeyName = 'k'; DisplayName = 'Contoso Document Client'; DisplayVersion = '413.0.1' }) -DisplayNameLike 'Contoso Document Client*' -MinimumVersion '412.0.7'
    Assert-True ($null -ne $newer) 'self-updated newer build still detected'
    $msiOnly = Find-UninstallEntry -Entry $entries -DisplayNameLike 'Contoso Document Client*' -MinimumVersion '412.0' -MsiKeysOnly $true
    Assert-Equal '{00000000-0000-0000-0000-000000000001}' $msiOnly.KeyName 'MSI-keys-only filter'
    # Three-part against four-part, both directions. Without padding, [version]'412.0.7' -ge [version]'412.0.7.0' is False.
    $three = @([pscustomobject]@{ KeyName = 'k'; DisplayName = 'Contoso Document Client'; DisplayVersion = '412.0.7' })
    $four = @([pscustomobject]@{ KeyName = 'k'; DisplayName = 'Contoso Document Client'; DisplayVersion = '412.0.7.0' })
    Assert-True ($null -ne (Find-UninstallEntry -Entry $three -DisplayNameLike 'Contoso Document Client*' -MinimumVersion '412.0.7.0')) 'three-part registry value meets a four-part minimum'
    Assert-True ($null -ne (Find-UninstallEntry -Entry $four -DisplayNameLike 'Contoso Document Client*' -MinimumVersion '412.0.7')) 'four-part registry value meets a three-part minimum'
    Assert-True ($null -eq (Find-UninstallEntry -Entry $three -DisplayNameLike 'Contoso Document Client*' -MinimumVersion '412.0.7.1')) 'a higher fourth part is still required'
}

Write-Section 'Unit: InstallShield result parsing'
& {
    . (Join-Path $repo 'win32\installshield\Install-WithResponseFile.ps1')
    $ok = @('[InstallShield Silent]', 'Version=v7.00', 'File=Log File', '[ResponseResult]', 'ResultCode=0', '[Application]', 'Name=Example App')
    Assert-Equal 0 (Get-IssResultCode -LogLines $ok) 'ResultCode 0'
    $bad = @('[ResponseResult]', 'ResultCode=-3')
    Assert-Equal -3 (Get-IssResultCode -LogLines $bad) 'ResultCode -3'
    Assert-True ((Get-IssResultText -Code -3) -match 'response file') 'ResultCode -3 explained'
    $wrongSection = @('[Application]', 'ResultCode=0')
    Assert-True ($null -eq (Get-IssResultCode -LogLines $wrongSection)) 'ResultCode outside [ResponseResult] ignored'
    Assert-True ((Get-IssResultText -Code $null) -match 'no ResultCode') 'missing ResultCode explained'
    $sample = Get-Content -LiteralPath (Join-Path $repo 'win32\installshield\response-file.sample.iss')
    Assert-True (($sample -join "`n") -match '\[InstallShield Silent\]') 'sample response file shape'
    Assert-Equal '/s /f1"C:\p\setup.iss" /f2"C:\l\s.log"' (Get-SetupArgument -ResponseFile 'C:\p\setup.iss' -LogFile 'C:\l\s.log') 'setup arguments'
    Assert-Equal '/s /f1"C:\p\setup.iss" /f2"C:\l\s.log" /SMS' (Get-SetupArgument -ResponseFile 'C:\p\setup.iss' -LogFile 'C:\l\s.log' -LegacySms $true) 'setup arguments with /SMS for legacy setups'
}

Write-Section 'Unit: portable EXE wrapper helpers'
& {
    . (Join-Path $repo 'win32\portable-exe\Install-PortableApp.ps1') -AppName 'Example Viewer' -Publisher 'Example Publisher' -ExeName 'ExampleViewer.exe'
    Assert-Equal 'ExampleViewer_Portable' (Get-DefaultKeyName -Name 'Example Viewer') 'registry key name'
    $v = Get-ArpValue -AppName 'Example Viewer' -Publisher 'Example Publisher' -Version '5.5.1.0' -Target 'C:\Program Files\Example Publisher\Example Viewer' -ExePath 'C:\Program Files\Example Publisher\Example Viewer\ExampleViewer.exe' -SizeKb 12000 -Date '20260101'
    Assert-Equal '5.5.1.0' $v.DisplayVersion 'ARP DisplayVersion'
    Assert-Equal 1 $v.NoModify 'ARP NoModify'
    Assert-True ($v.UninstallString -match 'Uninstall-PortableApp\.ps1" -Apply$') 'ARP uninstall string runs the uninstaller with -Apply'
    Assert-Equal $v.UninstallString $v.QuietUninstallString 'quiet uninstall string set'
}

# ---------------------------------------------------------------- 5. MSI module
if (-not $SkipMsi) {
    Write-Section 'MSI module on a synthetic MSI'
    . (Join-Path $PSScriptRoot 'SyntheticFixtures.ps1')
    Import-Module (Join-Path $repo 'msi\MsiTools.psm1') -Force
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('iee-msi-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $msi = Join-Path $tmp 'synthetic.msi'
        New-SyntheticMsi -Path $msi
        $srcHash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
        Assert-True ($null -eq (Get-MsiProperty -Path $msi -Name ALLUSERS)) 'synthetic MSI starts without ALLUSERS'
        Assert-Equal 'Synthetic Test Agent' (Get-MsiProperty -Path $msi -Name ProductName).Value 'read ProductName'

        $dry = Set-MsiProperty -Path $msi -Name ALLUSERS -Value 1 -OutputPath (Join-Path $tmp 'out\patched.msi')
        Assert-Equal 'WouldInsert' $dry.Action 'dry run reports insert'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $tmp 'out\patched.msi'))) 'dry run writes nothing'

        $set = Set-MsiProperty -Path $msi -Name ALLUSERS -Value 1 -OutputPath (Join-Path $tmp 'out\patched.msi') -Apply
        Assert-True $set.Verified 'ALLUSERS insert verified by read-back'
        Assert-Equal '1' (Get-MsiProperty -Path (Join-Path $tmp 'out\patched.msi') -Name ALLUSERS).Value 'patched copy holds ALLUSERS=1'
        $upd = Set-MsiProperty -Path (Join-Path $tmp 'out\patched.msi') -Name ProductName -Value 'Renamed Product' -OutputPath (Join-Path $tmp 'out\renamed.msi') -Apply
        Assert-True ($upd.Action -eq 'Update' -and $upd.Verified) 'update path verified'
        $threw = $false
        try { Set-MsiProperty -Path $msi -Name ALLUSERS -Value 1 -OutputPath $msi -Apply | Out-Null } catch { $threw = $true }
        Assert-True $threw 'refuses to edit the source in place'
        $threw = $false
        try { Set-MsiProperty -Path $msi -Name "ALLUSERS' OR '1'='1" -Value 1 -OutputPath (Join-Path $tmp 'x.msi') | Out-Null } catch { $threw = $true }
        Assert-True $threw 'rejects a non-identifier property name'

        $seq = @(Get-MsiSequence -Path $msi)
        Assert-True (@($seq | Where-Object { $_.Action -eq 'ExampleDiskCheckAction' }).Count -eq 1) 'sequence lists the custom action'

        $mst = Join-Path $tmp 'out\skip-check.mst'
        $plan = New-MsiTransformRemoveAction -Path $msi -Action ExampleDiskCheckAction -TransformPath $mst
        Assert-Equal 2 @($plan.WouldRemove).Count 'transform dry run finds the action in both sequences'
        Assert-True (-not (Test-Path -LiteralPath $mst)) 'transform dry run writes nothing'
        $built = New-MsiTransformRemoveAction -Path $msi -Action ExampleDiskCheckAction -TransformPath $mst -Apply
        Assert-True ($built.Applied -and $built.Verified) 'transform built and verified'
        Assert-True (Test-Path -LiteralPath $mst) 'transform file exists'
        $check = Test-MsiTransform -Path $msi -TransformPath $mst -Action ExampleDiskCheckAction, ExampleTokenCheckAction -Table InstallExecuteSequence
        $token = @($check.Rows | Where-Object { $_.Action -eq 'ExampleTokenCheckAction' })[0]
        Assert-True ($token.PresentBefore -and $token.PresentAfter) 'transform leaves the next custom action in place'
        Assert-Equal $srcHash (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash 'source MSI unchanged after all operations'

        $pkg = Join-Path $tmp 'pkg.intunewin'
        New-SyntheticIntuneWin -Path $pkg -Context User
        $meta = Get-IntuneWinMetadata -Path $pkg
        Assert-Equal 'User' $meta.MsiInfo.MsiExecutionContext 'intunewin execution context read'
        Assert-Equal '<redacted>' $meta.EncryptionInfo.EncryptionKey 'encryption key redacted by default'
        Assert-Equal 'SHA256' $meta.EncryptionInfo.FileDigestAlgorithm 'non-secret encryption field shown'
        Assert-Equal '1.8.7.0' $meta.ToolVersion 'tool version read'
    }
    finally {
        Remove-Module MsiTools -ErrorAction SilentlyContinue
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- 6. smoke
if (-not $SkipSmoke) {
    Write-Section 'Smoke: read-only scripts and dry runs on this machine'
    $hostExe = (Get-Process -Id $PID).Path
    function Invoke-Child {
        param([string]$Script, [string[]]$Arguments = @())
        $out = & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out.Trim() }
    }
    $r = Invoke-Child (Join-Path $repo 'remediations\agent-self-heal\Detect-AgentHealth.ps1')
    Assert-True ($r.Code -eq 1 -and $r.Output -match '^UNHEALTHY') "detect health on a machine without the agent: exit 1 UNHEALTHY (got $($r.Code))"
    $r = Invoke-Child (Join-Path $repo 'remediations\agent-self-heal\Remediate-AgentSelfHeal.ps1')
    Assert-True ($r.Code -eq 0 -and $r.Output -match 'DRY-RUN' -and $r.Output -match 'WOULD download') "self-heal dry run (got $($r.Code))"
    Assert-True (-not (Test-Path -LiteralPath 'C:\Program Files\SelfHeal')) 'self-heal dry run created no work folder'
    Assert-True ($r.Output -notmatch 'REPLACE-WITH-VENDOR-FILE-NAME') 'self-heal dry run output does not print the installer file name'
    Assert-True ($r.Output.Length -le 2048) 'self-heal output within budget'
    $r = Invoke-Child (Join-Path $repo 'remediations\recon-template\Detect-ReconTemplate.ps1')
    Assert-True ($r.Code -eq 0 -and $r.Output -match '^OS build=' -and $r.Output.Length -le 2048) "recon template (got $($r.Code))"
    $r = Invoke-Child (Join-Path $repo 'remediations\evidence-collector\Detect-EvidenceBundleDue.ps1')
    Assert-True ($r.Code -eq 1 -and $r.Output -match 'BUNDLE DUE') "evidence bundle due (got $($r.Code))"
    $r = Invoke-Child (Join-Path $repo 'remediations\evidence-collector\Remediate-CollectEvidence.ps1')
    Assert-True ($r.Code -eq 0 -and $r.Output -match 'DRY-RUN') "evidence collector dry run (got $($r.Code))"
    Assert-True (-not (Test-Path -LiteralPath 'C:\Program Files\EvidenceCollector')) 'evidence dry run created no work folder'
    $r = Invoke-Child (Join-Path $repo 'remediations\wlan-monitor\Detect-WlanFailures.ps1')
    Assert-True (($r.Code -eq 0 -or $r.Code -eq 1) -and $r.Output -match '^(OK|FailCount)') "wlan monitor runs (got $($r.Code))"
    $r = Invoke-Child (Join-Path $repo 'remediations\edr-install-recon\Detect-EdrInstallRecon.ps1')
    Assert-True ($r.Code -eq 0 -and $r.Output -match '^Model=' -and $r.Output -match 'NewSvc=None') "edr recon (got $($r.Code))"
    $r = Invoke-Child (Join-Path $repo 'win32\detection\Detect-UninstallVersion.ps1')
    Assert-True ($r.Code -eq 1 -and $r.Output -eq '') "detection script: not detected means exit 1 and no output (got $($r.Code))"

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('iee-smoke-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Copy-Item (Join-Path $repo 'win32\portable-exe\*.ps1') $tmp
        Copy-Item (Join-Path $env:WINDIR 'System32\whoami.exe') (Join-Path $tmp 'ExampleViewer.exe')
        $r = Invoke-Child (Join-Path $tmp 'Install-PortableApp.ps1') @('-AppName', 'Example Viewer', '-Publisher', 'Example Publisher', '-ExeName', 'ExampleViewer.exe')
        Assert-True ($r.Code -eq 0 -and $r.Output -match 'DRY-RUN') "portable install dry run (got $($r.Code))"
        Assert-True (-not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\ExampleViewer_Portable')) 'portable dry run wrote no registry key'
        $r = Invoke-Child (Join-Path $tmp 'Uninstall-PortableApp.ps1') @('-TargetFolder', $tmp)
        Assert-True ($r.Code -eq 0 -and $r.Output -match 'Nothing to do') "portable uninstall without manifest (got $($r.Code))"

        Copy-Item (Join-Path $repo 'win32\installshield\Install-WithResponseFile.ps1') $tmp
        Copy-Item (Join-Path $env:WINDIR 'System32\whoami.exe') (Join-Path $tmp 'setup.exe')
        Copy-Item (Join-Path $repo 'win32\installshield\response-file.sample.iss') (Join-Path $tmp 'setup.iss')
        $r = Invoke-Child (Join-Path $tmp 'Install-WithResponseFile.ps1')
        Assert-True ($r.Code -eq 0 -and $r.Output -match 'DRY-RUN' -and $r.Output -match '/s /f1') "installshield dry run (got $($r.Code))"

        # The 64-bit guard, run for real from 32-bit Windows PowerShell: the child must
        # be 64-bit and receive the same parameters, and its exit code must come back.
        $ps32 = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
        if ([Environment]::Is64BitOperatingSystem -and (Test-Path -LiteralPath $ps32)) {
            $guard = Get-RegionBody -Text ([System.IO.File]::ReadAllText((Join-Path $repo 'remediations\lib\Ensure64Bit.ps1'))) -Name 'Ensure64Bit'
            $probe = Join-Path $tmp 'Probe-64Bit.ps1'
            $probeText = @('param([string]$Name, [switch]$Flag)', $guard, 'Write-Output ("{0}|{1}|{2}" -f $Name, $Flag.IsPresent, [Environment]::Is64BitProcess)', 'exit 7') -join "`r`n"
            [System.IO.File]::WriteAllText($probe, $probeText, [System.Text.Encoding]::ASCII)
            $out = (& $ps32 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe -Name 'two words' -Flag 2>&1 | Out-String).Trim()
            $code = $LASTEXITCODE
            Assert-True ($out -eq 'two words|True|True') "64-bit guard relaunches from a 32-bit host with parameters intact (got '$out')"
            Assert-Equal 7 $code '64-bit guard passes the child exit code back'
        }
        else {
            Write-Host '  (no 32-bit Windows PowerShell here: relaunch test skipped)'
        }
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ("Passed: {0}  Failed: {1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { $script:Failures | ForEach-Object { Write-Host "  - $_" } }
exit $script:Fail
