# Patch agent install context

2026-08-07. A patch management agent's MSI went into Intune as a Win32 app and
installed in the user context, which is useless for an agent that patches the
machine. The assignment was fine. The cause was in the package.

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

## Checking the package

The first attempt still said User. The property edit had looked fine, but the
package metadata said otherwise, and I never pinned down why. I redid the
edit, gated the re-wrap on a read-back, and that package said System:
`MsiExecutionContext` System and `MsiIsMachineInstall` true. I deleted the
first Intune app object and created the app again from the corrected package.

Three Inspect folders from that day read User, User, System.

## What I changed afterwards

- I gate the re-wrap on a read-back, then check `Detection.xml` inside the
  `.intunewin`, because that is what Intune reads.
- Editing an MSI breaks its signature, so I keep the vendor's original
  untouched and edit a copy. A transform would not have worked here, because
  IntuneWinAppUtil reads the MSI itself when it records the execution context.
- This MSI was configured for our tenant by the vendor portal, so it stays on
  the packaging share. The technique is in `msi/MsiTools.psm1`, tested on a
  synthetic MSI.
