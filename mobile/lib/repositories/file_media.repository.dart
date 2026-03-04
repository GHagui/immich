import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/entities/asset.entity.dart' hide AssetType;
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:photo_manager/photo_manager.dart' hide AssetType;
import 'package:path/path.dart' as path;

final fileMediaRepositoryProvider = Provider((ref) => const FileMediaRepository());

class FileMediaRepository {
  const FileMediaRepository();

  static const _rawFileSaverChannel = MethodChannel('immich/raw_file_saver');

  /// Returns true when [filePath] is a Canon CR3 RAW file.
  @visibleForTesting
  bool isCR3File(String filePath) {
    return path.extension(filePath).toLowerCase() == '.cr3';
  }

  /// Returns the MIME type to pass to the native save channel for [filePath].
  ///
  /// `.cr3` files are mapped to `image/x-canon-cr3` so the native plugin can
  /// insert them into MediaStore.Downloads with a concrete type. All other
  /// extensions return `image/*`, which photo_manager resolves correctly via
  /// its own MimeTypeMap lookup for standard formats.
  @visibleForTesting
  String mimeTypeForFile(String filePath) {
    if (isCR3File(filePath)) return 'image/x-canon-cr3';
    return 'image/*';
  }

  Future<Asset?> saveImage(Uint8List data, {required String title, String? relativePath}) async {
    final entity = await PhotoManager.editor.saveImage(data, filename: title, title: title, relativePath: relativePath);
    return AssetMediaRepository.toAsset(entity);
  }

  Future<LocalAsset?> saveLocalAsset(Uint8List data, {required String title, String? relativePath}) async {
    final entity = await PhotoManager.editor.saveImage(data, filename: title, title: title, relativePath: relativePath);

    return LocalAsset(
      id: entity.id,
      name: title,
      type: AssetType.image,
      createdAt: entity.createDateTime,
      updatedAt: entity.modifiedDateTime,
      isEdited: false,
    );
  }

  Future<Asset?> saveImageWithFile(String filePath, {String? title, String? relativePath}) async {
    // CR3 files have no entry in Android's MimeTypeMap, so photo_manager falls back
    // to the wildcard "image/*" which MediaStore rejects. Use a dedicated native
    // channel that inserts the file with an explicit MIME type instead.
    if (CurrentPlatform.isAndroid && isCR3File(filePath)) {
      return _saveRawFileOnAndroid(
        filePath,
        title: title ?? path.basename(filePath),
        relativePath: relativePath ?? 'DCIM/Immich',
      );
    }

    final entity = await PhotoManager.editor.saveImageWithPath(filePath, title: title, relativePath: relativePath);
    return AssetMediaRepository.toAsset(entity);
  }

  /// Saves a RAW file on Android via [_rawFileSaverChannel], which inserts the
  /// file into MediaStore with an explicit MIME type to avoid the
  /// "Unsupported MIME type image/*" error from photo_manager.
  Future<Asset?> _saveRawFileOnAndroid(String filePath, {required String title, required String relativePath}) async {
    final String? uriString = await _rawFileSaverChannel.invokeMethod<String>('saveRawFile', {
      'filePath': filePath,
      'title': title,
      'relativePath': relativePath,
      'mimeType': mimeTypeForFile(filePath),
    });

    if (uriString == null) return null;

    // Extract the numeric MediaStore ID from the content URI so we can look up
    // the AssetEntity that photo_manager already knows about.
    final uri = Uri.parse(uriString);
    final assetId = uri.pathSegments.last;
    final entity = await AssetEntity.fromId(assetId);
    return AssetMediaRepository.toAsset(entity);
  }

  Future<Asset?> saveLivePhoto({required File image, required File video, required String title}) async {
    final entity = await PhotoManager.editor.darwin.saveLivePhoto(imageFile: image, videoFile: video, title: title);
    return AssetMediaRepository.toAsset(entity);
  }

  Future<Asset?> saveVideo(File file, {required String title, String? relativePath}) async {
    final entity = await PhotoManager.editor.saveVideo(file, title: title, relativePath: relativePath);
    return AssetMediaRepository.toAsset(entity);
  }

  Future<void> clearFileCache() => PhotoManager.clearFileCache();

  Future<void> enableBackgroundAccess() => PhotoManager.setIgnorePermissionCheck(true);

  Future<void> requestExtendedPermissions() => PhotoManager.requestPermissionExtend();
}
