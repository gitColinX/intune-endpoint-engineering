# Private work folder for files that SYSTEM will execute or delete.
#
# Why this exists: a remediation runs as SYSTEM. If it downloads an installer
# into a folder a standard user can write to, that user can swap the file
# between the hash check and msiexec, or plant a junction so a recursive delete
# lands somewhere else. C:\Windows\Temp is the classic mistake, and so is a new
# folder under C:\ProgramData, because BUILTIN\Users can create folders there
# and the creator owns what they create.
#
# New-PrivateFolder:
#   - refuses if any existing parent is a junction or symbolic link
#   - refuses a pre-existing folder that is a reparse point, or that is not
#     owned by SYSTEM or Administrators (someone else created it first)
#   - sets the owner to Administrators, removes inheritance, grants only SYSTEM
#     and Administrators
#   - reads owner, ACL and attributes back and throws unless they verify
# Put the folder under Program Files, where standard users cannot create
# anything, and let these checks be the second line.
#
# tests\Run-Tests.ps1 checks that every inline copy matches this file.

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
