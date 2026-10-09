# MsiTools: small, scriptable MSI database edits through the WindowsInstaller COM object,
# plus a reader for the metadata IntuneWinAppUtil writes into a .intunewin.
#
# Pattern status: [built, ran on real tickets]. I did each of these by hand at a
# PowerShell prompt during packaging work in 2026 (an ALLUSERS fix on a patch
# agent MSI, an MST that removed a failing vendor custom action, reading
# Detection.xml to confirm the execution context). This module is a fresh
# rewrite of those steps into functions, generalized from what I ran at work and
# tested against a synthetic MSI that the test suite builds from scratch. No
# vendor MSI is included or needed.
#
# Safety rules built in:
#   - The source MSI is never modified. Edits go to a copy (-OutputPath) or a temp copy.
#   - Nothing is written without -Apply. Without it you get a report of what would change.
#   - Every write is read back from disk and the result says whether it verified.
#   - Values go into SQL through MSI record parameters, never string concatenation.
#
# Editing an MSI invalidates the vendor's Authenticode signature. Set-MsiProperty
# reports the signature status before and after so that is never a surprise. For
# changes that only matter at install time, a transform (.mst) is the cleaner fix
# where the vendor supports it, because the original MSI stays signed and
# untouched. A transform does not help when a tool reads the MSI itself:
# IntuneWinAppUtil records MsiExecutionContext from the MSI, not from an MST.
#
# COM calls go through reflection (InvokeMember) because that behaves the same in
# Windows PowerShell 5.1 and PowerShell 7. Every write commits, releases its
# handles and is read back from the file on disk; the tests do exactly that
# against a synthetic MSI.

Set-StrictMode -Version 2

$script:ModeReadOnly = 0
$script:ModeTransact = 1

function Invoke-ComMethod {
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Name, [object[]]$Arguments = @())
    return $Object.GetType().InvokeMember($Name, [System.Reflection.BindingFlags]::InvokeMethod, $null, $Object, $Arguments)
}

function Get-ComProperty {
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Name, [object[]]$Arguments = @())
    return $Object.GetType().InvokeMember($Name, [System.Reflection.BindingFlags]::GetProperty, $null, $Object, $Arguments)
}

function Set-ComProperty {
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Name, [object[]]$Arguments = @())
    [void]$Object.GetType().InvokeMember($Name, [System.Reflection.BindingFlags]::SetProperty, $null, $Object, $Arguments)
}

function Close-ComObject {
    param($Object)
    if ($null -ne $Object -and [System.Runtime.InteropServices.Marshal]::IsComObject($Object)) {
        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($Object)
    }
}

function Clear-ComHandle {
    # Windows Installer keeps the file open until every COM reference is gone.
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

function Get-MsiInstaller {
    return (New-Object -ComObject WindowsInstaller.Installer)
}

function Open-MsiDatabase {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$Mode = 0)
    $installer = Get-MsiInstaller
    return (Invoke-ComMethod -Object $installer -Name 'OpenDatabase' -Arguments @($Path, $Mode))
}

function Invoke-MsiSql {
    # Runs one statement. Returns rows (as string arrays) when ColumnCount > 0.
    param(
        [Parameter(Mandatory = $true)]$Database,
        [Parameter(Mandatory = $true)][string]$Sql,
        [object[]]$Parameter = @(),
        [int]$ColumnCount = 0
    )
    $view = $null
    $record = $null
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        $view = Invoke-ComMethod -Object $Database -Name 'OpenView' -Arguments @($Sql)
        if ($Parameter.Count -gt 0) {
            $record = Invoke-ComMethod -Object (Get-MsiInstaller) -Name 'CreateRecord' -Arguments @($Parameter.Count)
            for ($i = 0; $i -lt $Parameter.Count; $i++) {
                if ($Parameter[$i] -is [int]) { Set-ComProperty -Object $record -Name 'IntegerData' -Arguments @(($i + 1), $Parameter[$i]) }
                else { Set-ComProperty -Object $record -Name 'StringData' -Arguments @(($i + 1), [string]$Parameter[$i]) }
            }
            [void](Invoke-ComMethod -Object $view -Name 'Execute' -Arguments @($record))
        }
        else {
            [void](Invoke-ComMethod -Object $view -Name 'Execute')
        }
        if ($ColumnCount -gt 0) {
            while ($true) {
                $r = Invoke-ComMethod -Object $view -Name 'Fetch'
                if ($null -eq $r) { break }
                $vals = New-Object string[] $ColumnCount
                for ($c = 1; $c -le $ColumnCount; $c++) { $vals[$c - 1] = [string](Get-ComProperty -Object $r -Name 'StringData' -Arguments @($c)) }
                $rows.Add($vals)
                Close-ComObject $r
            }
        }
        [void](Invoke-ComMethod -Object $view -Name 'Close')
    }
    finally {
        Close-ComObject $record
        Close-ComObject $view
    }
    return , $rows.ToArray()
}

