# Remote support client false failures

September 2026. A remote support client, deployed a month earlier as a Win32
app, showed 707 of 764 devices Failed in Intune. The agent itself was working
on most of them.

Patterns from this case: [`win32/DETECTION-RULES.md`](../../win32/DETECTION-RULES.md),
[`win32/detection`](../../win32/detection), [`triage/`](../../triage) (`--present-list`).

## The theory came from a colleague

A colleague said it first, on 2026-09-11: the agents had auto-updated, so the
MSI product-code detection rule no longer matched, Intune kept trying to
reinstall the older package, and that failed. My part was proving it with
data and fixing it.

## Checking it

All read-only, through Graph, the same day:

- Intune Discovered apps showed the client on about 700 Windows devices, and
  647 of them were already on a newer version than the package. Newer
  versions had shipped since the package was built, and the agents updated
  themselves, as designed.
- Each client version had its own MSI ProductCode. The detection rule looked
  for one.
- A per-device join of the install report against Discovered apps:

| Report says | Client actually present | Devices |
|---|---|---|
| Failed | yes | 667 |
| Failed | no | 40 |

So 667 of the 707 failures were false, and the real remediation list was 40
devices. The report's error column matched the mechanism: installing the older
MSI over a newer running client fails with 1603, shown as 0x80070643.

## The fix

I changed the detection rule to "file exists" on the client's service
executable, at a path that does not change between versions, and added a
verbose log to the install command. I did it through Graph with the app's
before and after JSON saved for rollback.

Three minutes later the rule was back to the product code. I had the app open
in the Intune portal from before the change, and my own Save on that blade (a
logo upload) re-sent the whole cached app object. I
re-applied the change as one PATCH per field, read each field back, and noted
that the portal saves had also flipped "Allow available uninstall" from Yes to
No (harmless for a Required-only app). Graph rejected the long change-log text
for the notes field, so that went in through the portal afterwards.

## What I did not do

- I did not re-measure the failure count after the fix. I expected Failed to
  drop to roughly the 40 real devices as devices re-evaluated, but I have no
  export showing it.

## Two more things the data showed

- An uninstall command that hard-codes the original product code breaks the
  same way once the agent updates itself. The fix is to look the code up at
  uninstall time.
- Assigning an app Required to all users on top of all devices doubles the
  report rows. A device assignment is enough for a machine-wide agent.

## What I changed afterwards

- I stopped using product-code detection for agents that update themselves.
  It is the Intune default for an MSI and still fine for apps that do not.
- I left the agent's auto-update on, because that is how its security fixes
  arrive, and changed the detection rule instead.
- I join the install report against inventory before I trust a failure
  count. The triage tool's `--present-list` option does the same offline.
- I close portal blades before changing an app through Graph, and read the
  app back afterwards.
