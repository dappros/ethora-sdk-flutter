import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../networking/files_service.dart';

/// The caller's uploaded files, paged (web `useMyFiles`). One instance is
/// shared by the Files panel and the room profile, so the list is fetched
/// once and every view of it stays consistent.
///
/// The backend lists the caller's own uploads and has no room filter, so a
/// room's files are picked client-side with [forRoom].
class MyFilesModel extends ChangeNotifier {
  MyFilesModel({required this.service, this.pageSize = kFilesPageSize});

  final FilesService service;
  final int pageSize;

  List<ApiFile> _items = const <ApiFile>[];
  int _total = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _loadingMore = false;
  bool _loadedOnce = false;
  Object? _error;
  int _request = 0;
  bool _disposed = false;

  List<ApiFile> get items => _items;
  int get total => _total;
  bool get hasMore => _hasMore;

  /// First page in flight.
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;

  /// The last failure, null after a success.
  Object? get error => _error;
  bool get loadedOnce => _loadedOnce;

  FilesEndpointSupport get support => service.support;

  /// Files uploaded for the chat [chatName] (the JID localpart).
  List<ApiFile> forRoom(String chatName) =>
      _items.where((f) => f.belongsToRoom(chatName)).toList();

  /// Loads the first page unless it is loaded or loading.
  Future<void> ensureLoaded() {
    if (_loadedOnce || _loading) return Future<void>.value();
    return refresh();
  }

  /// Drops what is loaded and fetches the first page again.
  Future<void> refresh() => _fetch(0, replace: true);

  /// The next page. Does nothing while a load runs or when all is loaded.
  Future<void> loadMore() {
    if (_loading || _loadingMore || !_hasMore) return Future<void>.value();
    return _fetch(_items.length, replace: false);
  }

  Future<void> _fetch(int offset, {required bool replace}) async {
    final id = ++_request;
    if (replace) {
      _loading = true;
      _loadingMore = false;
    } else {
      _loadingMore = true;
    }
    _error = null;
    // Not synchronously: a view calls this from initState, in the middle of a
    // build, where listeners must not be told to rebuild.
    scheduleMicrotask(_notify);
    try {
      final page = await service.list(limit: pageSize, offset: offset);
      if (id != _request || _disposed) return;
      final seen = <String>{if (!replace) ..._items.map((f) => f.id)};
      final fresh = page.items.where((f) => seen.add(f.id)).toList();
      _items = replace ? fresh : <ApiFile>[..._items, ...fresh];
      _total = page.total;
      // A page that brought nothing new ends paging, whatever `total` says.
      _hasMore = fresh.isNotEmpty && _items.length < _total;
      _loadedOnce = true;
    } catch (e) {
      if (id != _request || _disposed) return;
      _error = e;
    } finally {
      if (id == _request && !_disposed) {
        _loading = false;
        _loadingMore = false;
        _notify();
      }
    }
  }

  /// Deletes a file. It leaves the list at once and comes back if the
  /// request fails (the error is rethrown).
  Future<void> remove(String id) async {
    final previous = _items;
    final previousTotal = _total;
    _items = previous.where((f) => f.id != id).toList();
    _total = previousTotal > 0 ? previousTotal - 1 : 0;
    _notify();
    try {
      await service.delete(id);
    } catch (e) {
      _items = previous;
      _total = previousTotal;
      _error = e;
      _notify();
      rethrow;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A loaded message that carries a file: where it is and its id.
class FileMessageMatch {
  const FileMessageMatch(this.roomJid, this.messageId);
  final String roomJid;
  final String messageId;
}

/// Every loaded message that carries [file], by its `attachmentId` or its
/// location, so deleting a file can also retract the chat message instead of
/// leaving a broken picture behind (web `findMessagesForFile`).
List<FileMessageMatch> findMessagesForFile(
  Map<String, List<ChatMessage>> messagesByRoom,
  ApiFile file,
) {
  bool carries(Map<String, String> attachment) {
    final id = attachment['attachmentId'] ?? '';
    if (file.id.isNotEmpty && id.isNotEmpty && id == file.id) return true;
    final location = attachment['location'] ?? '';
    return file.location.isNotEmpty &&
        location.isNotEmpty &&
        location == file.location;
  }

  final matches = <FileMessageMatch>[];
  messagesByRoom.forEach((roomJid, list) {
    for (final message in list) {
      if (message.isDeleted) continue;
      final attachments = message.attachments.isNotEmpty
          ? message.attachments
          : <Map<String, String>>[
              <String, String>{
                'attachmentId': message.data['attachmentId'] ?? '',
                'location': message.mediaUrl ?? message.data['location'] ?? '',
              },
            ];
      if (attachments.any(carries)) {
        matches.add(FileMessageMatch(roomJid, message.id));
      }
    }
  });
  return matches;
}
