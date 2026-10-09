<#
.SYNOPSIS
    Intune Remediations remediation script: idempotent self-heal for an MSI-based agent.

.DESCRIPTION
    Works in escalating stages and stops at the first one that leaves every
    agent service Running:

      Stage 0  Healthy. Every expected service exists and is Running.
               Touch nothing and exit 0 ("NOTHING TOUCHED").
      Stage 1  Services exist but some are stopped. Start them, wait, re-check.
               A service set to Disabled is reported and left alone: someone
               disabled it on purpose and a script should not override that.
      Stage 2  Rebuild.
               a. msiexec /x every matching product that has a product code.
               b. Purge stale Windows Installer registration that msiexec could
                  not remove: Add/Remove Programs keys (both registry views),
                  HKLM\SOFTWARE\Classes\Installer\Products\<packed GUID>,
                  ...\Classes\Installer\Features\<packed GUID>, the product's
                  value under ...\Classes\Installer\UpgradeCodes\<packed code>
                  (an orphan there can send the reinstall's FindRelatedProducts
                  after a product that no longer exists), and
                  ...\Installer\UserData\<SID>\Products\<packed GUID>.
                  Every key is exported to a .reg backup before it is changed
                  and read back afterwards. Component registrations
                  (UserData\<SID>\Components) are left alone: they are keyed by
                  component and shared across products, and a leftover value
                  there at worst leaves a file behind at a later uninstall.
               c. Stop and delete leftover services, stop processes running from
                  the install folders, delete the folders (only under Program
                  Files or ProgramData, with rd /s so junctions inside are
                  removed, not followed).
               d. Create or check the private work folder (see New-PrivateFolder:
                  under Program Files, refused if someone else created it or it
                  is a junction, owner and ACL read back). Download the vendor
                  MSI there under its ORIGINAL file name, verify SHA256, exact
                  signer subject and/or signer thumbprint, and install with a
                  verbose log kept in the work folder. A redacted copy of that
                  log goes to the IME Logs folder for Collect diagnostics.
               e. Require every service Running. Otherwise exit 1 with the
                  telling lines from the MSI log.

    DRY RUN BY DEFAULT. Without -Apply (local runs) or ApplyWhenNoParameter =
    $true (the copy you upload to Intune), the script reads everything, prints
    what it WOULD do, and changes nothing.

    Why the installer file name is a setting and must never be changed: some
    vendors put a site or tenant install token in the MSI file name and read it
    back from the file name at install time. Rename the file and the install
    still starts, then fails later in a custom action with an empty token. I
    lost four script versions to exactly that. Keep the file name byte for byte
    as the vendor's portal delivers it, and treat it as a secret: do not commit
    a configured copy of this script to source control.

    Treating it as a secret also means keeping it out of what the script
    writes. The portal output never prints the file name or the URL. A verbose
    MSI log records the package path, so the log and the transcript stay in
    the private work folder, and only a copy with the file name, its base name
    and the URL replaced by <vendor-installer> is staged in IME Logs. If the
    vendor's custom actions also log the bare token, add a regex for it to
    RedactPatterns or set StageRedactedMsiLog to $false.

    Intune settings: run as SYSTEM, "Run script in 64-bit PowerShell" = Yes.
    The script also relaunches itself in 64-bit if it lands in a 32-bit host.

.PARAMETER Apply
    Make changes. Intune cannot pass parameters, so for the uploaded copy set
    ApplyWhenNoParameter to $true in the configuration block instead.

.NOTES
    Pattern status: [built, ran on real tickets]. The original went through
    five versions on a stranded group of devices for an RMM agent at my employer
    in July 2026. The final version's export shows HEALTHY / NOTHING TOUCHED as
    the latest result on all 17 devices it was assigned to, which proves the
    no-op guard and the end state, not the repair path. This file is a fresh
    rewrite, generalized from what I ran at work, and has only been
    parse-checked and unit-tested against synthetic input.
#>
[CmdletBinding()]
param(
    [switch]$Apply
)

