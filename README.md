# Parceltrace

Local file sharing with repairable artifact bundles. This independent [LocalSend](https://github.com/localsend/localsend) fork keeps the complete Flutter app and Rust networking core, then adds a workflow for recovering an incomplete batch without resending verified chunks.

## Artifact bundles

Open **Settings → Artifact bundles**.

1. Choose a file up to 32 MiB. The app creates bounded `.ptpack` files and adds them to the existing **Send** selection.
2. Send those files through LocalSend. On the receiving device, import the completed parts into the app’s receiver cache.
3. Reopen the app later and export a `.ptrepair` request for the chunks still missing.
4. On the sender, select that request and the unchanged original file. Send the generated repair parts.
5. Import repairs and choose **Save verified reconstruction**. Every chunk and the final file must match its SHA-256 before the app offers output bytes to the system save picker.

One receiver session is active at a time. **Clear receiver cache** removes that session’s manifest and verified chunks. Native save destinations and overwrite confirmation belong to the platform picker.

## What this fork adds

- A versioned manifest with a safe basename, file length, whole-file hash, contiguous chunk offsets, and chunk hashes.
- Bounded Gear-based content-defined chunking with 64 KiB minimum, 256 KiB target, and 1 MiB maximum chunks.
- Portable, verified part files and a manifest-bound missing-chunk request.
- Durable app-owned chunk storage, reopen recovery, duplicate-safe import, and exact reconstruction checks.
- A Flutter page that queues parts through the existing Send flow and uses native pickers for import and save.

The transport remains LocalSend’s existing HTTPS protocol. Stock peers can carry these ordinary files, but bundle creation, import, and repair require this fork. This does not add in-file resume endpoints to LocalSend, implement TCP or UDP, or execute imported content.

## Run and verify

Use Flutter **3.41.9** and Dart **3.11.5**, pinned in [.fvmrc](.fvmrc), plus the Rust version in [rust-toolchain.toml](rust-toolchain.toml). FVM is optional if the exact SDK is already on your PATH.

```bash
cd app
fvm flutter pub get
fvm flutter run
```

Run checks from `app/`:

```bash
fvm flutter analyze
fvm flutter test
fvm flutter build linux --debug
```

Drive the shared kernel from the repository root after resolving dependencies:

```bash
fvm dart app/tool/parceltrace_verify.dart
```

The [verification skill](.agents/skills/verify-parceltrace/SKILL.md) maps actions, evidence, and cleanup. The [Linux workflow](.github/workflows/parceltrace.yml) verifies the official SDK archive checksum, runs analysis and tests, drives repair on real files, and builds the app.

[Hosted Linux verification](https://github.com/STEVVVU/parceltrace/actions/runs/39542809065) passed all 79 Flutter tests, app analysis, the filesystem repair driver, and the Linux debug build at `48d5a740`. The local focused suite passed 8 tests. The actual filesystem driver created four normal part files from a 12 MiB source, imported the first complete part, reopened the receiver store with 14 verified chunks, requested only the 32 missing chunks, imported repairs twice, and reconstructed the exact source bytes. It also rejected corruption, truncation, oversized inputs, invalid ordering, foreign manifests, unsafe names, and a changed repair source. Generated evidence stays under ignored `.verification-evidence/`.

Full Flutter plugin tests could not run on this Windows host because plugin setup requires symlink support. System privileges were unchanged. Native picker/save dialogs, device lifecycle, mobile builds, and inter-device transfer acceptance remain unverified. The receiver cache has one coordinated owner in the page and no cross-process locking guarantee. Hashes detect mismatches; they do not establish a sender’s identity or make received files safe to open.

## Research and course frame

[FastCDC, USENIX ATC 2016](https://www.usenix.org/conference/atc16/technical-sessions/presentation/xia) supplies the Gear hashing, minimum cut-point, and chunk-size normalization ideas. This bounded algorithm is independently defined in the manifest. It does not reproduce the full paper, promise byte compatibility with other implementations, or claim the paper’s throughput results.

[Northeastern CS 4700’s reliable transport project](https://4700.network/docs/projects/project-4-reliable-transport-protocol/) supplies a failure-and-recovery evaluation frame. That assignment implements reliable UDP. This project adapts the problem to application-level artifact repair over the existing HTTPS transport and does not claim course completion.

## Source and license

Full LocalSend v1.18.2 source and history are retained at upstream commit `af0416be50770a97760f7070684bc667b759a15c`. Flutter and Dart provide the interface and bundle workflow; Rust supplies the inherited networking core. Original Apache-2.0 licenses and notices remain in place. The unchanged [upstream README](README.upstream.md) contains platform setup and inherited app documentation.
