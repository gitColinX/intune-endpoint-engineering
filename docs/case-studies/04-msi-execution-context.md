# Verify the metadata, not the edit: an MSI that installed per user

2026-08-07. A patch management agent's MSI went into Intune as a Win32 app and
installed in the user context, which is useless for an agent that patches the
machine. The package was the problem, not the assignment.

Pattern from this case: [`msi/`](../../msi) (`Set-MsiProperty`, `Get-IntuneWinMetadata`).

## Cause

The vendor MSI had no `ALLUSERS` property, so Windows Installer treated it as
a per-user package. When IntuneWinAppUtil wrapped it, it recorded that in the
package metadata: `MsiExecutionContext` User, `MsiIsUserInstall` true. Intune
took the app's install context from there.

## Fix

1. Copied the vendor MSI. The original stayed untouched.
2. Inserted `ALLUSERS=1` into the copy's Property table through the
   `WindowsInstaller.Installer` COM object, then read it back with a SELECT.
3. Re-wrapped the copy with IntuneWinAppUtil.
4. Opened the new `.intunewin` (it is a zip) and read
   `IntuneWinPackage/Metadata/Detection.xml`.

## What broke

The first attempt still said User. The property edit had looked fine, but the
package metadata said otherwise, and I never pinned down why. I redid the
edit, gated the re-wrap on a read-back, and that package said System:
`MsiExecutionContext` System and `MsiIsMachineInstall` true. I deleted the
first Intune app object and created the app again from the corrected package.

Three Inspect folders from that day read User, User, System.

## What I took from it

- Verify the thing the platform reads, not the thing you changed. Here that
  was `Detection.xml`, not the MSI.
- Editing an MSI breaks its signature. Keep the pristine original and say what
  you changed in the app notes. For changes that only matter at install time,
  prefer a transform when the vendor supports one. It would not have helped
  here: IntuneWinAppUtil reads the MSI itself when it records the execution
  context, so the property had to be in the MSI.
- This MSI was configured for our tenant by the vendor portal, so it never
  leaves the packaging share. The technique is what is shareable, and it is in
  `msi/MsiTools.psm1`, tested on a synthetic MSI.
