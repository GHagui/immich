import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/repositories/file_media.repository.dart';

void main() {
  late FileMediaRepository repository;

  setUp(() {
    repository = const FileMediaRepository();
  });

  group('FileMediaRepository.isCR3File', () {
    test('returns true for lowercase .cr3 extension', () {
      expect(repository.isCR3File('/path/to/image.cr3'), isTrue);
    });

    test('returns true for uppercase .CR3 extension', () {
      expect(repository.isCR3File('/path/to/image.CR3'), isTrue);
    });

    test('returns true for mixed-case .Cr3 extension', () {
      expect(repository.isCR3File('/path/to/image.Cr3'), isTrue);
    });

    test('returns true for real-world Canon filename', () {
      expect(repository.isCR3File('/path/to/IMG_5500.CR3'), isTrue);
    });

    test('returns false for .jpg', () {
      expect(repository.isCR3File('/path/to/image.jpg'), isFalse);
    });

    test('returns false for .png', () {
      expect(repository.isCR3File('/path/to/image.png'), isFalse);
    });

    test('returns false for .heic', () {
      expect(repository.isCR3File('/path/to/image.heic'), isFalse);
    });

    test('returns false for .cr2 (older Canon RAW)', () {
      expect(repository.isCR3File('/path/to/image.cr2'), isFalse);
    });

    test('returns false for .raw', () {
      expect(repository.isCR3File('/path/to/image.raw'), isFalse);
    });

    test('returns false for file with no extension', () {
      expect(repository.isCR3File('/path/to/image'), isFalse);
    });

    // Duplicate-download naming: the native plugin inserts the counter BEFORE
    // the extension ("IMG_5595 (1).CR3") so the extension is always preserved.
    test('returns true for counter-before-extension duplicate name', () {
      expect(repository.isCR3File('/path/to/IMG_5595 (1).CR3'), isTrue);
    });

    test('returns true for second duplicate counter-before-extension', () {
      expect(repository.isCR3File('/path/to/IMG_5595 (2).CR3'), isTrue);
    });

    // Regression guard: the old broken naming (counter after extension) must
    // NOT be recognised as a CR3 file, confirming the fix is necessary.
    test('returns false for broken counter-after-extension name (IMG_5595.CR3 (1))', () {
      expect(repository.isCR3File('/path/to/IMG_5595.CR3 (1)'), isFalse);
    });
  });

  group('FileMediaRepository.mimeTypeForFile', () {
    test('returns image/x-canon-cr3 for .cr3 files', () {
      expect(
        repository.mimeTypeForFile('/path/to/image.cr3'),
        equals('image/x-canon-cr3'),
      );
    });

    test('returns image/x-canon-cr3 for .CR3 files (case-insensitive)', () {
      expect(
        repository.mimeTypeForFile('/path/to/IMG_5500.CR3'),
        equals('image/x-canon-cr3'),
      );
    });

    test('returns image/* for .jpg files', () {
      expect(
        repository.mimeTypeForFile('/path/to/image.jpg'),
        equals('image/*'),
      );
    });

    test('returns image/* for .png files', () {
      expect(
        repository.mimeTypeForFile('/path/to/image.png'),
        equals('image/*'),
      );
    });

    test('returns image/* for .heic files', () {
      expect(
        repository.mimeTypeForFile('/path/to/image.heic'),
        equals('image/*'),
      );
    });

    test('CR3 MIME type is a specific type, not a wildcard', () {
      final mimeType = repository.mimeTypeForFile('/path/to/IMG_5500.CR3');
      expect(mimeType, isNot(equals('image/*')));
      expect(mimeType, isNot(contains('*')));
    });

    test('CR3 MIME type is passed to native plugin unchanged (Downloads handles it)', () {
      // MediaStore.Images rejects image/x-canon-cr3 at the OS level.
      // The native plugin routes CR3 to MediaStore.Downloads instead, which
      // accepts non-standard MIME types. The Dart layer still supplies the
      // semantically correct MIME type to the plugin.
      final mimeType = repository.mimeTypeForFile('/sdcard/DCIM/IMG_5500.CR3');
      expect(mimeType, equals('image/x-canon-cr3'));
    });

    test('returns image/x-canon-cr3 for counter-before-extension duplicate name', () {
      // The native plugin names duplicates "IMG_5595 (1).CR3"; the Dart layer
      // must still resolve the correct MIME type for such filenames.
      expect(
        repository.mimeTypeForFile('/path/to/IMG_5595 (1).CR3'),
        equals('image/x-canon-cr3'),
      );
    });

    test('returns image/* for broken counter-after-extension name (regression guard)', () {
      // "IMG_5595.CR3 (1)" has no recognised extension - confirms the old
      // broken naming would have caused a second failure at the MIME level too.
      expect(
        repository.mimeTypeForFile('/path/to/IMG_5595.CR3 (1)'),
        equals('image/*'),
      );
    });
  });
}