$Config = @{
    # --- what "healthy" means (keep identical to Detect-AgentHealth.ps1) ---
    ServiceNames            = @('ContosoAgent*')
    ExcludeServicePattern   = '^ContosoAgentRemoteSupport'
    MinimumServiceCount     = 2

    # --- rebuild scope ---
    # Regex matched against DisplayName / ProductName. Anchor it. Anything that
    # matches is uninstalled and purged, so test it with the dry run first.
    ProductNamePattern      = '^Contoso (RMM Agent|Agent Platform)\b'
    # Regex. Products matching this are never touched even if the pattern above
    # matches (for example a remote support client from the same vendor).
    ExcludeNamePattern      = 'Remote Support'
    # Folders removed during the rebuild. Must sit under Program Files or ProgramData.
    InstallFolders          = @('C:\Program Files (x86)\Contoso\Agent', 'C:\Program Files (x86)\Contoso\AgentSetup')

    # --- reinstall ---
    InstallerUrl            = 'https://downloads.example.com/agent/REPLACE-WITH-VENDOR-FILE-NAME.msi'
    # Keep EXACTLY as the vendor delivered it. See the description above.
    InstallerFileName       = 'REPLACE-WITH-VENDOR-FILE-NAME.msi'
    # At least one of these three must be set or the script refuses to install.
    ExpectedSha256          = ''
    # Exact certificate Subject (not a wildcard), for example 'CN=Contoso Ltd, O=Contoso Ltd, C=US'.
    ExpectedSignerSubject   = ''
    # Signer certificate thumbprints. Pinning is strict: add the new one when the vendor renews.
    ExpectedSignerThumbprint = @()
    MinimumInstallerBytes   = 1MB       # an HTML error page saved as .msi is a few KB
    MsiArguments            = '/qn /norestart REBOOT=ReallySuppress'
    ServiceStartWaitSeconds = 20
    PostInstallWaitSeconds  = 120

    # --- logging and state ---
    ImeLogs                 = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs'
    LogPrefix               = 'ContosoAgent_SelfHeal'
    # Private work folder for the download, the verbose MSI log, the transcript and
    # the .reg backups. Under Program Files because standard users cannot create
    # folders there; New-PrivateFolder still checks owner, ACL and junctions.
    WorkFolder              = 'C:\Program Files\SelfHeal\ContosoAgent'
    # Copy the verbose MSI log, redacted, into ImeLogs so Collect diagnostics brings it back.
    StageRedactedMsiLog     = $true
    # Extra regexes redacted from the report and the staged log, for example the
    # bare token if the vendor's custom actions log it on its own.
    RedactPatterns          = @()

    # --- Intune switch ---
    ApplyWhenNoParameter    = $false
}

# region OutputBudget
function Format-RemediationOutput {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Part = @(),
        [ValidateRange(64, 100000)][int]$Budget = 2048,
        [string]$Separator = ' || '
    )
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Part) {
        if ($null -eq $p) { continue }
        $t = (($p -replace '[\x00-\x1F\x7F]+', ' ') -replace '\s+', ' ').Trim()
        if ($t.Length -gt 0) { $items.Add($t) }
    }
    if ($items.Count -eq 0) { return '' }
    $joined = $items -join $Separator
    if ($joined.Length -le $Budget) { return $joined }

    $marker = '...'
    $minShare = 24
    $note = ''
    $maxParts = [int][Math]::Max(1, [Math]::Floor(($Budget + $Separator.Length) / ($minShare + $Separator.Length)))
    if ($items.Count -gt $maxParts) {
        $keep = [Math]::Max(1, $maxParts - 1)
        $note = '[+' + ($items.Count - $keep) + ' more]'
        $trimmed = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $keep; $i++) { $trimmed.Add($items[$i]) }
        $items = $trimmed
    }

    $sepCount = $items.Count - 1
    if ($note) { $sepCount++ }
    $available = $Budget - ($Separator.Length * $sepCount) - $note.Length
    $lengths = @($items | ForEach-Object { $_.Length })
    $alloc = New-Object 'int[]' $items.Count
    $open = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $items.Count; $i++) { $open.Add($i) }
    $remaining = $available
    while ($open.Count -gt 0) {
        $share = [int][Math]::Floor($remaining / $open.Count)
        $fits = @($open | Where-Object { $lengths[$_] -le $share })
        if ($fits.Count -eq 0) {
            foreach ($i in $open) { $alloc[$i] = $share }
            break
        }
        foreach ($i in $fits) {
            $alloc[$i] = $lengths[$i]
            $remaining -= $lengths[$i]
            [void]$open.Remove($i)
        }
    }

    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($alloc[$i] -ge $lengths[$i]) {
            $out.Add($items[$i])
        }
        else {
            $keepChars = [Math]::Max(0, $alloc[$i] - $marker.Length)
            $out.Add($items[$i].Substring(0, $keepChars) + $marker)
        }
    }
    if ($note) { $out.Add($note) }
    $result = $out -join $Separator
    if ($result.Length -gt $Budget) { $result = $result.Substring(0, $Budget) }
    return $result
}
# endregion OutputBudget

# region PackedGuid
function ConvertTo-PackedGuid {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Guid)
    $g = $Guid.Trim().Trim('{', '}')
    if ($g -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') {
        throw "Not a GUID: $Guid"
    }
    $p = $g.Split('-')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(-join ($p[0].ToCharArray()[7..0]))
    [void]$sb.Append(-join ($p[1].ToCharArray()[3..0]))
    [void]$sb.Append(-join ($p[2].ToCharArray()[3..0]))
    $tail = $p[3] + $p[4]
    for ($i = 0; $i -lt $tail.Length; $i += 2) {
        [void]$sb.Append($tail[$i + 1])
        [void]$sb.Append($tail[$i])
    }
    return $sb.ToString().ToUpperInvariant()
}

