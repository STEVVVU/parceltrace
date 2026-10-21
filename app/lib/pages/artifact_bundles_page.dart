import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/parceltrace/artifact_bundle.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

class ArtifactBundlesPage extends StatefulWidget {
  const ArtifactBundlesPage({super.key});

  @override
  State<ArtifactBundlesPage> createState() => _ArtifactBundlesPageState();
}

class _ArtifactBundlesPageState extends State<ArtifactBundlesPage> {
  BundleReceiverStore? _receiver;
  String? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(
      _refreshReceiver().whenComplete(() {
        if (mounted) setState(() => _busy = false);
      }),
    );
  }

  Future<Directory> _appDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'parceltrace'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<BundleReceiverStore> _openReceiver() async {
    final existing = _receiver;
    if (existing != null) return existing;
    final appDirectory = await _appDirectory();
    final receiver = await BundleReceiverStore.open(Directory(p.join(appDirectory.path, 'receiver')));
    if (mounted) setState(() => _receiver = receiver);
    return receiver;
  }

  Future<void> _refreshReceiver() async {
    try {
      await _openReceiver();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _refreshReceiver();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Uint8List> _readSelectedFile(PlatformFile file, int maximumBytes) async {
    if (file.size < 0 || file.size > maximumBytes) {
      throw FormatException('${file.name} exceeds the $maximumBytes byte limit');
    }
    if (file.bytes != null) {
      if (file.bytes!.length > maximumBytes) throw FormatException('${file.name} exceeds the size limit');
      return file.bytes!;
    }
    final stream = file.readStream ?? (file.path == null ? null : File(file.path!).openRead());
    if (stream == null) throw FormatException('${file.name} could not be read from the selected location');
    final output = BytesBuilder(copy: false);
    var length = 0;
    await for (final bytes in stream) {
      length += bytes.length;
      if (length > maximumBytes) throw FormatException('${file.name} exceeds the size limit');
      output.add(bytes);
    }
    if (length != file.size) throw FormatException('${file.name} changed while it was being read');
    return output.takeBytes();
  }

  Future<void> _createAndQueueParts() async {
    final ref = context.ref;
    final selection = await FilePicker.pickFiles(allowMultiple: false, withReadStream: true, type: FileType.any);
    if (selection == null || selection.files.isEmpty) return;
    final selected = selection.files.single;
    final source = await _readSelectedFile(selected, artifactBundleMaxFileBytes);
    final bundle = ArtifactBundle.fromBytes(fileName: selected.name, bytes: source);
    final appDirectory = await _appDirectory();
    final outputDirectory = Directory(p.join(appDirectory.path, 'outgoing', bundle.manifest.id));
    await outputDirectory.create(recursive: true);
    final parts = bundle.createParts();
    final files = <File>[];
    for (var index = 0; index < parts.length; index++) {
      final name = 'part-${(index + 1).toString().padLeft(3, '0')}.ptpack';
      final file = File(p.join(outputDirectory.path, name));
      await file.writeAsBytes(parts[index], flush: true);
      files.add(file);
    }
    await ref
        .redux(selectedSendingFilesProvider)
        .dispatchAsync(
          AddFilesAction<File>(files: files, converter: CrossFileConverters.convertFile),
        );
    ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.send));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _importParts() async {
    final selection = await FilePicker.pickFiles(
      allowMultiple: true,
      withReadStream: true,
      type: FileType.custom,
      allowedExtensions: const ['ptpack'],
    );
    if (selection == null || selection.files.isEmpty) return;
    if (selection.files.length > 16) throw const FormatException('Select at most 16 part files at once');
    final receiver = await _openReceiver();
    for (final file in selection.files) {
      await receiver.importPart(await _readSelectedFile(file, artifactBundleMaxPartFileBytes));
    }
    if (mounted) setState(() => _receiver = receiver);
  }

  Future<void> _exportRepairRequest() async {
    final receiver = _receiver ?? await _openReceiver();
    final manifest = receiver.manifest;
    if (manifest == null) throw const FormatException('Import at least one part before requesting repair');
    final bytes = await receiver.exportRepairRequest();
    await FilePicker.saveFile(
      dialogTitle: 'Save repair request',
      fileName: '${manifest.id}.ptrepair',
      type: FileType.custom,
      allowedExtensions: const ['ptrepair'],
      bytes: bytes,
    );
  }

  Future<void> _createRepairParts() async {
    final ref = context.ref;
    final requestSelection = await FilePicker.pickFiles(
      allowMultiple: false,
      withReadStream: true,
      type: FileType.custom,
      allowedExtensions: const ['ptrepair'],
    );
    if (requestSelection == null || requestSelection.files.isEmpty) return;
    final request = await _readSelectedFile(requestSelection.files.single, 64 * 1024);
    final sourceSelection = await FilePicker.pickFiles(allowMultiple: false, withReadStream: true, type: FileType.any);
    if (sourceSelection == null || sourceSelection.files.isEmpty) return;
    final selected = sourceSelection.files.single;
    final source = await _readSelectedFile(selected, artifactBundleMaxFileBytes);
    final parts = createRepairParts(sourceBytes: source, fileName: selected.name, requestBytes: request);
    if (parts.isEmpty) throw const FormatException('The receiver has no missing chunks');
    final manifest = ArtifactBundle.fromBytes(fileName: selected.name, bytes: source).manifest;
    final appDirectory = await _appDirectory();
    final outputDirectory = Directory(p.join(appDirectory.path, 'outgoing', manifest.id));
    await outputDirectory.create(recursive: true);
    final files = <File>[];
    for (var index = 0; index < parts.length; index++) {
      final file = File(p.join(outputDirectory.path, 'repair-${(index + 1).toString().padLeft(3, '0')}.ptpack'));
      await file.writeAsBytes(parts[index], flush: true);
      files.add(file);
    }
    await ref
        .redux(selectedSendingFilesProvider)
        .dispatchAsync(
          AddFilesAction<File>(files: files, converter: CrossFileConverters.convertFile),
        );
    ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.send));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _saveReconstruction() async {
    final receiver = _receiver ?? await _openReceiver();
    final manifest = receiver.manifest;
    if (manifest == null) throw const FormatException('Import artifact parts before saving a file');
    final bytes = await receiver.reconstruct();
    await FilePicker.saveFile(
      dialogTitle: 'Save verified file',
      fileName: manifest.fileName,
      bytes: bytes,
    );
  }

  Future<void> _clearReceiver() async {
    final receiver = _receiver ?? await _openReceiver();
    if (receiver.manifest == null) return;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear received artifact'),
        content: const Text('Remove the current manifest and verified cached chunks from this app?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed == true) await receiver.clearSession();
  }

  @override
  Widget build(BuildContext context) {
    final receiver = _receiver;
    final manifest = receiver?.manifest;
    return Scaffold(
      appBar: AppBar(title: const Text('Artifact bundles')),
      body: ResponsiveListView(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 20),
        children: [
          Text(
            'Package one file up to 32 MiB into verified parts. Send parts with LocalSend, then repair only missing chunks if a batch is interrupted.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.outbox_outlined),
                  title: const Text('Create and queue parts'),
                  subtitle: const Text('Choose a source file. Its part files are added to the existing Send selection.'),
                  onTap: _busy ? null : () => _run(_createAndQueueParts),
                ),
                ListTile(
                  leading: const Icon(Icons.move_to_inbox_outlined),
                  title: const Text('Import received parts'),
                  subtitle: const Text('Select one or more .ptpack files. Verified chunks are cached in app storage.'),
                  onTap: _busy ? null : () => _run(_importParts),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.build_outlined),
                  title: const Text('Export repair request'),
                  subtitle: const Text('Save a manifest-bound request for chunks still missing.'),
                  onTap: _busy || manifest == null ? null : () => _run(_exportRepairRequest),
                ),
                ListTile(
                  leading: const Icon(Icons.replay_outlined),
                  title: const Text('Build and queue repair parts'),
                  subtitle: const Text('Choose a .ptrepair request and the unchanged original source.'),
                  onTap: _busy ? null : () => _run(_createRepairParts),
                ),
                ListTile(
                  leading: const Icon(Icons.save_alt_outlined),
                  title: const Text('Save verified reconstruction'),
                  subtitle: const Text('The output is offered only after every chunk and the whole-file hash verify.'),
                  onTap: _busy || manifest == null ? null : () => _run(_saveReconstruction),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: manifest == null
                  ? const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.inventory_2_outlined),
                      title: Text('No received artifact is active'),
                      subtitle: Text('Import a part to start a durable repair session.'),
                    )
                  : _busy
                  ? const LinearProgressIndicator()
                  : FutureBuilder<List<int>>(
                      future: receiver!.missingChunks(),
                      builder: (context, snapshot) {
                        if (snapshot.hasError) return Text('Receiver cache error: ${snapshot.error}');
                        if (!snapshot.hasData) return const LinearProgressIndicator();
                        final missing = snapshot.data!;
                        final available = manifest.chunks.length - missing.length;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(manifest.fileName, style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 6),
                            Text('${manifest.fileSize} bytes • ${manifest.chunks.length} chunks • $available verified • ${missing.length} missing'),
                            const SizedBox(height: 6),
                            SelectableText('Manifest ${manifest.id}', style: Theme.of(context).textTheme.bodySmall),
                          ],
                        );
                      },
                    ),
            ),
          ),
          if (manifest != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _busy ? null : () => _run(_clearReceiver),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Clear receiver cache'),
              ),
            ),
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
