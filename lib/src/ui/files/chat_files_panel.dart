import 'package:flutter/material.dart';

import '../../core/chat_component_controller.dart';
import '../../core/my_files_model.dart';
import '../../i18n/chat_i18n.dart';
import '../../models/chat_component_config.dart';
import '../../networking/files_service.dart';
import '../../networking/secure_file_url.dart';
import '../../theme/chat_theme.dart';
import '../media/file_card.dart';
import '../media/media_viewer.dart';
import '../rooms/room_ui.dart';

/// Opens a file: pictures, videos and PDFs in the in-app viewer, anything else
/// in the platform browser (web FilesPanel `handlePreview`).
Future<void> previewApiFile(
  BuildContext context,
  ApiFile file, {
  String? fileToken,
}) async {
  if (isFilePreviewable(file.mimetype, file.originalName)) {
    final scope = ChatUiScope.of(context);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatScopeBridge(
          scope: scope,
          child: MediaViewerPage(
            attachments: <Map<String, String>>[
              <String, String>{
                'location': file.location,
                'locationPreview': file.locationPreview,
                'mimetype': file.mimetype,
                'originalName': file.displayName,
              },
            ],
            fileToken: fileToken,
          ),
        ),
      ),
    );
    return;
  }
  await openMediaUrl(context, appendFileToken(file.location, fileToken));
}

/// Hands the file to the platform browser, which downloads it (web
/// `handleDownload`).
Future<void> downloadApiFile(
  BuildContext context,
  ApiFile file, {
  String? fileToken,
}) {
  return openMediaUrl(context, appendFileToken(file.location, fileToken));
}

/// Asks, then deletes [file] through the controller (which also retracts the
/// chat messages that carry it). Shows a message when it fails.
Future<void> confirmAndDeleteApiFile(
  BuildContext context,
  ChatComponentController controller,
  ApiFile file,
) async {
  final strings = context.chatStrings;
  final ok = await confirmChatAction(
    context,
    title: strings.t('files.delete.confirmTitle'),
    message: strings.t('files.delete.confirmMessage'),
    confirmLabel: strings.t('files.action.delete'),
    destructive: true,
  );
  if (!ok || !context.mounted) return;
  try {
    await controller.deleteMyFile(file);
  } catch (_) {
    if (context.mounted) {
      showChatSnack(context, strings.t('files.delete.failed'));
    }
  }
}

/// The Files tab: the caller's uploads with a name search, All / Media /
/// Documents / Audio chips, load more, preview, download and delete (web
/// `FilesPanel`). Filtering is client-side over the pages loaded so far.
class ChatFilesPanel extends StatefulWidget {
  const ChatFilesPanel({
    super.key,
    required this.controller,
    required this.config,
  });

  final ChatComponentController controller;
  final ChatComponentConfig config;

  @override
  State<ChatFilesPanel> createState() => _ChatFilesPanelState();
}

class _ChatFilesPanelState extends State<ChatFilesPanel> {
  final TextEditingController _search = TextEditingController();
  FileCategory? _category;

  MyFilesModel get _model => widget.controller.myFiles;

  @override
  void initState() {
    super.initState();
    _model.ensureLoaded();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    return ListenableBuilder(
      listenable: _model,
      builder: (context, _) {
        final model = _model;
        final visible = filterFiles(
          model.items,
          category: _category,
          query: _search.text,
        );
        final fileToken = widget.controller.state.value.user?.fileToken;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: theme.bgSubtle,
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: strings.t('files.search.placeholder'),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(999),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(999),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _chip(strings.t('files.filter.all'), null),
                  _chip(strings.t('files.filter.media'), FileCategory.media),
                  _chip(strings.t('files.filter.documents'),
                      FileCategory.documents),
                  _chip(strings.t('files.filter.audio'), FileCategory.audio),
                ],
              ),
            ),
            Expanded(
              child: _body(context, model, visible, fileToken, strings, theme),
            ),
          ],
        );
      },
    );
  }

  Widget _chip(String label, FileCategory? category) {
    final selected = _category == category;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _category = category),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    MyFilesModel model,
    List<ApiFile> visible,
    String? fileToken,
    ChatStrings strings,
    ChatTheme theme,
  ) {
    if (model.loading && model.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 10),
            Text(
              strings.t('files.loading'),
              style: TextStyle(color: theme.textMuted),
            ),
          ],
        ),
      );
    }
    if (model.error != null && model.items.isEmpty) {
      return _State(
        icon: Icons.error_outline_rounded,
        title: strings.t('files.error.title'),
        action: strings.t('files.action.retry'),
        onAction: model.refresh,
      );
    }
    if (visible.isEmpty) {
      final nothingYet = model.items.isEmpty;
      return _State(
        icon: Icons.insert_drive_file_outlined,
        title: nothingYet
            ? strings.t('files.empty.title')
            : strings.t('files.noResults'),
        subtitle: nothingYet
            ? strings.t('files.empty.subtitle')
            : (model.hasMore
                ? strings.t('files.noResults.moreAvailable')
                : null),
        // Filtering is over the pages loaded so far, so "nothing matches" is
        // only true for what is here: offer the next page.
        action: !nothingYet && model.hasMore
            ? strings.t('files.action.loadMore')
            : null,
        onAction: model.loadMore,
      );
    }
    return ListView(
      children: [
        ChatFilesList(
          files: visible,
          fileToken: fileToken,
          onPreview: (f) => previewApiFile(context, f, fileToken: fileToken),
          onDownload: (f) => downloadApiFile(context, f, fileToken: fileToken),
          onDelete: (f) =>
              confirmAndDeleteApiFile(context, widget.controller, f),
        ),
        if (model.hasMore)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: OutlinedButton(
                onPressed: model.loadingMore ? null : model.loadMore,
                child: Text(
                  model.loadingMore
                      ? strings.t('files.loading')
                      : strings.t('files.action.loadMore'),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _State extends StatelessWidget {
  const _State({
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.textMuted),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: theme.text,
              ),
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.textMuted),
                ),
              ),
            if (action != null)
              TextButton(onPressed: onAction, child: Text(action!)),
          ],
        ),
      ),
    );
  }
}