function ConvertFrom-PackedGuid {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PackedGuid)
    $s = $PackedGuid.Trim()
    if ($s -notmatch '^[0-9A-Fa-f]{32}$') { throw "Not a packed GUID: $PackedGuid" }
    $a = -join ($s.Substring(0, 8).ToCharArray()[7..0])
    $b = -join ($s.Substring(8, 4).ToCharArray()[3..0])
    $c = -join ($s.Substring(12, 4).ToCharArray()[3..0])
    $tail = $s.Substring(16)
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $tail.Length; $i += 2) {
        [void]$sb.Append($tail[$i + 1])
        [void]$sb.Append($tail[$i])
    }
    $d = $sb.ToString()
    return ('{' + $a + '-' + $b + '-' + $c + '-' + $d.Substring(0, 4) + '-' + $d.Substring(4) + '}').ToUpperInvariant()
}
# endregion PackedGuid

function Get-RedactionList {
    # The strings that can carry a vendor install token: the URL, the file name and
    # its base name. Longest first, so the URL is replaced before the name inside it.
    param([hashtable]$Settings)
    $name = [string]$Settings.InstallerFileName
    $candidates = @([string]$Settings.InstallerUrl, $name, [System.IO.Path]::GetFileNameWithoutExtension($name))
    return @($candidates | Where-Object { $_ -and $_.Trim().Length -ge 6 } | Select-Object -Unique | Sort-Object Length -Descending)
}

