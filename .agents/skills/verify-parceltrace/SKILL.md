---
name: verify-parceltrace
description: Verify Parceltrace artifact-bundle creation, interrupted import, repair, and reconstruction through the shared Dart kernel when changing bundle behavior.
---

# Verify Parceltrace

This repo's primary surface is the LocalSend Flutter app. Parceltrace also exposes a pure Dart bundle kernel, which is the safe automated surface for verifying portable pack and repair behavior without connecting to another device.

## Launch

From the repository root, use the Flutter SDK pinned by `.fvmrc`:

```bash
fvm dart --version
```

Confirm the command reports Dart 3.11.5. This checks the pinned runtime without hardcoding a machine-specific SDK path. The verification driver is a short-lived command, so each drive starts a fresh process. It creates a unique temporary workspace under the system temp directory and deletes that workspace during cleanup. No LocalSend native app or network peer is started.

## Doctor

Run `fvm dart --version` and confirm it reports Dart 3.11.5. If FVM is unavailable or the version differs, stop before driving. From the repo root, confirm the working tree and generated evidence location with `git status --short` and `Test-Path .verification-evidence/parceltrace/latest.json`.

## Drive

Run the maintained driver from the repository root:

```bash
fvm dart app/tool/parceltrace_verify.dart
```

The driver creates a synthetic source, builds packs, imports only a subset into a real temporary receiver store, closes and reopens that store, exports the missing-chunk request, makes repair packs from the original bytes, imports them idempotently, and verifies the reconstructed output byte-for-byte. It also exercises corrupt pack, foreign manifest, changed source, unsafe basename, and output path escape rejection. The driver uses the same `ArtifactBundle` and `BundleReceiverStore` APIs as the Flutter page.

## Evidence

The driver records the actions, resulting manifest and part counts, repaired byte count, exact reconstruction hash, and negative-case outcomes in `.verification-evidence/parceltrace/latest.json`. Preserve this file across cleanup. A successful exit is insufficient unless the JSON names each action and the reconstructed digest matches the source digest.

## Cleanup

The driver removes its unique temporary workspace in a `finally` block. It leaves `.verification-evidence/parceltrace/latest.json` intact. Do not remove evidence as part of cleanup. The generated evidence is ignored by Git.

## Helpers

The maintained helper is `app/tool/parceltrace_verify.dart`. Invoke it with the Drive command above. It requires no app server, credentials, device, or network connection.
