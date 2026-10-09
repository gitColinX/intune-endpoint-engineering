# Synthetic fixtures for the test suite. Everything here is made up at test time:
# no vendor MSI, no real package, no real device data.

function New-SyntheticMsi {
    # Builds a minimal MSI database from scratch with the WindowsInstaller COM
    # object: a Property table without ALLUSERS, two sequence tables holding a
    # pair of fake custom actions, and a summary information stream. It is not
    # installable and does not need to be; the MSI tools only edit and read the
    # database.
    param([Parameter(Mandatory = $true)][string]$Path)
    $bind = [System.Reflection.BindingFlags]
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.GetType().InvokeMember('OpenDatabase', $bind::InvokeMethod, $null, $installer, @($Path, 3))
    $exec = {
        param($sql)
        $v = $db.GetType().InvokeMember('OpenView', $bind::InvokeMethod, $null, $db, @($sql))
        [void]$v.GetType().InvokeMember('Execute', $bind::InvokeMethod, $null, $v, @())
        [void]$v.GetType().InvokeMember('Close', $bind::InvokeMethod, $null, $v, @())
        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($v)
    }
    & $exec 'CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` LONGCHAR NOT NULL LOCALIZABLE PRIMARY KEY `Property`)'
    & $exec 'CREATE TABLE `InstallExecuteSequence` (`Action` CHAR(72) NOT NULL, `Condition` CHAR(255), `Sequence` SHORT PRIMARY KEY `Action`)'
    & $exec 'CREATE TABLE `InstallUISequence` (`Action` CHAR(72) NOT NULL, `Condition` CHAR(255), `Sequence` SHORT PRIMARY KEY `Action`)'
    $props = [ordered]@{
        ProductCode     = '{11111111-2222-3333-4444-555555555555}'
        UpgradeCode     = '{66666666-7777-8888-9999-AAAAAAAAAAAA}'
        ProductName     = 'Synthetic Test Agent'
        ProductVersion  = '1.2.3'
        Manufacturer    = 'Example Test Vendor'
        ProductLanguage = '1033'
    }
    foreach ($k in $props.Keys) { & $exec ("INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('{0}', '{1}')" -f $k, $props[$k]) }
    $exe = [ordered]@{ CostInitialize = 800; FileCost = 900; CostFinalize = 1000; ExampleDiskCheckAction = 1100; InstallValidate = 1400; InstallInitialize = 1500; ExampleTokenCheckAction = 1550; InstallFinalize = 6600 }
    foreach ($k in $exe.Keys) { & $exec ("INSERT INTO ``InstallExecuteSequence`` (``Action``, ``Sequence``) VALUES ('{0}', {1})" -f $k, $exe[$k]) }
    $ui = [ordered]@{ CostInitialize = 800; FileCost = 900; CostFinalize = 1000; ExampleDiskCheckAction = 1050; ExecuteAction = 1300 }
    foreach ($k in $ui.Keys) { & $exec ("INSERT INTO ``InstallUISequence`` (``Action``, ``Sequence``) VALUES ('{0}', {1})" -f $k, $ui[$k]) }

    $si = $db.GetType().InvokeMember('SummaryInformation', $bind::GetProperty, $null, $db, @(20))
    $set = { param($id, $val) [void]$si.GetType().InvokeMember('Property', $bind::SetProperty, $null, $si, @($id, $val)) }
    & $set 2 'Installation Database'
    & $set 3 'Synthetic Test Agent'
    & $set 4 'Example Test Vendor'
    & $set 7 'x64;1033'
    & $set 9 '{ABCDEF01-2345-6789-ABCD-EF0123456789}'
    & $set 14 200
    & $set 15 2
    [void]$si.GetType().InvokeMember('Persist', $bind::InvokeMethod, $null, $si, @())
    [void]$db.GetType().InvokeMember('Commit', $bind::InvokeMethod, $null, $db, @())
    [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($si)
    [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($db)
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

function New-SyntheticIntuneWin {
    # A zip shaped like a .intunewin: IntuneWinPackage/Metadata/Detection.xml plus a
    # dummy payload. The encryption values are obviously fake.
    param([Parameter(Mandatory = $true)][string]$Path, [ValidateSet('User', 'System', 'Any')][string]$Context = 'System')
    $machine = if ($Context -eq 'User') { 'false' } else { 'true' }
    $user = if ($Context -eq 'User') { 'true' } else { 'false' }
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<ApplicationInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ToolVersion="1.8.7.0">
  <Name>synthetic-agent.msi</Name>
  <UnencryptedContentSize>4096</UnencryptedContentSize>
  <FileName>IntunePackage.intunewin</FileName>
  <SetupFile>synthetic-agent.msi</SetupFile>
  <EncryptionInfo>
    <EncryptionKey>FAKEKEYFAKEKEYFAKEKEYFAKEKEY</EncryptionKey>
    <MacKey>FAKEMACFAKEMACFAKEMAC</MacKey>
    <InitializationVector>FAKEIVFAKEIV</InitializationVector>
    <Mac>FAKEMACVALUE</Mac>
    <ProfileIdentifier>ProfileVersion1</ProfileIdentifier>
    <FileDigest>FAKEDIGEST</FileDigest>
    <FileDigestAlgorithm>SHA256</FileDigestAlgorithm>
  </EncryptionInfo>
  <MsiInfo>
    <MsiProductCode>{11111111-2222-3333-4444-555555555555}</MsiProductCode>
    <MsiProductVersion>1.2.3</MsiProductVersion>
    <MsiPackageCode>{ABCDEF01-2345-6789-ABCD-EF0123456789}</MsiPackageCode>
    <MsiUpgradeCode>{66666666-7777-8888-9999-AAAAAAAAAAAA}</MsiUpgradeCode>
    <MsiExecutionContext>$Context</MsiExecutionContext>
    <MsiRequiresLogon>false</MsiRequiresLogon>
    <MsiRequiresReboot>false</MsiRequiresReboot>
    <MsiIsMachineInstall>$machine</MsiIsMachineInstall>
    <MsiIsUserInstall>$user</MsiIsUserInstall>
    <MsiIncludesServices>true</MsiIncludesServices>
    <MsiIncludesODBCDataSource>false</MsiIncludesODBCDataSource>
    <MsiContainsSystemRegistryKeys>true</MsiContainsSystemRegistryKeys>
    <MsiContainsSystemFolders>false</MsiContainsSystemFolders>
    <MsiPublisher>Example Test Vendor</MsiPublisher>
  </MsiInfo>
</ApplicationInfo>
"@
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $e = $zip.CreateEntry('IntuneWinPackage/Metadata/Detection.xml')
        $w = New-Object System.IO.StreamWriter($e.Open(), (New-Object System.Text.UTF8Encoding($false)))
        try { $w.Write($xml) } finally { $w.Dispose() }
        $e2 = $zip.CreateEntry('IntuneWinPackage/Contents/IntunePackage.intunewin')
        $w2 = New-Object System.IO.StreamWriter($e2.Open())
        try { $w2.Write('not a real payload') } finally { $w2.Dispose() }
    }
    finally {
        $zip.Dispose()
    }
}
