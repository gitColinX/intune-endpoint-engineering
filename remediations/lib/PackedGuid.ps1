# Windows Installer "packed" (compressed) GUID helpers.
#
# Windows Installer does not store a product code in the registry the way you
# read it in an MSI. Under HKLM\SOFTWARE\Classes\Installer\Products and
# ...\Installer\UserData\<SID>\Products the key name is a 32-character packed
# form: the first three groups are reversed character by character, and every
# byte of the last two groups has its two hex characters swapped.
#
#   {12345678-ABCD-EF01-2345-6789ABCDEF01}  ->  87654321DCBA10FE32547698BADCFE10
#
# When msiexec /x cannot remove a broken product, these keys are what keeps
# Windows Installer believing the product is still there. You need the packed
# form to find them.
#
# The self-heal remediation carries an inline copy between the region markers.

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
