# MsiTools

Scriptable MSI database edits through the `WindowsInstaller.Installer` COM
object that ships with Windows, and a reader for the metadata
IntuneWinAppUtil writes into a `.intunewin`. No Orca, no InstEd, no SDK.

Status: [built, ran on real tickets]. I did each of these by hand at a
PowerShell prompt during packaging work in July and August 2026. This module is
a fresh rewrite of those steps, generalized from what I ran at work. The test
suite builds a synthetic MSI from scratch and runs every function against it
in Windows PowerShell 5.1 and PowerShell 7; no vendor MSI is included or
needed.

```powershell
Import-Module .\msi\MsiTools.psm1

Get-MsiProperty  -Path .\vendor.msi -Name ALLUSERS
Set-MsiProperty  -Path .\vendor.msi -Name ALLUSERS -Value 1 -OutputPath .\patched\vendor.msi          # dry run
Set-MsiProperty  -Path .\vendor.msi -Name ALLUSERS -Value 1 -OutputPath .\patched\vendor.msi -Apply   # writes the copy, reads it back

Get-MsiSequence  -Path .\vendor.msi -Table InstallExecuteSequence
New-MsiTransformRemoveAction -Path .\vendor.msi -Action ExampleDiskCheckAction -TransformPath .\skip-check.mst          # dry run
New-MsiTransformRemoveAction -Path .\vendor.msi -Action ExampleDiskCheckAction -TransformPath .\skip-check.mst -Apply   # builds and verifies
Test-MsiTransform -Path .\vendor.msi -TransformPath .\skip-check.mst -Action ExampleDiskCheckAction

(Get-IntuneWinMetadata -Path .\Output\vendor.intunewin).MsiInfo.MsiExecutionContext
```

## Rules the module enforces

- The source MSI is never modified. `Set-MsiProperty` edits a copy at
  `-OutputPath`; the transform functions work on a throwaway copy in `%TEMP%`.
- Nothing is written without `-Apply`.
- Every write is read back from disk. `Set-MsiProperty` returns `Verified`;
  `New-MsiTransformRemoveAction` runs `Test-MsiTransform` on its own output.
- Values reach the SQL through MSI record parameters (`?`), never string
  concatenation, and property and action names must be valid MSI identifiers.

## Set-MsiProperty: the ALLUSERS fix

A patch agent MSI had no `ALLUSERS` property. IntuneWinAppUtil recorded
`MsiExecutionContext` as User in the package metadata, and the app installed
per user. I inserted `ALLUSERS=1` into a copy's Property table, re-wrapped it,
and read `Detection.xml` out of the new `.intunewin`. The first attempt still
said User, and I never pinned down why. I redid the edit, gated the re-wrap on
a read-back, and that package said System (and `MsiIsMachineInstall` true).
Reading the metadata, not trusting the edit, is the whole lesson (case study 4).

How the module does it: COM calls go through reflection (`InvokeMember`),
which behaves the same in Windows PowerShell 5.1 and PowerShell 7. Each write
commits, releases every handle, and reads the value back from the file on
disk; the tests do that against the synthetic MSI. The read-back, and then
`Detection.xml`, are what I rely on, not the call style.

Editing an MSI breaks the vendor's Authenticode signature. The function
reports `SourceSignature` and `OutputSignature` so that is visible. Keep the
pristine original next to the patched copy and say what you changed in the
Intune app notes. A transform keeps the original signed and is the better
choice for changes that only matter at install time, but it would not have
fixed this one: IntuneWinAppUtil reads the MSI itself when it records the
execution context.

## New-MsiTransformRemoveAction and Test-MsiTransform

Builds an MST that deletes one or more actions from the sequence tables:
copy, delete rows, commit, `GenerateTransform` against the untouched
original, `CreateTransformSummaryInfo`, delete the copy, then verify by
applying the transform to another throwaway copy and checking the actions are
gone. Install with:

```
msiexec /i vendor.msi TRANSFORMS="skip-check.mst" /qn /norestart /L*v install.log
```

A warning from experience. I built one of these to remove a vendor custom
action (a disk-space check) that failed under a silent SYSTEM install. The
transform worked exactly as designed, and the next custom action in the
sequence, a token check, failed instead (from my notes; the raw log was not
kept). The real cause was upstream of both: my own scripts were renaming the
MSI, and the installer needed its original file name (some vendors read a
site token from the installer file name). Use a transform to learn which
action fails and why before you ship one, and never remove a vendor check you
do not understand from a production install. The synthetic MSI in the tests
reproduces that shape on purpose: removing `ExampleDiskCheckAction` leaves
`ExampleTokenCheckAction` in place.

## Get-IntuneWinMetadata

A `.intunewin` is a zip. `IntuneWinPackage/Metadata/Detection.xml` records
the setup file name, the tool version and, for an MSI, `MsiInfo`: product
code, version, upgrade code, `MsiExecutionContext` (User, System or Any),
whether it is a machine or user install, whether it includes services.

`EncryptionInfo` in the same file holds the key material for the encrypted
payload in the package. The function shows it as `<redacted>` unless you pass
`-IncludeEncryptionInfo`. Do not paste it anywhere.