function Assert-Identifier {
    param([string]$Value, [string]$What)
    if ($Value -notmatch '^[A-Za-z_][A-Za-z0-9_.]{0,71}$') { throw "$What '$Value' is not a valid MSI identifier" }
}

function Get-FullPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Get-SignatureStatus {
    param([string]$Path)
    try { return [string](Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop).Status } catch { return 'Unknown' }
}

function Get-MsiProperty {
    <#
    .SYNOPSIS
        Reads the Property table of an MSI (read-only).
    .EXAMPLE
        Get-MsiProperty -Path .\agent.msi -Name ALLUSERS
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Name
    )
    $full = Get-FullPath $Path
    if (-not (Test-Path -LiteralPath $full)) { throw "Not found: $full" }
    $db = Open-MsiDatabase -Path $full -Mode $script:ModeReadOnly
    try {
        if ($Name) {
            Assert-Identifier -Value $Name -What 'Property'
            $rows = Invoke-MsiSql -Database $db -Sql 'SELECT `Property`, `Value` FROM `Property` WHERE `Property` = ?' -Parameter @($Name) -ColumnCount 2
        }
        else {
            $rows = Invoke-MsiSql -Database $db -Sql 'SELECT `Property`, `Value` FROM `Property`' -ColumnCount 2
        }
        foreach ($row in $rows) { [pscustomobject]@{ Property = $row[0]; Value = $row[1] } }
    }
    finally {
        Close-ComObject $db
        Clear-ComHandle
    }
}

function Set-MsiProperty {
    <#
    .SYNOPSIS
        Inserts or updates one Property table row in a COPY of an MSI, then reads it back.
    .DESCRIPTION
        The case that made me write this: a vendor patch agent MSI had no ALLUSERS
        property. IntuneWinAppUtil recorded MsiExecutionContext=User in the package
        metadata and Intune installed it per user. Adding ALLUSERS=1 to a copy and
        re-wrapping flipped the recorded context to System, on the second attempt;
        the first re-wrapped package still said User. Read Detection.xml back
        (Get-IntuneWinMetadata) before you trust the edit.

        Without -Apply nothing is written; the result shows Before, the intended
        value and the action that would run.
    .EXAMPLE
        Set-MsiProperty -Path .\vendor.msi -Name ALLUSERS -Value 1 -OutputPath .\out\vendor.msi
        Set-MsiProperty -Path .\vendor.msi -Name ALLUSERS -Value 1 -OutputPath .\out\vendor.msi -Apply
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [switch]$Force,
        [switch]$Apply
    )
    Assert-Identifier -Value $Name -What 'Property'
    $src = Get-FullPath $Path
    $dst = Get-FullPath $OutputPath
    if (-not (Test-Path -LiteralPath $src)) { throw "Not found: $src" }
    if ($src -ieq $dst) { throw 'OutputPath must differ from Path. The source MSI is never modified.' }
    if ([string]::IsNullOrEmpty($Value)) { throw 'An empty Value would delete the property in Windows Installer terms; refusing.' }

    $before = Get-MsiProperty -Path $src -Name $Name
    $beforeValue = if ($before) { $before.Value } else { $null }
    $action = if ($null -eq $beforeValue) { 'Insert' } elseif ($beforeValue -ceq $Value) { 'NoChange' } else { 'Update' }
    $result = [ordered]@{
        Source          = $src
        Output          = $dst
        Property        = $Name
        Before          = $beforeValue
        Requested       = $Value
        Action          = $action
        Applied         = $false
        ReadBack        = $null
        Verified        = $false
        SourceSignature = Get-SignatureStatus -Path $src
        OutputSignature = $null
    }
    if (-not $Apply) {
        $result.Action = 'Would' + $action
        return [pscustomobject]$result
    }
    if ((Test-Path -LiteralPath $dst) -and -not $Force) { throw "OutputPath exists: $dst (use -Force to overwrite)" }
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    Set-ItemProperty -LiteralPath $dst -Name IsReadOnly -Value $false

    if ($action -ne 'NoChange') {
        $db = Open-MsiDatabase -Path $dst -Mode $script:ModeTransact
        try {
            if ($action -eq 'Insert') {
                [void](Invoke-MsiSql -Database $db -Sql 'INSERT INTO `Property` (`Property`, `Value`) VALUES (?, ?)' -Parameter @($Name, $Value))
            }
            else {
                [void](Invoke-MsiSql -Database $db -Sql 'UPDATE `Property` SET `Value` = ? WHERE `Property` = ?' -Parameter @($Value, $Name))
            }
            [void](Invoke-ComMethod -Object $db -Name 'Commit')
        }
        finally {
            Close-ComObject $db
            Clear-ComHandle
        }
    }
    $after = Get-MsiProperty -Path $dst -Name $Name
    $result.Applied = $true
    $result.ReadBack = if ($after) { $after.Value } else { $null }
    $result.Verified = ($result.ReadBack -ceq $Value)
    $result.OutputSignature = Get-SignatureStatus -Path $dst
    return [pscustomobject]$result
}