/// The rows of a file list: thumbnail or icon, name, size and date, and a
/// menu with preview, download and delete.
class ChatFilesList extends StatelessWidget {
  const ChatFilesList({
    super.key,
    required this.files,
    required this.onPreview,
    required this.onDownload,
    this.onDelete,
    this.fileToken,
    this.compact = false,
  });

  final List<ApiFile> files;
  final String? fileToken;
  final bool compact;
  final ValueChanged<ApiFile> onPreview;
  final ValueChanged<ApiFile> onDownload;
  final ValueChanged<ApiFile>? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    return Column(
      children: [
        for (final file in files)
          ListTile(
            key: ValueKey('file-${file.id}'),
            dense: compact,
            onTap: () => onPreview(file),
            leading: _Thumb(file: file, fileToken: fileToken),
            title: Text(
              file.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.text, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              _meta(file),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.textMuted, fontSize: 12),
            ),
            trailing: PopupMenuButton<String>(
              tooltip: strings.t('action.moreOptions'),
              icon: Icon(Icons.more_vert_rounded, color: theme.textSecondary),
              onSelected: (value) {
                switch (value) {
                  case 'preview':
                    onPreview(file);
                  case 'download':
                    onDownload(file);
                  case 'delete':
                    onDelete?.call(file);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'preview',
                  child: Text(strings.t('files.action.preview')),
                ),
                PopupMenuItem(
                  value: 'download',
                  child: Text(strings.t('files.action.download')),
                ),
                if (onDelete != null)
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      strings.t('files.action.delete'),
                      style: TextStyle(color: theme.danger),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  String _meta(ApiFile file) {
    final parts = <String>[
      if (file.size != null) formatBytes(file.size),
      if (file.createdAtDate != null) _day(file.createdAtDate!.toLocal()),
    ];
    return parts.join(' · ');
  }

  String _day(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.file, this.fileToken});

  final ApiFile file;
  final String? fileToken;

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final category = fileCategoryOf(file.mimetype, file.originalName);
    final icon = switch (category) {
      FileCategory.audio => Icons.audiotrack_rounded,
      FileCategory.media => Icons.perm_media_outlined,
      FileCategory.documents => file.mimetype == 'application/pdf'
          ? Icons.picture_as_pdf_rounded
          : Icons.insert_drive_file_rounded,
    };
    final fallback = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: theme.iconChipBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: theme.icons),
    );
    final isImage = (file.mimetype).toLowerCase().startsWith('image/') &&
        isFilePreviewable(file.mimetype, file.originalName);
    final src = file.locationPreview.isNotEmpty
        ? file.locationPreview
        : (isImage ? file.location : '');
    if (src.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        appendFileToken(src, fileToken),
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

/// The "Files" section of the room profile: this chat's files, six at first
/// with Show all / Show less (web ChatProfileModal).
class RoomFilesSection extends StatefulWidget {
  const RoomFilesSection({
    super.key,
    required this.controller,
    required this.roomJid,
    this.readOnly = false,
  });

  final ChatComponentController controller;
  final String roomJid;

  /// Hides the delete action.
  final bool readOnly;

  @override
  State<RoomFilesSection> createState() => _RoomFilesSectionState();
}

class _RoomFilesSectionState extends State<RoomFilesSection> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    widget.controller.myFiles.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.chatTheme;
    final strings = context.chatStrings;
    final model = widget.controller.myFiles;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        // The files route may not exist on this backend: no section then.
        if (model.support == FilesEndpointSupport.unsupported) {
          return const SizedBox.shrink();
        }
        final files = model.forRoom(widget.roomJid.split('@').first);
        final shown = _expanded ? files : files.take(6).toList();
        final fileToken = widget.controller.state.value.user?.fileToken;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.t('modal.chatProfile.filesTitle').toUpperCase(),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.6,
                        color: theme.textMuted,
                      ),
                    ),
                  ),
                  if (files.length > 6)
                    TextButton(
                      onPressed: () => setState(() => _expanded = !_expanded),
                      child: Text(strings.t(_expanded
                          ? 'modal.chatProfile.filesShowLess'
                          : 'modal.chatProfile.filesShowAll')),
                    ),
                ],
              ),
            ),
            if (model.loading && files.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (model.error != null && files.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        strings.t('files.error.title'),
                        style: TextStyle(color: theme.textMuted),
                      ),
                    ),
                    TextButton(
                      onPressed: model.refresh,
                      child: Text(strings.t('files.action.retry')),
                    ),
                  ],
                ),
              )
            else if (files.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  strings.t('modal.chatProfile.filesEmpty'),
                  style: TextStyle(color: theme.textMuted),
                ),
              )
            else
              ChatFilesList(
                files: shown,
                compact: true,
                fileToken: fileToken,
                onPreview: (f) =>
                    previewApiFile(context, f, fileToken: fileToken),
                onDownload: (f) =>
                    downloadApiFile(context, f, fileToken: fileToken),
                onDelete: widget.readOnly
                    ? null
                    : (f) => confirmAndDeleteApiFile(
                          context,
                          widget.controller,
                          f,
                        ),
              ),
          ],
        );
      },
    );
  }
}