function Protect-InstallerName {
    # Pure: replace every literal (case-insensitive) and every regex with a placeholder.
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [AllowEmptyCollection()][string[]]$Literal = @(),
        [AllowEmptyCollection()][string[]]$Pattern = @(),
        [string]$Placeholder = '<vendor-installer>'
    )
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $out = $Text
    foreach ($l in $Literal) {
        if ($l) { $out = [regex]::Replace($out, [regex]::Escape($l), $Placeholder, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
    }
    foreach ($p in $Pattern) {
        if ($p) { $out = [regex]::Replace($out, $p, $Placeholder) }
    }
    return $out
}

function Copy-RedactedLog {
    # Writes a redacted UTF-8 copy of a log. ReadAllText honours the UTF-16 byte
    # order mark that verbose MSI logs usually carry.
    param([string]$Source, [string]$Destination, [string[]]$Literal = @(), [string[]]$Pattern = @())
    if (-not (Test-Path -LiteralPath $Source)) { return $false }
    $text = [System.IO.File]::ReadAllText($Source)
    $clean = Protect-InstallerName -Text $text -Literal $Literal -Pattern $Pattern
    [System.IO.File]::WriteAllText($Destination, $clean, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

$script:Report = New-Object System.Collections.Generic.List[string]
function Add-Report {
    # Every report line is redacted, so an exception message or an MSI log line
    # that quotes the installer path cannot put the token into the portal.
    param([string]$Text)
    $script:Report.Add((Protect-InstallerName -Text $Text -Literal (Get-RedactionList -Settings $Config) -Pattern @($Config.RedactPatterns)))
}

function Get-AgentService {
    param([hashtable]$Settings)
    $found = @(Get-Service -Name $Settings.ServiceNames -ErrorAction SilentlyContinue)
    if ($Settings.ExcludeServicePattern) {
        $found = @($found | Where-Object { $_.Name -notmatch $Settings.ExcludeServicePattern })
    }
    return $found
}

function Test-AgentHealthy {
    param(
        [AllowEmptyCollection()][object[]]$Service,
        [int]$MinimumServiceCount = 1
    )
    if ($null -eq $Service -or @($Service).Count -lt $MinimumServiceCount) { return $false }
    $notRunning = @($Service | Where-Object { [string]$_.Status -ne 'Running' })
    return ($notRunning.Count -eq 0)
}

function Format-ServiceState {
    param([AllowEmptyCollection()][object[]]$Service)
    if (-not $Service -or @($Service).Count -eq 0) { return 'none' }
    return (($Service | ForEach-Object { '{0}={1}' -f $_.Name, $_.Status }) -join ' ')
}

function Test-NameInScope {
    # Pure: is this display name in the rebuild scope?
    param([string]$Name, [string]$IncludePattern, [string]$ExcludePattern)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -notmatch $IncludePattern) { return $false }
    if ($ExcludePattern -and ($Name -match $ExcludePattern)) { return $false }
    return $true
}

function Test-SafeRemovalPath {
    # Pure: only allow deleting folders at least two levels below Program Files,
    # Program Files (x86) or ProgramData. Guards against a config typo like 'C:\'.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { return $false }
    if ($Path -match '\.\.') { return $false }
    $full = $Path.TrimEnd('\')
    $roots = @('C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData')
    foreach ($r in $roots) {
        if ($full.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $rest = $full.Substring($r.Length + 1)
            if (@($rest.Split('\') | Where-Object { $_ }).Count -ge 2) { return $true }
        }
    }
    return $false
}

function Test-InstallerIntegrity {
    # Returns a result object; never throws for a mismatch.
    param(
        [string]$Path,
        [string]$ExpectedSha256,
        [string]$ExpectedSignerSubject,
        [AllowEmptyCollection()][string[]]$ExpectedSignerThumbprint = @(),
        [long]$MinimumBytes
    )
    $r = [ordered]@{ Ok = $false; Detail = '' }
    if (-not (Test-Path -LiteralPath $Path)) { $r.Detail = 'file missing'; return [pscustomobject]$r }
    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -lt $MinimumBytes) { $r.Detail = "too small ($len bytes), probably an error page"; return [pscustomobject]$r }
    $thumbs = @($ExpectedSignerThumbprint | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ($_ -replace '\s', '').ToUpperInvariant() })
    $wantSubject = -not [string]::IsNullOrWhiteSpace($ExpectedSignerSubject)
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256) -and -not $wantSubject -and $thumbs.Count -eq 0) {
        $r.Detail = 'no ExpectedSha256, ExpectedSignerSubject or ExpectedSignerThumbprint configured; refusing to install an unverified download'
        return [pscustomobject]$r
    }
    $checks = @()
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if ($actual -ne $ExpectedSha256.Trim().ToUpperInvariant()) {
            $r.Detail = "SHA256 mismatch (got $actual)"
            return [pscustomobject]$r
        }
        $checks += 'sha256 ok'
    }
    if ($wantSubject -or $thumbs.Count) {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
        if ($sig.Status -ne 'Valid') { $r.Detail = "signature status $($sig.Status)"; return [pscustomobject]$r }
        $subject = [string]$sig.SignerCertificate.Subject
        # Exact comparison: a wildcard such as '*O=Contoso Ltd*' would also accept 'O=Contoso Ltd Evil'.
        if ($wantSubject -and ($subject -ne $ExpectedSignerSubject.Trim())) { $r.Detail = "unexpected signer: $subject"; return [pscustomobject]$r }
        if ($thumbs.Count -and ($thumbs -notcontains ([string]$sig.SignerCertificate.Thumbprint).ToUpperInvariant())) {
            $r.Detail = "unexpected signer thumbprint: $($sig.SignerCertificate.Thumbprint)"
            return [pscustomobject]$r
        }
        $checks += 'signature ok'
    }
    $r.Ok = $true
    $r.Detail = ($checks -join ', ') + " ($len bytes)"
    return [pscustomobject]$r
}

# region PrivateFolder
function Test-TrustedFolderState {
    # Pure: '' when the state is safe for SYSTEM to run files from, else the reason.
    # Rule objects need Sid and Type (Allow or Deny).
    param(
        [string]$OwnerSid,
        [AllowEmptyCollection()][object[]]$Rule = @(),
        [bool]$Protected,
        [bool]$IsReparsePoint
    )
    $trusted = @('S-1-5-18', 'S-1-5-32-544')
    if ($IsReparsePoint) { return 'it is a reparse point (junction or symbolic link)' }
    if ($trusted -notcontains $OwnerSid) { return "owner $OwnerSid is not SYSTEM or Administrators" }
    if (-not $Protected) { return 'it still inherits permissions from its parent' }
    foreach ($r in $Rule) {
        if ([string]$r.Type -eq 'Allow' -and $trusted -notcontains [string]$r.Sid) { return "its ACL allows $($r.Sid)" }
    }
    return ''
}

function Get-FolderState {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    $acl = Get-Acl -LiteralPath $Path
    $sidType = [System.Security.Principal.SecurityIdentifier]
    $rules = @($acl.GetAccessRules($true, $true, $sidType) | ForEach-Object {
            [pscustomobject]@{ Sid = $_.IdentityReference.Value; Type = [string]$_.AccessControlType }
        })
    return [pscustomobject]@{
        OwnerSid       = $acl.GetOwner($sidType).Value
        Rule           = $rules
        Protected      = [bool]$acl.AreAccessRulesProtected
        IsReparsePoint = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    }
}

function New-PrivateFolder {
    param([Parameter(Mandatory = $true)][string]$Path)
    $parent = Split-Path -Parent $Path
    while ($parent) {
        if (Test-Path -LiteralPath $parent) {
            if ((Get-Item -LiteralPath $parent -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Refusing $Path : parent $parent is a junction or symbolic link"
            }
        }
        $next = Split-Path -Parent $parent
        if (-not $next -or $next -eq $parent) { break }
        $parent = $next
    }
    if (Test-Path -LiteralPath $Path) {
        $s = Get-FolderState -Path $Path
        if ($s.IsReparsePoint) { throw "Refusing $Path : it is a junction or symbolic link" }
        if (@('S-1-5-18', 'S-1-5-32-544') -notcontains $s.OwnerSid) {
            throw "Refusing $Path : it already exists and is owned by $($s.OwnerSid), not SYSTEM or Administrators. Check who created it before removing it."
        }
    }
    else {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    & icacls.exe $Path /setowner '*S-1-5-32-544' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls /setowner failed on $Path (exit $LASTEXITCODE)" }
    & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $Path (exit $LASTEXITCODE)" }
    $s = Get-FolderState -Path $Path
    $why = Test-TrustedFolderState -OwnerSid $s.OwnerSid -Rule $s.Rule -Protected $s.Protected -IsReparsePoint $s.IsReparsePoint
    if ($why) { throw "Work folder $Path did not verify: $why" }
}
# endregion PrivateFolder

function Select-InstallerRegistrationTarget {
    # Pure: from an inventory (live or faked), pick the Features keys and the
    # UpgradeCodes values that belong to the packed product codes in scope.
    #   FeatureKey        subkey names under Classes\Installer\Features
    #   UpgradeCodeValue  hashtable: packed upgrade code -> value names under it
    #                     (each value name is a packed product code)
    param(
        [AllowEmptyCollection()][string[]]$PackedCode = @(),
        [AllowEmptyCollection()][string[]]$FeatureKey = @(),
        [hashtable]$UpgradeCodeValue = @{}
    )
    $codes = @($PackedCode | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in $FeatureKey) {
        if ($f -and ($codes -contains $f.ToUpperInvariant())) {
            $out.Add([pscustomobject]@{ Kind = 'InstallerFeatures'; Key = $f; ValueName = '' })
        }
    }
    foreach ($u in @($UpgradeCodeValue.Keys)) {
        foreach ($v in @($UpgradeCodeValue[$u])) {
            if ($v -and ($codes -contains ([string]$v).ToUpperInvariant())) {
                $out.Add([pscustomobject]@{ Kind = 'UpgradeCodeValue'; Key = [string]$u; ValueName = [string]$v })
            }
        }
    }
    return $out
}

function Get-StaleRegistration {
    # Read-only inventory of everything Stage 2 would purge.
    param([hashtable]$Settings)
    $items = New-Object System.Collections.Generic.List[object]
    $arpRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $productCodes = New-Object System.Collections.Generic.List[string]
    foreach ($root in $arpRoots) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($p -and (Test-NameInScope -Name $p.DisplayName -IncludePattern $Settings.ProductNamePattern -ExcludePattern $Settings.ExcludeNamePattern)) {
                $isMsi = $key.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$'
                if ($isMsi) { $productCodes.Add($key.PSChildName.ToUpperInvariant()) }
                $items.Add([pscustomobject]@{ Kind = 'ARP'; Path = $key.PSPath; RegName = $key.Name; ValueName = ''; Label = "$($p.DisplayName) v$($p.DisplayVersion)"; ProductCode = $(if ($isMsi) { $key.PSChildName } else { '' }) })
            }
        }
    }
    $packedFromArp = @($productCodes | ForEach-Object { ConvertTo-PackedGuid -Guid $_ })
    $packedInScope = New-Object System.Collections.Generic.List[string]
    foreach ($c in $packedFromArp) { $packedInScope.Add($c) }
    foreach ($key in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Classes\Installer\Products' -ErrorAction SilentlyContinue)) {
        $name = (Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue).ProductName
        $byName = Test-NameInScope -Name $name -IncludePattern $Settings.ProductNamePattern -ExcludePattern $Settings.ExcludeNamePattern
        $byCode = $packedFromArp -contains $key.PSChildName.ToUpperInvariant()
        if ($byName -or $byCode) {
            $items.Add([pscustomobject]@{ Kind = 'InstallerProducts'; Path = $key.PSPath; RegName = $key.Name; ValueName = ''; Label = "$name [$($key.PSChildName)]"; ProductCode = '' })
            if (-not $packedInScope.Contains($key.PSChildName.ToUpperInvariant())) { $packedInScope.Add($key.PSChildName.ToUpperInvariant()) }
        }
    }
    foreach ($sid in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData' -ErrorAction SilentlyContinue)) {
        foreach ($prod in @(Get-ChildItem -LiteralPath (Join-Path $sid.PSPath 'Products') -ErrorAction SilentlyContinue)) {
            $ip = Get-ItemProperty -LiteralPath (Join-Path $prod.PSPath 'InstallProperties') -ErrorAction SilentlyContinue
            $byName = $ip -and (Test-NameInScope -Name $ip.DisplayName -IncludePattern $Settings.ProductNamePattern -ExcludePattern $Settings.ExcludeNamePattern)
            $byCode = $packedInScope.Contains($prod.PSChildName.ToUpperInvariant())
            if ($byName -or $byCode) {
                $items.Add([pscustomobject]@{ Kind = 'UserData'; Path = $prod.PSPath; RegName = $prod.Name; ValueName = ''; Label = "$($sid.PSChildName)\$($prod.PSChildName)"; ProductCode = '' })
            }
        }
    }

    # Features and UpgradeCodes, by packed product code.
    $featRoot = 'HKLM:\SOFTWARE\Classes\Installer\Features'
    $upRoot = 'HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes'
    $featKeys = @($packedInScope | Where-Object { Test-Path -LiteralPath (Join-Path $featRoot $_) })
    $upValues = @{}
    foreach ($uk in @(Get-ChildItem -LiteralPath $upRoot -ErrorAction SilentlyContinue)) {
        $upValues[$uk.PSChildName] = @($uk.GetValueNames())
    }
    foreach ($t in @(Select-InstallerRegistrationTarget -PackedCode $packedInScope.ToArray() -FeatureKey $featKeys -UpgradeCodeValue $upValues)) {
        if ($t.Kind -eq 'InstallerFeatures') {
            $items.Add([pscustomobject]@{ Kind = $t.Kind; Path = (Join-Path $featRoot $t.Key); RegName = ('HKEY_LOCAL_MACHINE\SOFTWARE\Classes\Installer\Features\' + $t.Key); ValueName = ''; Label = "[$($t.Key)]"; ProductCode = '' })
        }
        else {
            $items.Add([pscustomobject]@{ Kind = $t.Kind; Path = (Join-Path $upRoot $t.Key); RegName = ('HKEY_LOCAL_MACHINE\SOFTWARE\Classes\Installer\UpgradeCodes\' + $t.Key); ValueName = $t.ValueName; Label = "[$($t.Key)] value $($t.ValueName)"; ProductCode = '' })
        }
    }
    return $items
}

function Remove-RegistryKeyWithBackup {
    # Exports the key to a .reg file, then deletes the key (or, for an item with a
    # ValueName, only that value) and reads it back.
    param([object]$Item, [string]$BackupFolder)
    $safe = ($Item.Kind + '_' + (($Item.RegName + '_' + $Item.ValueName) -replace '[^A-Za-z0-9]', '_'))
    if ($safe.Length -gt 120) { $safe = $safe.Substring($safe.Length - 120) }
    $backup = Join-Path $BackupFolder ($safe + '.reg')
    & reg.exe export $Item.RegName $backup /y 2>&1 | Out-Null
    $backedUp = ($LASTEXITCODE -eq 0)
    if (-not $backedUp) { return "SKIP $($Item.Kind) $($Item.Label): backup failed, key left in place" }
    if ($Item.ValueName) {
        Remove-ItemProperty -LiteralPath $Item.Path -Name $Item.ValueName -Force -ErrorAction SilentlyContinue
        $key = Get-Item -LiteralPath $Item.Path -ErrorAction SilentlyContinue
        $gone = -not ($key -and (@($key.GetValueNames()) -contains $Item.ValueName))
    }
    else {
        Remove-Item -LiteralPath $Item.Path -Recurse -Force -ErrorAction SilentlyContinue
        $gone = -not (Test-Path -LiteralPath $Item.Path)
    }
    return ('PURGED {0} {1}: {2}' -f $Item.Kind, $Item.Label, $(if ($gone) { 'verified gone' } else { 'STILL PRESENT' }))
}

function Invoke-Msiexec {
    param([string]$Arguments)
    $msiexec = Join-Path $env:WINDIR 'System32\msiexec.exe'
    $p = Start-Process -FilePath $msiexec -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    return $p.ExitCode
}

function Wait-AgentRunning {
    param([hashtable]$Settings, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $svc = Get-AgentService -Settings $Settings
        if (Test-AgentHealthy -Service $svc -MinimumServiceCount $Settings.MinimumServiceCount) { return $svc }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    return (Get-AgentService -Settings $Settings)
}

function Get-MsiLogClue {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'no MSI log' }
    $hits = @(Select-String -LiteralPath $Path -Pattern 'Return value 3', 'returned actual error', 'Error 1722', 'Error 1603', 'Error 1920', 'Error 1921' -ErrorAction SilentlyContinue |
        Select-Object -First 4 | ForEach-Object { $_.Line.Trim() })
    if ($hits.Count) { return ($hits -join ' ;; ') }
    return 'no error lines matched in MSI log'
}

function Invoke-SelfHeal {
    # Returns the exit code as its last output. Report lines go to $script:Report.
    param([bool]$DoApply)
    $mode = if ($DoApply) { 'APPLY' } else { 'DRY-RUN (no changes)' }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    # The verbose MSI log and the transcript stay in the private work folder: a
    # verbose MSI log records the package path, and with it the tokenized file name.
    $transcript = Join-Path $Config.WorkFolder ($Config.LogPrefix + '.log')
    $msiLog = Join-Path $Config.WorkFolder ($Config.LogPrefix + '_msi_' + $stamp + '.log')
    $stagedLog = Join-Path $Config.ImeLogs ($Config.LogPrefix + '_msi_' + $stamp + '_redacted.log')
    $exitCode = 1
    $transcribing = $false
    try {
        Add-Report "MODE: $mode"

        # Stage 0: healthy, touch nothing.
        $svc = Get-AgentService -Settings $Config
        if (Test-AgentHealthy -Service $svc -MinimumServiceCount $Config.MinimumServiceCount) {
            Add-Report ('HEALTHY: ' + (Format-ServiceState -Service $svc) + ' NOTHING TOUCHED')
            return 0
        }

        # Stage 1: start what is stopped, unless something disabled it on purpose.
        if ($svc.Count -gt 0) {
            $disabled = @($svc | Where-Object { [string]$_.StartType -eq 'Disabled' })
            if ($disabled.Count) {
                Add-Report ('DISABLED: ' + (($disabled | ForEach-Object { $_.Name }) -join ', ') + '. Not overriding a deliberate disable; fix the cause and re-run.')
                return 1
            }
            $stopped = @($svc | Where-Object { [string]$_.Status -ne 'Running' })
            if ($svc.Count -ge $Config.MinimumServiceCount -and $stopped.Count) {
                if ($DoApply) {
                    foreach ($s in $stopped) { Start-Service -Name $s.Name -ErrorAction SilentlyContinue }
                    $svc = Wait-AgentRunning -Settings $Config -TimeoutSeconds $Config.ServiceStartWaitSeconds
                    if (Test-AgentHealthy -Service $svc -MinimumServiceCount $Config.MinimumServiceCount) {
                        Add-Report ('STARTED: ' + (Format-ServiceState -Service $svc))
                        return 0
                    }
                    Add-Report ('STARTFAIL: ' + (Format-ServiceState -Service $svc) + ', rebuilding')
                }
                else {
                    Add-Report ('WOULD start: ' + (($stopped | ForEach-Object { $_.Name }) -join ', ') + ', then rebuild only if they do not stay Running')
                }
            }
            else {
                Add-Report ('PARTIAL: ' + (Format-ServiceState -Service $svc) + " (need $($Config.MinimumServiceCount)), rebuilding")
            }
        }
        else {
            Add-Report 'MISSING: no agent services, rebuilding'
        }

        # Stage 2: rebuild.
        $stale = @(Get-StaleRegistration -Settings $Config)
        $codes = @($stale | Where-Object { $_.ProductCode } | ForEach-Object { $_.ProductCode } | Select-Object -Unique)
        if (-not $DoApply) {
            foreach ($c in $codes) { Add-Report "WOULD msiexec /x $c" }
            foreach ($i in $stale) { Add-Report ('WOULD purge {0}: {1} (after .reg backup)' -f $i.Kind, $i.Label) }
            foreach ($s in $svc) { Add-Report "WOULD stop and delete service $($s.Name)" }
            foreach ($f in $Config.InstallFolders) {
                if (Test-Path -LiteralPath $f) {
                    $ok = Test-SafeRemovalPath -Path $f
                    Add-Report $(if ($ok) { "WOULD delete folder $f" } else { "REFUSE to delete folder $f (outside allowed roots)" })
                }
            }
            Add-Report "WOULD create or check the private work folder $($Config.WorkFolder) (owner, ACL and junction checks, read back)"
            Add-Report "WOULD download the vendor MSI under its configured file name (not printed), verify it, install with a verbose log in the work folder, wait up to $($Config.PostInstallWaitSeconds)s for services"
            return 0
        }

        New-PrivateFolder -Path $Config.WorkFolder
        Start-Transcript -Path $transcript -Append -Force | Out-Null
        $transcribing = $true
        $backupFolder = Join-Path $Config.WorkFolder ('regbackup-' + $stamp)
        New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null

        foreach ($c in $codes) {
            $code = Invoke-Msiexec -Arguments "/x $c /qn /norestart REBOOT=ReallySuppress"
            $known = @(0, 1605, 1614, 1641, 3010) -contains $code
            Add-Report ("UNINSTALL $c exit $code" + $(if ($known) { '' } else { ' (forcing cleanup)' }))
        }
        # Re-inventory: a clean uninstall removes most keys on its own.
        foreach ($i in @(Get-StaleRegistration -Settings $Config)) {
            Add-Report (Remove-RegistryKeyWithBackup -Item $i -BackupFolder $backupFolder)
        }
        foreach ($s in @(Get-AgentService -Settings $Config)) {
            Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
            & sc.exe delete $s.Name | Out-Null
            $still = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
            Add-Report ("SVCDEL $($s.Name): " + $(if ($still) { 'STILL PRESENT (marked for delete, may need reboot)' } else { 'verified gone' }))
        }
        foreach ($f in $Config.InstallFolders) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            if (-not (Test-SafeRemovalPath -Path $f)) { Add-Report "REFUSE folder $f (outside allowed roots)"; continue }
            Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($f + '\', [System.StringComparison]::OrdinalIgnoreCase) } |
                Stop-Process -Force -ErrorAction SilentlyContinue
            # rd /s removes a junction inside the folder without following it, so a link a
            # user planted in a vendor folder cannot point this SYSTEM delete somewhere else.
            & cmd.exe /d /c rd /s /q "$f" 2>&1 | Out-Null
            Add-Report ("DELDIR $(Split-Path $f -Leaf): " + $(if (Test-Path -LiteralPath $f) { 'STILL PRESENT' } else { 'verified gone' }))
        }

        # Download under the vendor's own file name, then verify before running anything.
        $installer = Join-Path $Config.WorkFolder $Config.InstallerFileName
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $installer) {
            Add-Report 'STALE INSTALLER: an old copy in the work folder could not be removed'
            return 1
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        # The progress bar makes large downloads many times slower in Windows PowerShell 5.1.
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $Config.InstallerUrl -OutFile $installer -UseBasicParsing -TimeoutSec 600
        }
        catch {
            Add-Report ('DLFAIL: ' + $_.Exception.Message)
            return 1
        }
        finally {
            $ProgressPreference = $oldProgress
        }
        $check = Test-InstallerIntegrity -Path $installer -ExpectedSha256 $Config.ExpectedSha256 -ExpectedSignerSubject $Config.ExpectedSignerSubject -ExpectedSignerThumbprint @($Config.ExpectedSignerThumbprint) -MinimumBytes $Config.MinimumInstallerBytes
        if (-not $check.Ok) {
            Add-Report ('VERIFY FAIL: ' + $check.Detail)
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
            return 1
        }
        Add-Report ('VERIFY: ' + $check.Detail)

        $code = Invoke-Msiexec -Arguments ('/i "' + $installer + '" ' + $Config.MsiArguments + ' /L*v "' + $msiLog + '"')
        Add-Report "MSIEXEC exit $code"
        if ($Config.StageRedactedMsiLog) {
            $staged = Copy-RedactedLog -Source $msiLog -Destination $stagedLog -Literal (Get-RedactionList -Settings $Config) -Pattern @($Config.RedactPatterns)
            Add-Report $(if ($staged) { 'MSILOG: redacted copy staged in IME Logs' } else { 'MSILOG: no verbose log to stage' })
        }

        $svc = Wait-AgentRunning -Settings $Config -TimeoutSeconds $Config.PostInstallWaitSeconds
        if (Test-AgentHealthy -Service $svc -MinimumServiceCount $Config.MinimumServiceCount) {
            Add-Report ('REBUILT: ' + (Format-ServiceState -Service $svc))
            $exitCode = 0
        }
        else {
            Add-Report ('NOT HEALTHY AFTER INSTALL: ' + (Format-ServiceState -Service $svc))
            Add-Report ('MSILOG: ' + (Get-MsiLogClue -Path $msiLog))
            $exitCode = 1
        }
    }
    catch {
        Add-Report ('ERROR: ' + $_.Exception.Message)
        $exitCode = 1
    }
    finally {
        if ($transcribing) { Stop-Transcript | Out-Null }
    }
    return $exitCode
}

if ($MyInvocation.InvocationName -ne '.') {
    # region Ensure64Bit
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $ps64 = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $ps64) {
            $relaunch = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
            foreach ($entry in $PSBoundParameters.GetEnumerator()) {
                if ($entry.Value -is [System.Management.Automation.SwitchParameter]) {
                    if ($entry.Value.IsPresent) { $relaunch += ('-' + $entry.Key) }
                }
                else {
                    $relaunch += ('-' + $entry.Key)
                    $relaunch += [string]$entry.Value
                }
            }
            & $ps64 @relaunch
            exit $LASTEXITCODE
        }
        Write-Output 'ERROR: running in a 32-bit host and the sysnative path is missing. Set "Run script in 64-bit PowerShell" to Yes.'
        exit 1
    }
    # endregion Ensure64Bit
    $result = @(Invoke-SelfHeal -DoApply ($Apply.IsPresent -or [bool]$Config.ApplyWhenNoParameter))
    Write-Output (Format-RemediationOutput -Part $script:Report)
    exit ([int]$result[-1])
}