function Get-MsiSequence {
    <#
    .SYNOPSIS
        Lists the rows of a sequence table (InstallExecuteSequence by default), ordered by Sequence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('InstallExecuteSequence', 'InstallUISequence', 'AdminExecuteSequence', 'AdminUISequence', 'AdvtExecuteSequence')]
        [string]$Table = 'InstallExecuteSequence'
    )
    $full = Get-FullPath $Path
    $db = Open-MsiDatabase -Path $full -Mode $script:ModeReadOnly
    try {
        $sql = 'SELECT `Action`, `Condition`, `Sequence` FROM `{0}`' -f $Table
        $rows = Invoke-MsiSql -Database $db -Sql $sql -ColumnCount 3
        $rows | ForEach-Object { [pscustomobject]@{ Table = $Table; Action = $_[0]; Condition = $_[1]; Sequence = [int]("0" + $_[2]) } } | Sort-Object Sequence
    }
    finally {
        Close-ComObject $db
        Clear-ComHandle
    }
}

function Test-MsiActionPresent {
    param($Database, [string]$Table, [string]$Action)
    $sql = 'SELECT `Action` FROM `{0}` WHERE `Action` = ?' -f $Table
    $rows = Invoke-MsiSql -Database $Database -Sql $sql -Parameter @($Action) -ColumnCount 1
    return ($rows.Count -gt 0)
}

