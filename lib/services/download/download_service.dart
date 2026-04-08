import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io' show Directory, File;

import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/download.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/bili_download_media_file_info.dart';
import 'package:PiliPlus/models_new/pgc/pgc_info_model/episode.dart' as pgc;
import 'package:PiliPlus/models_new/pgc/pgc_info_model/result.dart';
import 'package:PiliPlus/models_new/video/video_detail/data.dart';
import 'package:PiliPlus/models_new/video/video_detail/episode.dart' as ugc;
import 'package:PiliPlus/models_new/video/video_detail/page.dart';
import 'package:PiliPlus/pages/danmaku/controller.dart';
import 'package:PiliPlus/services/download/download_foreground_service.dart';
import 'package:PiliPlus/services/download/download_manager.dart';
import 'package:PiliPlus/utils/extension/file_ext.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;
import 'package:synchronized/synchronized.dart';

// ref https://github.com/10miaomiao/bilimiao2/blob/master/bilimiao-download/src/main/java/cn/a10miaomiao/bilimiao/download/DownloadService.kt

class DownloadService extends GetxService {
  static const _entryFile = 'entry.json';
  static const _indexFile = 'index.json';

  final _lock = Lock();

  final flagNotifier = SetNotifier();
  final waitDownloadQueue = RxList<BiliDownloadEntryInfo>();
  final downloadList = <BiliDownloadEntryInfo>[];

  int? get curCid => _activeContext?.entry.cid;
  final curDownload = Rxn<BiliDownloadEntryInfo>();
  void _updateCurStatus(DownloadStatus status) {
    if (curDownload.value != null) {
      curDownload
        ..value!.status = status
        ..refresh();
    }
  }

  void _setActivePhase(
    _ActiveDownloadContext context,
    _ActiveDownloadPhase phase,
  ) {
    context
      ..phase = phase
      ..failureReason = null;
    _updateCurStatus(phase.status);
  }

  void _setActiveFailure(
    _ActiveDownloadContext context,
    _ActiveDownloadFailureReason reason,
  ) {
    context.failureReason = reason;
    _updateCurStatus(reason.status);
  }

  bool _isForegroundServiceRunning = false;
  bool _isStartPending = false;
  int _sessionSeed = 0;
  _ActiveDownloadContext? _activeContext;

  Future<void> _startForegroundService() async {
    if (_isForegroundServiceRunning) return;
    _isForegroundServiceRunning = true;
    await DownloadForegroundService.start();
  }

  void _stopForegroundService({
    BiliDownloadEntryInfo? entry,
    bool forceLastProgress = false,
  }) {
    if (!_isForegroundServiceRunning) return;
    _isForegroundServiceRunning = false;
    unawaited(
      DownloadForegroundService.stop(
        title: forceLastProgress ? entry?.title : null,
        progress: forceLastProgress ? entry?.downloadedBytes : null,
        total: forceLastProgress ? entry?.totalBytes : null,
      ),
    );
  }

  void _syncForegroundProgress(
    BiliDownloadEntryInfo entry, {
    bool force = false,
  }) {
    if (!_isForegroundServiceRunning) return;
    DownloadForegroundService.updateProgress(
      title: entry.title,
      progress: entry.downloadedBytes,
      total: entry.totalBytes,
      force: force,
    );
  }

  _ActiveDownloadContext _beginDownloadSession(BiliDownloadEntryInfo entry) {
    final context = _ActiveDownloadContext(
      sessionId: ++_sessionSeed,
      entry: entry,
    );
    _activeContext = context;
    curDownload.value = entry;
    waitDownloadQueue.refresh();
    return context;
  }

  bool _isActiveContext(_ActiveDownloadContext context) {
    return _activeContext?.sessionId == context.sessionId &&
        curDownload.value?.cid == context.entry.cid;
  }

  Future<void> _cancelActiveManagers({required bool isDelete}) async {
    await _activeContext?.downloadManager?.cancel(isDelete: isDelete);
    await _activeContext?.audioDownloadManager?.cancel(isDelete: isDelete);
    if (_activeContext case final context?) {
      context
        ..downloadManager = null
        ..audioDownloadManager = null;
    }
  }

