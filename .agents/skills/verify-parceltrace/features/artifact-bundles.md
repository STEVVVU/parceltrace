# Artifact bundles

## Sub-features

- Create a bounded content-defined manifest and portable part files.
- Import verified parts into durable local receiver storage.
- Export a missing-chunk request, produce repair parts, and reconstruct the original file.
- Reject malformed, corrupt, foreign, unsafe, or changed-source inputs.

## How to get to it (user POV)

Open Settings and choose Artifact bundles. On desktop, the Flutter page is available through this entry. Native file-picker and save dialogs require manual platform verification.

## Driving it with the Dart CLI

Run `fvm dart app/tool/parceltrace_verify.dart` from the repository root using the Flutter SDK pinned in `.fvmrc`. This drives the same shared bundle and receiver-store APIs as the page through a synthetic file and a temporary filesystem store.

The proof passes when the driver records an incomplete import, successfully reopens the store, produces a request for missing chunks, imports repairs, reconstructs bytes matching the original SHA-256, and records rejection of each supported negative case. Evidence is saved at `.verification-evidence/parceltrace/latest.json` and survives temporary-workspace cleanup.

## Gotchas

- The driver proves the shared filesystem kernel, not operating-system file-picker behavior, native lifecycle behavior, inter-device compatibility, or LocalSend transport.
- Imported bundle content is treated as inert bytes and never executed.

## Observed evidence

[Hosted run39538466496](https://github.com/STEVVVU/parceltrace/actions/runs/39538466496) at6a285062 passed app analysis, all79 Flutter tests, the real file-based repair driver and the Linux debug build. Downloaded JSON confirms exact-byte reconstruction, duplicate repair import, supported refusal cases and actual temporary-workspace removal. Native pickers, mobile lifecycle and inter-device acceptance remain unverified.