function Test-MsiTransform {
    <#
    .SYNOPSIS
        Applies a transform to a throwaway copy of the MSI and reports whether the named actions are present before and after.
    .DESCRIPTION
        Read-only with respect to your files: the MSI is copied to a temp folder,
        the transform is applied in memory, nothing is committed, and the copy is deleted.
    .EXAMPLE
        Test-MsiTransform -Path .\vendor.msi -TransformPath .\skip-check.mst -Action ExampleDiskCheckAction
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TransformPath,
        [Parameter(Mandatory = $true)][string[]]$Action,
        [string[]]$Table = @('InstallExecuteSequence', 'InstallUISequence')
    )
    foreach ($a in $Action) { Assert-Identifier -Value $a -What 'Action' }
    $src = Get-FullPath $Path
    $mst = Get-FullPath $TransformPath
    if (-not (Test-Path -LiteralPath $mst)) { throw "Transform not found: $mst" }
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('msi-verify-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $tmp = Join-Path $tmpDir 'verify.msi'
    Copy-Item -LiteralPath $src -Destination $tmp -Force
    Set-ItemProperty -LiteralPath $tmp -Name IsReadOnly -Value $false
    $rows = New-Object System.Collections.Generic.List[object]
    $db = $null
    try {
        $db = Open-MsiDatabase -Path $tmp -Mode $script:ModeTransact
        $tables = New-Object System.Collections.Generic.List[string]
        foreach ($candidate in $Table) {
            $hit = Invoke-MsiSql -Database $db -Sql 'SELECT `Name` FROM `_Tables` WHERE `Name` = ?' -Parameter @($candidate) -ColumnCount 1
            if ($hit.Count -gt 0) { $tables.Add($candidate) }
        }
        $before = @{}
        foreach ($t in $tables) { foreach ($a in $Action) { $before["$t|$a"] = Test-MsiActionPresent -Database $db -Table $t -Action $a } }
        [void](Invoke-ComMethod -Object $db -Name 'ApplyTransform' -Arguments @($mst, 0))
        foreach ($t in $tables) {
            foreach ($a in $Action) {
                $rows.Add([pscustomobject]@{ Table = $t; Action = $a; PresentBefore = $before["$t|$a"]; PresentAfter = (Test-MsiActionPresent -Database $db -Table $t -Action $a) })
            }
        }
    }
    finally {
        Close-ComObject $db
        Clear-ComHandle
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $removed = @($rows | Where-Object { $_.PresentBefore -and -not $_.PresentAfter })
    $stillThere = @($rows | Where-Object { $_.PresentAfter })
    return [pscustomobject]@{
        Transform = $mst
        Rows      = $rows.ToArray()
        Removed   = $removed.Count
        Ok        = ($removed.Count -gt 0 -and $stillThere.Count -eq 0)
    }
}

function New-MsiTransformRemoveAction {
    <#
    .SYNOPSIS
        Builds an MST that deletes one or more actions from the sequence tables, then verifies it.
    .DESCRIPTION
        How it works: copy the MSI to a temp folder, delete the action rows from
        the copy, commit, then GenerateTransform(copy vs original) and
        CreateTransformSummaryInfo to write a proper .mst. The original MSI is
        opened read-only and never changes. The temp copy is deleted. The new
        transform is then checked with Test-MsiTransform.

        Install with: msiexec /i vendor.msi TRANSFORMS="skip-check.mst" /qn /L*v log.txt

        A warning from experience: removing a failing custom action can simply
        expose the next one. In my case the disk-space check went away and, per
        my notes (the raw log was not kept), a token check further down the
        sequence failed instead. The real cause turned out to be upstream of both. Treat this as a diagnostic step and a
        last resort, not a fix you ship without understanding why the action fails.
    .EXAMPLE
        New-MsiTransformRemoveAction -Path .\vendor.msi -Action ExampleDiskCheckAction -TransformPath .\skip-check.mst
        New-MsiTransformRemoveAction -Path .\vendor.msi -Action ExampleDiskCheckAction -TransformPath .\skip-check.mst -Apply
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Action,
        [Parameter(Mandatory = $true)][string]$TransformPath,
        [string[]]$Table = @('InstallExecuteSequence', 'InstallUISequence'),
        [switch]$Force,
        [switch]$Apply
    )
    foreach ($a in $Action) { Assert-Identifier -Value $a -What 'Action' }
    $src = Get-FullPath $Path
    $mst = Get-FullPath $TransformPath
    if (-not (Test-Path -LiteralPath $src)) { throw "Not found: $src" }

    $found = @()
    foreach ($t in $Table) {
        $seq = @(Get-MsiSequence -Path $src -Table $t -ErrorAction SilentlyContinue)
        $found += @($seq | Where-Object { $Action -contains $_.Action })
    }
    if ($found.Count -eq 0) { throw ('None of the actions were found in ' + ($Table -join ', ') + ': ' + ($Action -join ', ')) }

    if (-not $Apply) {
        return [pscustomobject]@{ Source = $src; Transform = $mst; WouldRemove = $found; Applied = $false; Verified = $false }
    }
    if ((Test-Path -LiteralPath $mst) -and -not $Force) { throw "TransformPath exists: $mst (use -Force to overwrite)" }
    if (Test-Path -LiteralPath $mst) { Remove-Item -LiteralPath $mst -Force }
    $mstDir = Split-Path -Parent $mst
    if (-not (Test-Path -LiteralPath $mstDir)) { New-Item -ItemType Directory -Path $mstDir -Force | Out-Null }

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('msi-transform-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $work = Join-Path $tmpDir 'modified.msi'
    Copy-Item -LiteralPath $src -Destination $work -Force
    Set-ItemProperty -LiteralPath $work -Name IsReadOnly -Value $false
    $db = $null
    $ref = $null
    $different = $false
    try {
        $db = Open-MsiDatabase -Path $work -Mode $script:ModeTransact
        foreach ($row in $found) {
            $sql = 'DELETE FROM `{0}` WHERE `Action` = ?' -f $row.Table
            [void](Invoke-MsiSql -Database $db -Sql $sql -Parameter @($row.Action))
        }
        [void](Invoke-ComMethod -Object $db -Name 'Commit')
        Close-ComObject $db
        $db = $null
        Clear-ComHandle

        $db = Open-MsiDatabase -Path $work -Mode $script:ModeReadOnly
        $ref = Open-MsiDatabase -Path $src -Mode $script:ModeReadOnly
        $different = [bool](Invoke-ComMethod -Object $db -Name 'GenerateTransform' -Arguments @($ref, $mst))
        if ($different) {
            [void](Invoke-ComMethod -Object $db -Name 'CreateTransformSummaryInfo' -Arguments @($ref, $mst, 0, 0))
        }
    }
    finally {
        Close-ComObject $db
        Close-ComObject $ref
        Clear-ComHandle
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $different) { throw 'GenerateTransform found no difference; no transform written.' }
    $check = Test-MsiTransform -Path $src -TransformPath $mst -Action ($found | ForEach-Object { $_.Action } | Select-Object -Unique) -Table $Table
    return [pscustomobject]@{
        Source    = $src
        Transform = $mst
        Removed   = $found
        Applied   = $true
        Verified  = $check.Ok
        Check     = $check.Rows
        Sha256    = (Get-FileHash -LiteralPath $mst -Algorithm SHA256).Hash
    }
}

function Get-IntuneWinMetadata {
    <#
    .SYNOPSIS
        Reads IntuneWinPackage/Metadata/Detection.xml from a .intunewin without extracting anything else.
    .DESCRIPTION
        The outer .intunewin is a zip. Its Detection.xml records what
        IntuneWinAppUtil saw in the setup file, including MsiExecutionContext
        (User, System or Any) for MSI setups. Checking this is how I proved an
        MSI edit had actually changed the install context, instead of trusting
        that the edit worked.

        EncryptionInfo holds the key material for the encrypted payload in the
        same package. It is redacted unless you pass -IncludeEncryptionInfo,
        and even then do not paste it anywhere.
    .EXAMPLE
        (Get-IntuneWinMetadata -Path .\Output\agent.intunewin).MsiInfo.MsiExecutionContext
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$IncludeEncryptionInfo
    )
    $full = Get-FullPath $Path
    if (-not (Test-Path -LiteralPath $full)) { throw "Not found: $full" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [System.IO.Compression.ZipFile]::OpenRead($full)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -replace '\\', '/' -ieq 'IntuneWinPackage/Metadata/Detection.xml' } | Select-Object -First 1
        if (-not $entry) { throw 'IntuneWinPackage/Metadata/Detection.xml not found in package' }
        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally {
        $zip.Dispose()
    }
    $xml = New-Object System.Xml.XmlDocument
    $xml.XmlResolver = $null
    $xml.LoadXml($text)
    $root = $xml.DocumentElement
    $msi = [ordered]@{}
    $msiNode = $root.SelectSingleNode('*[local-name()="MsiInfo"]')
    if ($msiNode) { foreach ($c in $msiNode.ChildNodes) { if ($c.NodeType -eq 'Element') { $msi[$c.LocalName] = $c.InnerText } } }
    $enc = [ordered]@{}
    $encNode = $root.SelectSingleNode('*[local-name()="EncryptionInfo"]')
    if ($encNode) {
        foreach ($c in $encNode.ChildNodes) {
            if ($c.NodeType -ne 'Element') { continue }
            $safe = @('ProfileIdentifier', 'FileDigestAlgorithm') -contains $c.LocalName
            $enc[$c.LocalName] = if ($IncludeEncryptionInfo -or $safe) { $c.InnerText } else { '<redacted>' }
        }
    }
    function Get-RootChildText([string]$n) { $node = $root.SelectSingleNode('*[local-name()="' + $n + '"]'); if ($node) { return $node.InnerText } return $null }
    return [pscustomobject]@{
        Package                = $full
        ToolVersion            = $root.GetAttribute('ToolVersion')
        Name                   = Get-RootChildText 'Name'
        SetupFile              = Get-RootChildText 'SetupFile'
        UnencryptedContentSize = Get-RootChildText 'UnencryptedContentSize'
        IsMsi                  = ($msi.Count -gt 0)
        MsiInfo                = [pscustomobject]$msi
        EncryptionInfo         = [pscustomobject]$enc
    }
}

Export-ModuleMember -Function Get-MsiProperty, Set-MsiProperty, Get-MsiSequence, New-MsiTransformRemoveAction, Test-MsiTransform, Get-IntuneWinMetadata