  void _clearActiveDownload({bool clearCurrent = true}) {
    if (_activeContext case final context?) {
      context
        ..downloadManager = null
        ..audioDownloadManager = null;
    }
    if (clearCurrent) {
      _activeContext = null;
      curDownload.value = null;
      waitDownloadQueue.refresh();
    }
  }

  BiliDownloadEntryInfo? _nextQueuedEntry({int? excludingCid}) {
    for (final entry in waitDownloadQueue) {
      if (entry.cid != excludingCid) {
        return entry;
      }
    }
    return null;
  }

  void _applyActiveTransition(_ActiveDownloadTransition transition) {
    final entry = transition.entry;
    _clearActiveDownload();
    if (transition.downloadNext) {
      final nextEntry = _nextQueuedEntry(excludingCid: transition.excludingCid);
      if (nextEntry != null) {
        startDownload(nextEntry);
        return;
      }
    }
    if (transition.stopForeground) {
      _stopForegroundService(
        entry: entry,
        forceLastProgress: transition.forceLastProgress,
      );
    }
  }

  late Future<void> waitForInitialization;

  @override
  void onInit() {
    super.onInit();
    initDownloadList();
  }

  void initDownloadList() {
    waitForInitialization = _readDownloadList();
  }

  Future<void> _readDownloadList() async {
    downloadList.clear();
    final downloadDir = Directory(await _getDownloadPath());
    await for (final dir in downloadDir.list()) {
      if (dir is Directory) {
        downloadList.addAll(await _readDownloadDirectory(dir));
      }
    }
    downloadList.sort((a, b) => b.timeUpdateStamp.compareTo(a.timeUpdateStamp));
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<List<BiliDownloadEntryInfo>> _readDownloadDirectory(
    Directory pageDir,
  ) async {
    final result = <BiliDownloadEntryInfo>[];

    if (!pageDir.existsSync()) {
      return result;
    }

    await for (final entryDir in pageDir.list()) {
      if (entryDir is Directory) {
        final entryFile = File(path.join(entryDir.path, _entryFile));
        if (entryFile.existsSync()) {
          try {
            final entryJson = await entryFile.readAsString();
            final entry = BiliDownloadEntryInfo.fromJson(jsonDecode(entryJson))
              ..pageDirPath = pageDir.path
              ..entryDirPath = entryDir.path;
            if (entry.isCompleted) {
              result.add(entry);
            } else {
              waitDownloadQueue.add(entry..status = DownloadStatus.wait);
            }
          } catch (_) {}
        }
      }
    }

    return result;
  }

  void downloadVideo(
    Part page,
    VideoDetailData? videoDetail,
    ugc.EpisodeItem? videoArc,
    VideoQuality videoQuality,
  ) {
    final cid = page.cid!;
    if (downloadList.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    if (waitDownloadQueue.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    final pageData = PageInfo(
      cid: cid,
      page: page.page!,
      from: page.from,
      part: page.part,
      vid: page.vid,
      hasAlias: false,
      tid: 0,
      width: 0,
      height: 0,
      rotate: 0,
      downloadTitle: '视频已缓存完成',
      downloadSubtitle: videoDetail?.title ?? videoArc!.title,
    );
    final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final entry = BiliDownloadEntryInfo(
      mediaType: 2,
      hasDashAudio: false,
      isCompleted: false,
      totalBytes: 0,
      downloadedBytes: 0,
      title: videoDetail?.title ?? videoArc!.title!,
      typeTag: videoQuality.code.toString(),
      cover: (videoDetail?.pic ?? videoArc!.cover!).http2https,
      preferedVideoQuality: videoQuality.code,
      qualityPithyDescription: videoQuality.desc,
      guessedTotalBytes: 0,
      totalTimeMilli: (page.duration ?? 0) * 1000,
      danmakuCount:
          videoDetail?.stat?.danmaku ?? videoArc?.arc?.stat?.danmaku ?? 0,
      timeUpdateStamp: currentTime,
      timeCreateStamp: currentTime,
      canPlayInAdvance: true,
      interruptTransformTempFile: false,
      avid: videoDetail?.aid ?? videoArc!.aid!,
      spid: 0,
      seasonId: null,
      ep: null,
      source: null,
      bvid: videoDetail?.bvid ?? videoArc!.bvid!,
      ownerId: videoDetail?.owner?.mid ?? videoArc?.arc?.author?.mid,
      ownerName: videoDetail?.owner?.name ?? videoArc?.arc?.author?.name,
      pageData: pageData,
    );
    _createDownload(entry);
  }

  void downloadBangumi(
    int index,
    PgcInfoModel pgcItem,
    pgc.EpisodeItem episode,
    VideoQuality quality,
  ) {
    final cid = episode.cid!;
    if (downloadList.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    if (waitDownloadQueue.indexWhere((e) => e.cid == cid) != -1) {
      return;
    }
    final currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final source = SourceInfo(
      avId: episode.aid!,
      cid: cid,
    );
    final ep = EpInfo(
      avId: source.avId,
      page: index,
      danmaku: source.cid,
      cover: episode.cover!,
      episodeId: episode.id!,
      index: episode.title!,
      indexTitle: episode.longTitle ?? '',
      showTitle: episode.showTitle,
      from: episode.from ?? 'bangumi',
      seasonType: pgcItem.type ?? (episode.from == 'pugv' ? -1 : 0),
      width: 0,
      height: 0,
      rotate: 0,
      link: episode.link ?? '',
      bvid: episode.bvid ?? IdUtils.av2bv(source.avId),
      sortIndex: index,
    );
    final entry = BiliDownloadEntryInfo(
      mediaType: 2,
      hasDashAudio: false,
      isCompleted: false,
      totalBytes: 0,
      downloadedBytes: 0,
      title: pgcItem.seasonTitle ?? pgcItem.title ?? '',
      typeTag: quality.code.toString(),
      cover: episode.cover!,
      preferedVideoQuality: quality.code,
      qualityPithyDescription: quality.desc,
      guessedTotalBytes: 0,
      totalTimeMilli:
          (episode.duration ?? 0) *
          (episode.from == 'pugv' ? 1000 : 1), // pgc millisec,, pugv sec
      danmakuCount: pgcItem.stat?.danmaku ?? 0,
      timeUpdateStamp: currentTime,
      timeCreateStamp: currentTime,
      canPlayInAdvance: true,
      interruptTransformTempFile: false,
      spid: 0,
      seasonId: pgcItem.seasonId!.toString(),
      bvid: episode.bvid ?? IdUtils.av2bv(source.avId),
      avid: source.avId,
      ep: ep,
      source: source,
      ownerId: pgcItem.upInfo?.mid,
      ownerName: pgcItem.upInfo?.uname,
      pageData: null,
    );
    _createDownload(entry);
  }

  Future<void> _createDownload(BiliDownloadEntryInfo entry) async {
    final entryDir = await _getDownloadEntryDir(entry);
    final entryJsonFile = File(path.join(entryDir.path, _entryFile));
    await entryJsonFile.writeAsString(jsonEncode(entry.toJson()));
    entry
      ..pageDirPath = entryDir.parent.path
      ..entryDirPath = entryDir.path
      ..status = DownloadStatus.wait;
    waitDownloadQueue.add(entry);
    if (!_isStartPending && curDownload.value?.status.isDownloading != true) {
      _isStartPending = true;
      startDownload(entry);
    }
  }

  Future<Directory> _getDownloadEntryDir(BiliDownloadEntryInfo entry) async {
    late final String dirName;
    late final String pageDirName;
    if (entry.ep case final ep?) {
      dirName = 's_${entry.seasonId}';
      pageDirName = ep.episodeId.toString();
    } else if (entry.pageData case final page?) {
      dirName = entry.avid.toString();
      pageDirName = 'c_${page.cid}';
    }
    final pageDir = Directory(
      path.join(await _getDownloadPath(), dirName, pageDirName),
    );
    if (!pageDir.existsSync()) {
      await pageDir.create(recursive: true);
    }
    return pageDir;
  }

  static Future<String> _getDownloadPath() async {
    final dir = Directory(downloadPath);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  Future<void> startDownload(BiliDownloadEntryInfo entry) {
    return _lock.synchronized(() async {
      _isStartPending = false;
      final previousEntry = curDownload.value;
      await _cancelActiveManagers(isDelete: false);
      if (previousEntry case final curEntry?) {
        if (curEntry.status.isDownloading) {
          curEntry.status = DownloadStatus.pause;
        }
      }

      final context = _beginDownloadSession(entry);
      await _startForegroundService();
      await _startDownload(context);
    });
  }

  Future<bool> downloadDanmaku({
    required BiliDownloadEntryInfo entry,
    bool isUpdate = false,
  }) {
    return _downloadDanmaku(
      entry: entry,
      isUpdate: isUpdate,
    );
  }

  Future<bool> _downloadDanmaku({
    required BiliDownloadEntryInfo entry,
    required bool isUpdate,
    _ActiveDownloadContext? context,
  }) async {
    final cid = entry.pageData?.cid ?? entry.source?.cid;
    if (cid == null) {
      return false;
    }
    final danmakuFile = File(
      path.join(entry.entryDirPath, PathUtils.danmakuName),
    );
    if (isUpdate || !danmakuFile.existsSync()) {
      try {
        if (!isUpdate) {
          _updateCurStatus(DownloadStatus.getDanmaku);
        }
        final seg = (entry.totalTimeMilli / PlDanmakuController.segmentLength)
            .ceil();

        final res = await Future.wait([
          for (var i = 1; i <= seg; i++)
            DmGrpc.dmSegMobile(cid: cid, segmentIndex: i),
        ]);

        final danmaku = res.removeAt(0).data;
        for (final i in res) {
          if (i case Success(:final response)) {
            danmaku.elems.addAll(response.elems);
          }
        }
        res.clear();
        await danmakuFile.writeAsBytes(danmaku.writeToBuffer());

        return true;
      } catch (e) {
        if (!isUpdate) {
          if (context != null && _isActiveContext(context)) {
            _setActiveFailure(context, _ActiveDownloadFailureReason.danmaku);
          } else {
            _updateCurStatus(DownloadStatus.failDanmaku);
          }
        }
        if (kDebugMode) SmartDialog.showToast(e.toString());
        return false;
      }
    }
    return true;
  }

  Future<bool> _downloadCover({
    required BiliDownloadEntryInfo entry,
  }) async {
    try {
      final filePath = path.join(entry.entryDirPath, PathUtils.coverName);
      if (File(filePath).existsSync()) {
        return true;
      }
      final file = (await DefaultCacheManager().getFileFromCache(
        entry.cover,
      ))?.file;
      if (file != null) {
        await file.copy(filePath);
      } else {
        await Request.dio.download(entry.cover, filePath);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startDownload(_ActiveDownloadContext context) async {
    final entry = context.entry;
    try {
      final preparedStage =
          await _DownloadPreparationCoordinator(
            service: this,
            context: context,
          ).run();
      if (preparedStage == null || !_isActiveContext(context)) return;
      _launchMediaDownloadStage(context, preparedStage);
    } catch (e) {
      if (!_isActiveContext(context)) return;
      _setActiveFailure(context, _ActiveDownloadFailureReason.playUrl);
      _applyActiveTransition(_ActiveDownloadTransition.failed(entry));
      if (kDebugMode) {
        debugPrint('get download url error: $e');
      }
    }
  }

  void _launchMediaDownloadStage(
    _ActiveDownloadContext context,
    _PreparedDownloadStage stage,
  ) {
    final entry = stage.entry;
    final videoDir = stage.videoDir;
    switch (stage.mediaFileInfo) {
      case Type1 mediaFileInfo:
        _setActivePhase(context, _ActiveDownloadPhase.downloadingMedia);
        final first = mediaFileInfo.segmentList.first;
        context.downloadManager = DownloadManager(
          url: first.url,
          path: path.join(videoDir.path, PathUtils.videoNameType1),
          onReceiveProgress: (progress, total) =>
              _onReceive(context, progress, total),
          onDone: ([error]) => _onDone(context, error),
        );
        break;
      case Type2 mediaFileInfo:
        _setActivePhase(context, _ActiveDownloadPhase.downloadingMedia);
        context.downloadManager = DownloadManager(
          url: mediaFileInfo.video.first.baseUrl,
          path: path.join(videoDir.path, PathUtils.videoNameType2),
          onReceiveProgress: (progress, total) =>
              _onReceive(context, progress, total),
          onDone: ([error]) => _onDone(context, error),
        );
        final audio = mediaFileInfo.audio;
        if (audio != null && audio.isNotEmpty) {
          context.audioDownloadManager = DownloadManager(
            url: audio.first.baseUrl,
            path: path.join(videoDir.path, PathUtils.audioNameType2),
            onReceiveProgress: null,
            onDone: ([error]) => _onAudioDone(context, error),
          );
        }
        _syncMediaDimensions(entry, mediaFileInfo);
        _updateBiliDownloadEntryJson(entry);
        break;
      default:
        break;
    }
  }

  Future<Directory> _ensureVideoDir(BiliDownloadEntryInfo entry) async {
    final videoDir = Directory(path.join(entry.entryDirPath, entry.typeTag));
    if (!videoDir.existsSync()) {
      await videoDir.create(recursive: true);
    }
    return videoDir;
  }

  void _syncMediaDimensions(BiliDownloadEntryInfo entry, Type2 mediaFileInfo) {
    late final first = mediaFileInfo.video.first;
    entry.pageData
      ?..width = first.width
      ..height = first.height;
    entry.ep
      ?..width = first.width
      ..height = first.height;
  }

  DownloadStatus _resolveActiveTransferStatus(_ActiveDownloadContext context) {
    final status = switch (context.audioDownloadManager?.status) {
      DownloadStatus.downloading => DownloadStatus.audioDownloading,
      DownloadStatus.failDownload => DownloadStatus.failDownloadAudio,
      _ => context.downloadManager?.status ?? DownloadStatus.pause,
    };
    switch (status) {
      case DownloadStatus.audioDownloading:
        context.phase = _ActiveDownloadPhase.downloadingAudio;
        break;
      case DownloadStatus.failDownloadAudio:
        context.failureReason = _ActiveDownloadFailureReason.audioDownload;
        break;
      default:
        break;
    }
    _updateCurStatus(status);
    return status;
  }

  Future<void> _updateBiliDownloadEntryJson(BiliDownloadEntryInfo entry) {
    final entryJsonFile = File(path.join(entry.entryDirPath, _entryFile));
    return entryJsonFile.writeAsString(jsonEncode(entry.toJson()));
  }

  void _onReceive(_ActiveDownloadContext context, int progress, int total) {
    final entry = curDownload.value;
    if (entry == null || !_isActiveContext(context)) return;
    if (progress == 0 && total != 0) {
      _updateBiliDownloadEntryJson(entry..totalBytes = total);
    }
    _setActivePhase(context, _ActiveDownloadPhase.downloadingMedia);
    entry
      ..downloadedBytes = progress
      ..status = context.phase.status;
    curDownload.refresh();
    _syncForegroundProgress(entry);
  }

  void _onDone(_ActiveDownloadContext context, [Object? error]) {
    final entry = curDownload.value;
    if (entry == null || !_isActiveContext(context)) return;
    if (error != null) {
      _setActiveFailure(context, _ActiveDownloadFailureReason.mediaDownload);
      final audioManager = context.audioDownloadManager;
      _applyActiveTransition(_ActiveDownloadTransition.failed(entry));
      unawaited(audioManager?.cancel(isDelete: false));
      return;
    }

    final status = _resolveActiveTransferStatus(context);

    entry.downloadedBytes = entry.totalBytes;
    if (status == DownloadStatus.completed) {
      _completeDownload(context);
    } else {
      _updateBiliDownloadEntryJson(entry);
      if (status == DownloadStatus.failDownloadAudio) {
        _applyActiveTransition(_ActiveDownloadTransition.failed(entry));
      }
    }
  }

  void _onAudioDone(_ActiveDownloadContext context, [Object? error]) {
    final entry = curDownload.value;
    if (entry == null || !_isActiveContext(context)) return;
    if (context.downloadManager?.status != DownloadStatus.completed) return;
    if (error == null) {
      _updateCurStatus(DownloadStatus.completed);
      _completeDownload(context);
      return;
    }
    _setActiveFailure(context, _ActiveDownloadFailureReason.audioDownload);
    _applyActiveTransition(_ActiveDownloadTransition.failed(entry));
  }

  Future<void> _completeDownload(_ActiveDownloadContext context) async {
    final entry = curDownload.value;
    if (entry == null || !_isActiveContext(context)) {
      return;
    }
    entry
      ..downloadedBytes = entry.totalBytes
      ..status = DownloadStatus.completed
      ..isCompleted = true;
    await _updateBiliDownloadEntryJson(entry);
    waitDownloadQueue.remove(entry);
    downloadList.insert(0, entry);
    flagNotifier.refresh();
    _applyActiveTransition(_ActiveDownloadTransition.completed(entry));
  }

  void nextDownload({int? excludingCid}) {
    final nextEntry = _nextQueuedEntry(excludingCid: excludingCid);
    if (nextEntry != null) {
      startDownload(nextEntry);
    }
  }

  Future<void> deleteDownload({
    required BiliDownloadEntryInfo entry,
    bool removeList = false,
    bool removeQueue = false,
    bool refresh = true,
    bool downloadNext = true,
  }) async {
    final isCurrentEntry = curDownload.value?.cid == entry.cid;
    if (removeList) {
      downloadList.remove(entry);
    }
    if (removeQueue || isCurrentEntry) {
      waitDownloadQueue.remove(entry);
    }
    if (isCurrentEntry) {
      await cancelDownload(
        isDelete: true,
        downloadNext: downloadNext,
      );
    }
    final downloadDir = Directory(entry.pageDirPath);
    if (downloadDir.existsSync()) {
      if (!await downloadDir.lengthGte(2)) {
        await downloadDir.tryDel(recursive: true);
      } else {
        final entryDir = Directory(entry.entryDirPath);
        if (entryDir.existsSync()) {
          await entryDir.tryDel(recursive: true);
        }
      }
    }
    if (refresh) {
      flagNotifier.refresh();
    }
  }

  Future<void> deletePage({
    required String pageDirPath,
    bool refresh = true,
  }) async {
    await Directory(pageDirPath).tryDel(recursive: true);
    downloadList.removeWhere((e) => e.pageDirPath == pageDirPath);
    if (refresh) {
      flagNotifier.refresh();
    }
  }

  Future<void> cancelDownload({
    required bool isDelete,
    bool downloadNext = true,
  }) async {
    final entry = curDownload.value;
    await _cancelActiveManagers(isDelete: isDelete);
    if (!isDelete) {
      if (entry != null) {
        await _updateBiliDownloadEntryJson(entry);
        entry.status = DownloadStatus.pause;
      }
    }
    if (entry != null) {
      _applyActiveTransition(
        _ActiveDownloadTransition.cancelled(
          entry,
          downloadNext: downloadNext,
          isDelete: isDelete,
        ),
      );
    } else if (waitDownloadQueue.isEmpty || !downloadNext) {
      _stopForegroundService();
    }
  }
}

final class _ActiveDownloadContext {
  _ActiveDownloadContext({
    required this.sessionId,
    required this.entry,
  }) : phase = _ActiveDownloadPhase.fetchingDanmaku;

  final int sessionId;
  final BiliDownloadEntryInfo entry;
  _ActiveDownloadPhase phase;
  _ActiveDownloadFailureReason? failureReason;
  DownloadManager? downloadManager;
  DownloadManager? audioDownloadManager;
}

final class _PreparedDownloadStage {
  const _PreparedDownloadStage({
    required this.entry,
    required this.mediaFileInfo,
    required this.videoDir,
  });

  final BiliDownloadEntryInfo entry;
  final BiliDownloadMediaInfo mediaFileInfo;
  final Directory videoDir;
}

final class _DownloadPreparationCoordinator {
  const _DownloadPreparationCoordinator({
    required this.service,
    required this.context,
  });

  final DownloadService service;
  final _ActiveDownloadContext context;

  BiliDownloadEntryInfo get entry => context.entry;

  Future<_PreparedDownloadStage?> run() async {
    service._setActivePhase(context, _ActiveDownloadPhase.fetchingDanmaku);
    if (!await service._downloadDanmaku(
      entry: entry,
      isUpdate: false,
      context: context,
    )) {
      if (service._isActiveContext(context)) {
        service._applyActiveTransition(_ActiveDownloadTransition.failed(entry));
      }
      return null;
    }
    if (!service._isActiveContext(context)) return null;

    service._setActivePhase(context, _ActiveDownloadPhase.resolvingMedia);

    final mediaFileInfo = await DownloadHttp.getVideoUrl(
      entry: entry,
      ep: entry.ep,
      source: entry.source,
      pageData: entry.pageData,
    );
    final videoDir = await service._ensureVideoDir(entry);
    final mediaJsonFile = File(path.join(videoDir.path, DownloadService._indexFile));
    await Future.wait([
      mediaJsonFile.writeAsString(jsonEncode(mediaFileInfo.toJson())),
      service._downloadCover(entry: entry),
    ]);

    return _PreparedDownloadStage(
      entry: entry,
      mediaFileInfo: mediaFileInfo,
      videoDir: videoDir,
    );
  }
}

final class _ActiveDownloadTransition {
  const _ActiveDownloadTransition._({
    required this.entry,
    required this.downloadNext,
    required this.excludingCid,
    required this.stopForeground,
    required this.forceLastProgress,
  });

  const _ActiveDownloadTransition.completed(BiliDownloadEntryInfo entry)
    : this._(
        entry: entry,
        downloadNext: true,
        excludingCid: null,
        stopForeground: true,
        forceLastProgress: true,
      );

  const _ActiveDownloadTransition.failed(BiliDownloadEntryInfo entry)
    : this._(
        entry: entry,
        downloadNext: false,
        excludingCid: null,
        stopForeground: true,
        forceLastProgress: false,
      );

  _ActiveDownloadTransition.cancelled(
    BiliDownloadEntryInfo entry, {
    required bool downloadNext,
    required bool isDelete,
  }) : this._(
         entry: entry,
         downloadNext: downloadNext,
         excludingCid: isDelete ? null : entry.cid,
         stopForeground: true,
         forceLastProgress: false,
       );

  final BiliDownloadEntryInfo entry;
  final bool downloadNext;
  final int? excludingCid;
  final bool stopForeground;
  final bool forceLastProgress;
}

enum _ActiveDownloadPhase {
  fetchingDanmaku,
  resolvingMedia,
  downloadingMedia,
  downloadingAudio,
}

extension on _ActiveDownloadPhase {
  DownloadStatus get status => switch (this) {
    _ActiveDownloadPhase.fetchingDanmaku => DownloadStatus.getDanmaku,
    _ActiveDownloadPhase.resolvingMedia => DownloadStatus.getPlayUrl,
    _ActiveDownloadPhase.downloadingMedia => DownloadStatus.downloading,
    _ActiveDownloadPhase.downloadingAudio => DownloadStatus.audioDownloading,
  };
}

enum _ActiveDownloadFailureReason {
  danmaku,
  playUrl,
  mediaDownload,
  audioDownload,
}

extension on _ActiveDownloadFailureReason {
  DownloadStatus get status => switch (this) {
    _ActiveDownloadFailureReason.danmaku => DownloadStatus.failDanmaku,
    _ActiveDownloadFailureReason.playUrl => DownloadStatus.failPlayUrl,
    _ActiveDownloadFailureReason.mediaDownload => DownloadStatus.failDownload,
    _ActiveDownloadFailureReason.audioDownload =>
      DownloadStatus.failDownloadAudio,
  };
}

typedef SetNotifier = Set<VoidCallback>;

extension SetNotifierExt on SetNotifier {
  void refresh() {
    for (final i in this) {
      i();
    }
  }
}
