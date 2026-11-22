import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/session_picker/session_controller.dart';
import '../../features/studio_editor/studio_editor_controller.dart';
import '../ffi/native_worker.dart';
import '../session/session_store.dart';
import '../storage/android_storage_gateway.dart';
import '../storage/proxy_cache_manager.dart';
import '../storage/storage_gateway.dart';

final storageGatewayProvider = Provider<StorageGateway>(
  (ref) => AndroidStorageGateway(),
);

final nativeWorkerProvider = Provider<NativeWorker>(
  (ref) => throw UnimplementedError(
    'nativeWorkerProvider must be overridden during app bootstrap or in tests.',
  ),
);

final sessionStoreProvider = Provider<SessionStore>((ref) {
  return SessionStore(storageGateway: ref.watch(storageGatewayProvider));
});

final proxyCacheManagerProvider = Provider<ProxyCacheManager>((ref) {
  final manager = ProxyCacheManager(
    storageGateway: ref.watch(storageGatewayProvider),
    nativeWorker: ref.watch(nativeWorkerProvider),
  );
  ref.onDispose(() {
    unawaited(manager.dispose());
  });
  return manager;
});

final sessionControllerProvider =
    StateNotifierProvider<SessionController, SessionState>((ref) {
      return SessionController(
        storageGateway: ref.watch(storageGatewayProvider),
        sessionStore: ref.watch(sessionStoreProvider),
        proxyCacheManager: ref.watch(proxyCacheManagerProvider),
      );
    });

final studioNativeGatewayProvider = Provider<StudioNativeGateway>(
  (ref) => NativeWorkerStudioGateway(ref.watch(nativeWorkerProvider)),
);

final studioFrameLoaderProvider = Provider<StudioFrameLoader?>(
  (ref) => null,
);
