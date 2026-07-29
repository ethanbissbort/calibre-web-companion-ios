import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:docman/docman.dart';
import 'package:http/http.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:calibre_web_companion/core/exceptions/cancellation_exception.dart';
import 'package:calibre_web_companion/core/services/api_service.dart';
import 'package:calibre_web_companion/core/services/download_manager.dart';
import 'package:calibre_web_companion/features/settings/data/models/download_schema.dart';
import 'package:calibre_web_companion/features/book_details/data/models/book_details_model.dart';
import 'package:calibre_web_companion/features/book_view/data/models/book_view_model.dart';
import 'package:calibre_web_companion/core/services/tag_service.dart';
import 'package:calibre_web_companion/features/book_details/data/models/metadata_models.dart';

class BookDetailsRemoteDatasource {
  final ApiService apiService;
  final Logger logger;
  final TagService tagService;

  BookDetailsRemoteDatasource({
    required this.apiService,
    required this.logger,
    required this.tagService,
  });

  Future<BookDetailsModel> fetchBookDetails(
    BookViewModel bookListModel,
    String bookUuid,
  ) async {
    try {
      final prefs = GetIt.instance<SharedPreferences>();
      final serverType = prefs.getString('server_type');
      final isOpds =
          serverType == 'opds' ||
          serverType == 'grimmory' ||
          serverType == 'booklore';

      if (serverType == 'calibre') {
        return _fetchCalibreBookDetails(bookListModel, prefs);
      }

      if (isOpds) {
        String comments = bookListModel.data;

        if (comments.isNotEmpty) {
          comments = _removeHtmlTags(comments);
        }

        return BookDetailsModel(
          id: bookListModel.id,
          uuid: bookListModel.uuid,
          title: bookListModel.title,
          authors: bookListModel.authors,
          cover: bookListModel.coverUrl ?? '',
          formats:
              bookListModel.formats.isNotEmpty
                  ? bookListModel.formats
                  : const ['epub'],
          comments: comments,
          tags: bookListModel.tags,
        );
      }

      if (!tagService.isInitialized) {
        await tagService.initialize();
      }

      final response = await apiService.getJson(
        endpoint: '/ajax/book/$bookUuid',
        authMethod: AuthMethod.auto,
      );

      return BookDetailsModel.fromBookListModel(
        bookListModel,
        response,
        tagService,
      );
    } catch (e) {
      logger.e("Error fetching book details: $e");
      throw Exception("Failed to fetch book details: $e");
    }
  }

  String _removeHtmlTags(String htmlString) {
    final RegExp exp = RegExp(r"<[^>]*>", multiLine: true, caseSensitive: true);
    String parsedString = htmlString.replaceAll(exp, '');

    parsedString = parsedString
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");

    return parsedString.trim();
  }

  Future<BookDetailsModel> _fetchCalibreBookDetails(
    BookViewModel bookListModel,
    SharedPreferences prefs,
  ) async {
    final libraryId = prefs.getString('calibre_library_id');
    final librarySegment =
        (libraryId != null && libraryId.isNotEmpty) ? '/$libraryId' : '';

    Map<String, dynamic> data = const {};
    try {
      data = await apiService.getJson(
        endpoint: '/ajax/book/${bookListModel.id}$librarySegment',
        authMethod: AuthMethod.auto,
      );
    } catch (e) {
      logger.w(
        'Calibre book detail fetch failed, falling back to list data: $e',
      );
    }

    String joinList(dynamic value, String fallback) {
      if (value is List) return value.map((e) => e.toString()).join(', ');
      final str = value?.toString();
      return (str == null || str.isEmpty) ? fallback : str;
    }

    final formats =
        (data['formats'] as List?)?.map((e) => e.toString()).toList() ??
        (bookListModel.formats.isNotEmpty
            ? bookListModel.formats
            : const ['EPUB']);

    final tags =
        (data['tags'] as List?)?.map((e) => e.toString()).toList() ??
        bookListModel.tags;

    final seriesIndex =
        double.tryParse(data['series_index']?.toString() ?? '')?.toInt() ??
        bookListModel.seriesIndex;

    final rating = double.tryParse(data['rating']?.toString() ?? '') ?? 0.0;

    final coverUrl =
        data['cover']?.toString().isNotEmpty == true
            ? data['cover'].toString()
            : (bookListModel.coverUrl ??
                '/get/cover/${bookListModel.id}$librarySegment');

    final rawComments =
        data['comments']?.toString() ??
        (bookListModel.data.isNotEmpty ? bookListModel.data : '');

    return BookDetailsModel(
      id: bookListModel.id,
      uuid: data['uuid']?.toString() ?? bookListModel.uuid,
      title: data['title']?.toString() ?? bookListModel.title,
      authors: joinList(data['authors'], bookListModel.authors),
      cover: coverUrl,
      coverUrl: coverUrl,
      hasCover: true,
      formats: formats,
      series: data['series']?.toString() ?? bookListModel.series,
      seriesIndex: seriesIndex,
      publishers: data['publisher']?.toString() ?? bookListModel.publishers,
      languages: joinList(data['languages'], bookListModel.languages),
      pubdate: data['pubdate']?.toString() ?? bookListModel.pubdate,
      rating: rating,
      comments: _removeHtmlTags(rawComments),
      tags: tags,
      tagModels: tagService.convertTagsToModels(tags),
    );
  }

  Future<bool> toggleReadStatus(int bookId) async {
    try {
      logger.i('Toggling read status for book: $bookId');

      final response = await apiService.post(
        endpoint: '/ajax/toggleread/$bookId',
        authMethod: AuthMethod.cookie,
        useCsrf: true,
        csrfTokenUrl: '/me',
      );

      if (response.statusCode == 200) {
        logger.i('Successfully toggled read status');
        return true;
      } else {
        logger.e('Failed to toggle read status: ${response.statusCode}');
        throw Exception(
          'Failed to toggle read status (${response.statusCode})',
        );
      }
    } catch (e) {
      logger.e('Error toggling read status: $e');
      throw Exception('Error toggling read status: $e');
    }
  }

  Future<bool> toggleArchiveStatus(int bookId) async {
    try {
      logger.i('Toggling archive status for book: $bookId');

      final response = await apiService.post(
        endpoint: '/ajax/togglearchived/$bookId',
        authMethod: AuthMethod.cookie,
        useCsrf: true,
        csrfTokenUrl: '/me',
      );

      if (response.statusCode == 200) {
        logger.i('Successfully toggled archive status');
        return true;
      } else {
        logger.e('Failed to toggle archive status: ${response.statusCode}');
        throw Exception(
          'Failed to toggle archive status (${response.statusCode})',
        );
      }
    } catch (e) {
      logger.e('Error toggling archive status: $e');
      throw Exception('Error toggling archive status: $e');
    }
  }

  Future<bool> deleteBook(int bookId) async {
    try {
      logger.i('Deleting book: $bookId');

      final prefs = GetIt.instance<SharedPreferences>();
      if (prefs.getString('server_type') == 'calibre') {
        final libraryId = prefs.getString('calibre_library_id');
        final librarySegment =
            (libraryId != null && libraryId.isNotEmpty) ? '/$libraryId' : '';

        final response = await apiService.post(
          endpoint: '/cdb/delete-books/$bookId$librarySegment',
          authMethod: AuthMethod.auto,
        );

        if (response.statusCode == 200) {
          logger.i('Successfully deleted book (Calibre)');
          return true;
        }
        if (response.statusCode == 403) {
          throw Exception(
            'The Calibre server does not allow deleting (read-only mode or a '
            'user without write permission).',
          );
        }
        logger.e('Failed to delete book (Calibre): ${response.statusCode}');
        throw Exception('Failed to delete book (${response.statusCode})');
      }

      final response = await apiService.post(
        endpoint: '/delete/$bookId',
        authMethod: AuthMethod.cookie,
        useCsrf: true,
        csrfTokenUrl: '/book/$bookId',
      );

      if (response.statusCode == 200 || response.statusCode == 302) {
        logger.i('Successfully deleted book');
        return true;
      } else {
        logger.e('Failed to delete book: ${response.statusCode}');
        throw Exception('Failed to delete book (${response.statusCode})');
      }
    } catch (e) {
      logger.e('Error deleting book: $e');
      throw Exception('Error deleting book: $e');
    }
  }

  Future<String> downloadBook(
    BookDetailsModel book,
    DocumentFile selectedDirectory,
    DownloadSchema schema, {
    String format = 'epub',
    Function(int)? progressCallback,
    DownloadCancellationToken? cancelToken,
  }) async {
    return downloadBookToPath(
      book: book,
      selectedDirectory: selectedDirectory,
      schema: schema,
      format: format,
      progressCallback: progressCallback,
      cancelToken: cancelToken,
    );
  }

  Future<void> openInBrowser(BookDetailsModel book) async {
    try {
      final baseUrl = apiService.getBaseUrl();

      if (baseUrl.isEmpty) {
        logger.w('No server URL found');
        throw Exception('Server URL missing');
      }

      final Uri url = Uri.parse('$baseUrl/book/${book.id}');

      if (!await launchUrl(url)) {
        throw Exception('Could not launch $url');
      }

      logger.i('Opened book in browser: $url');
    } catch (e) {
      logger.e('Error opening book in browser: $e');
      throw Exception('Error opening book in browser: $e');
    }
  }

  Future<StreamedResponse> getDownloadStream(
    String bookId,
    String format,
  ) async {
    try {
      logger.i('Getting download stream for book: $bookId, Format: $format');

      final prefs = GetIt.instance<SharedPreferences>();
      final serverType = prefs.getString('server_type');
      final isOpds =
          serverType == 'opds' ||
          serverType == 'grimmory' ||
          serverType == 'booklore';

      String endpoint;
      AuthMethod authMethod;

      if (serverType == 'calibre') {
        final libraryId = prefs.getString('calibre_library_id');
        final librarySegment =
            (libraryId != null && libraryId.isNotEmpty) ? '/$libraryId' : '';
        endpoint = '/get/${format.toUpperCase()}/$bookId$librarySegment';
        authMethod = AuthMethod.auto;
      } else if (isOpds) {
        endpoint = '/$bookId/download';
        authMethod = AuthMethod.basic;
      } else {
        final lowerFormat = format.toLowerCase();
        endpoint = '/download/$bookId/$lowerFormat/$bookId.$lowerFormat';
        authMethod = AuthMethod.cookie;
      }

      final response = await apiService.getStream(
        endpoint: endpoint,
        authMethod: authMethod,
      );

      if (response.statusCode == 200) {
        logger.i('Successfully got download stream');
        return response;
      } else {
        logger.e('Failed to get download stream: ${response.statusCode}');
        throw Exception(
          'Failed to get download stream (${response.statusCode})',
        );
      }
    } catch (e) {
      logger.e('Error getting download stream: $e');
      throw Exception('Error getting download stream: $e');
    }
  }

  Future<List<MetadataProvider>> getMetadataProviders() async {
    try {
      final response = await apiService.get(
        endpoint: '/metadata/provider',
        authMethod: AuthMethod.cookie,
      );

      if (response.statusCode == 200) {
        logger.i(response.body);
        final dynamic decoded = json.decode(response.body);
        logger.i('Decoded metadata providers: $decoded');
        if (decoded is List) {
          return decoded.map((e) => MetadataProvider.fromJson(e)).toList();
        }
      }
      return [];
    } catch (e) {
      logger.e('Error fetching metadata providers: $e');
      return [];
    }
  }

  Future<List<MetadataSearchResult>> searchMetadata(
    String query,
    List<String> activeProviderIds,
  ) async {
    try {
      final body = {'query': query};

      final response = await apiService.post(
        endpoint: '/metadata/search',
        body: body,
        authMethod: AuthMethod.cookie,
        useCsrf: true,
        csrfTokenUrl: '/me',
        csrfOnlyInHeader: true,
        contentType: 'application/x-www-form-urlencoded',
      );

      logger.i(response.body);

      if (response.statusCode == 200) {
        logger.i(response.body);
        final List<dynamic> jsonList = json.decode(response.body);
        return jsonList.map((e) => MetadataSearchResult.fromJson(e)).toList();
      }

      logger.w('Search failed with status: ${response.statusCode}');
      return [];
    } catch (e) {
      logger.e('Error searching metadata: $e');
      throw Exception('Search failed: $e');
    }
  }

  Future<bool> updateBookMetadata(
    String bookId, {
    required String title,
    required String authors,
    required String comments,
    required String tags,
    required String series,
    required String seriesIndex,
    required String pubdate,
    required String publisher,
    required String languages,
    required double rating,
    Uint8List? coverImageBytes,
    String? coverFileName,
    String? coverUrl,
  }) async {
    try {
      final prefs = GetIt.instance<SharedPreferences>();
      if (prefs.getString('server_type') == 'calibre') {
        return _updateCalibreMetadata(
          bookId,
          prefs,
          title: title,
          authors: authors,
          comments: comments,
          tags: tags,
          series: series,
          seriesIndex: seriesIndex,
          pubdate: pubdate,
          publisher: publisher,
          languages: languages,
          rating: rating,
          coverImageBytes: coverImageBytes,
        );
      }

      final body = {
        'title': title,
        'authors': authors,
        'comments': comments,
        'tags': tags,
        'series': series,
        'series_index': seriesIndex,
        'pubdate': pubdate,
        'publisher': publisher,
        'languages': languages,
        'cover_url': coverUrl ?? '',
        'rating': rating.toString(),
        'detail_view': 'on',
      };

      http.MultipartFile multipartFile;

      if (coverImageBytes != null && coverFileName != null) {
        logger.i('Updating book metadata with cover for book: $bookId');
        multipartFile = http.MultipartFile.fromBytes(
          'btn-upload-cover',
          coverImageBytes,
          filename: coverFileName,
          contentType: MediaType('image', 'jpeg'),
        );
      } else {
        logger.i(
          'Updating book metadata (forcing multipart) for book: $bookId',
        );
        multipartFile = http.MultipartFile.fromBytes(
          'btn-upload-cover',
          [],
          filename: '',
          contentType: MediaType('application', 'octet-stream'),
        );
      }

      final response = await apiService.post(
        endpoint: '/admin/book/$bookId',
        body: body,
        authMethod: AuthMethod.cookie,
        files: [multipartFile],
        useCsrf: true,
        csrfTokenUrl: '/me',
      );

      if (response.statusCode == 302) {
        logger.i('Successfully updated book metadata');
        return true;
      } else {
        logger.e(
          'Failed to update book metadata: ${response.statusCode} - ${response.body}',
        );
        return false;
      }
    } catch (e) {
      logger.e('Error updating book metadata: $e');
      throw Exception('Failed to update book metadata: $e');
    }
  }

  Future<bool> _updateCalibreMetadata(
    String bookId,
    SharedPreferences prefs, {
    required String title,
    required String authors,
    required String comments,
    required String tags,
    required String series,
    required String seriesIndex,
    required String pubdate,
    required String publisher,
    required String languages,
    required double rating,
    Uint8List? coverImageBytes,
  }) async {
    final libraryId = prefs.getString('calibre_library_id');
    final librarySegment =
        (libraryId != null && libraryId.isNotEmpty) ? '/$libraryId' : '';

    List<String> splitList(String value) =>
        value
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();

    final changes = <String, dynamic>{
      'title': title,
      'authors': splitList(authors),
      'tags': splitList(tags),
      'comments': comments,
      'publisher': publisher,
      'rating': (rating * 2).round(),
    };

    if (series.trim().isNotEmpty) {
      changes['series'] = series.trim();
      final idx = double.tryParse(seriesIndex.trim().replaceAll(',', '.'));
      if (idx != null) changes['series_index'] = idx;
    } else {
      changes['series'] = null;
    }

    if (pubdate.trim().isNotEmpty) {
      changes['pubdate'] = pubdate.trim();
    }

    if (coverImageBytes != null && coverImageBytes.isNotEmpty) {
      changes['cover'] = base64Encode(coverImageBytes);
    }

    final id = int.tryParse(bookId) ?? 0;

    final response = await apiService.post(
      endpoint: '/cdb/set-fields/$bookId$librarySegment',
      authMethod: AuthMethod.auto,
      contentType: 'application/json',
      body: {
        'changes': changes,
        'loaded_book_ids': [id],
      },
    );

    if (response.statusCode == 200) {
      logger.i('Calibre metadata updated for book $bookId');
      return true;
    }
    if (response.statusCode == 403) {
      throw Exception(
        'The Calibre server does not allow changes (read-only mode or a user '
        'without write permission).',
      );
    }
    logger.e(
      'Calibre set-fields failed: ${response.statusCode} - ${response.body}',
    );
    throw Exception('Failed to update metadata (${response.statusCode})');
  }

  /// Directory used to stage downloads that cannot be streamed straight to
  /// their final location (the Android SAF path).
  Future<Directory> _stagingDirectory() async {
    final temp = await getTemporaryDirectory();
    final dir = Directory(path.join(temp.path, downloadStagingDirectoryName));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } catch (e) {
      logger.w('Could not delete temporary file ${file.path}: $e');
    }
  }

  Future<void> _closeQuietly(IOSink sink) async {
    try {
      await sink.close();
    } catch (_) {
      // The sink is already broken; nothing useful left to do.
    }
  }

  /// The announced body length, but only when it can be compared against the
  /// number of bytes we actually read (see [isContentLengthComparable]).
  int _comparableContentLength(StreamedResponse response) {
    if (!isContentLengthComparable(response.headers)) return -1;
    return response.contentLength ?? -1;
  }

  /// Fails loudly when a transfer was cut short, so a truncated book is never
  /// registered as a complete one.
  void _validateReceivedSize({
    required int receivedBytes,
    required int contentLength,
    required String title,
  }) {
    final check = checkDownloadSize(
      receivedBytes: receivedBytes,
      contentLength: contentLength,
    );
    final message = downloadSizeMessage(
      check,
      receivedBytes: receivedBytes,
      contentLength: contentLength,
    );

    if (!check.isUsable) {
      logger.e('Download of "$title" failed validation: $message');
      throw Exception(message);
    }
    if (check == DownloadSizeCheck.overrun) {
      logger.w('Download of "$title": $message');
    }
  }

  /// Streams the download for [book] into [partFile].
  ///
  /// Memory stays flat: chunks go straight to disk through an [IOSink] instead
  /// of being accumulated in a list, so even a multi-hundred-megabyte PDF does
  /// not risk an OOM/jetsam kill. Returns the number of bytes written.
  ///
  /// On any failure — including cancellation and a truncated transfer —
  /// [partFile] is deleted before the error propagates, so a half-written file
  /// can never be mistaken for a book.
  Future<int> _streamToPartFile({
    required BookDetailsModel book,
    required String format,
    required File partFile,
    Function(int)? progressCallback,
    DownloadCancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();

    final parent = partFile.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
    await _deleteQuietly(partFile);

    final response = await getDownloadStream(book.id.toString(), format);
    final contentLength = _comparableContentLength(response);

    logger.i(
      'Download response status: ${response.statusCode}, '
      'Content length: $contentLength',
    );

    final sink = partFile.openWrite();
    try {
      final received = await pumpDownloadStream(
        source: response.stream,
        sink: sink,
        expectedLength: contentLength,
        onProgress:
            progressCallback == null ? null : (p) => progressCallback(p),
        cancelToken: cancelToken,
      );

      await sink.flush();
      await sink.close();

      _validateReceivedSize(
        receivedBytes: received,
        contentLength: contentLength,
        title: book.title,
      );

      return received;
    } catch (e) {
      await _closeQuietly(sink);
      await _deleteQuietly(partFile);
      rethrow;
    }
  }

  /// Removes a document we created in a SAF directory, used to clean up after a
  /// failed write. Tries the underscore variant too, because SAF replaces
  /// spaces in display names.
  Future<void> _deleteSafFile(DocumentFile directory, String fileName) async {
    final candidates = <String>{fileName, fileName.replaceAll(' ', '_')};
    for (final candidate in candidates) {
      try {
        final doc = await directory.find(candidate);
        if (doc != null && doc.isFile) {
          await doc.delete();
          logger.i('Removed incomplete file $candidate');
          return;
        }
      } catch (e) {
        logger.w('Could not remove incomplete file $candidate: $e');
      }
    }
  }

  Future<DocumentFile> _getOrCreateDirectory(
    DocumentFile parent,
    String name,
  ) async {
    final existing = await parent.find(name);
    if (existing != null && existing.isDirectory) {
      return existing;
    }
    return await parent.createDirectory(name) ?? parent;
  }

  /// Downloads [book] into a SAF directory.
  ///
  /// [deleteOnError] removes the document again when the write fails, so a
  /// broken transfer never leaves a corrupt file at the destination.
  Future<String> downloadBookToPath({
    required BookDetailsModel book,
    required DocumentFile selectedDirectory,
    required DownloadSchema schema,
    String format = 'epub',
    Function(int)? progressCallback,
    bool reuseExistingFile = true,
    bool deleteOnError = true,
    DownloadCancellationToken? cancelToken,
  }) async {
    try {
      logger.i(
        'Downloading book: ${book.title}, Format: $format, Schema: $schema, Directory: $selectedDirectory',
      );
      final safeTitle = book.title.replaceAll(RegExp(r'[\\/:*?"<>|.]'), '');
      final safeAuthor = book.authors.replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
      final safeAuthorSort = book.authorSort.replaceAll(
        RegExp(r'[\\/:*?"<>|]'),
        '',
      );

      final fileName = '$safeTitle.$format';

      DocumentFile targetDir = selectedDirectory;
      String? safeSeries;

      if (book.series.isNotEmpty) {
        safeSeries = book.series.replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
      }

      switch (schema) {
        case DownloadSchema.flat:
          break;
        case DownloadSchema.authorOnly:
          targetDir = await _getOrCreateDirectory(
            selectedDirectory,
            safeAuthor,
          );
          break;
        case DownloadSchema.authorBook:
          final authorDir = await _getOrCreateDirectory(
            selectedDirectory,
            safeAuthor,
          );
          targetDir = await _getOrCreateDirectory(authorDir, safeTitle);
          break;
        case DownloadSchema.authorSeriesBook:
          final authorDir = await _getOrCreateDirectory(
            selectedDirectory,
            safeAuthor,
          );
          if (safeSeries != null && safeSeries.isNotEmpty) {
            final seriesDir = await _getOrCreateDirectory(
              authorDir,
              safeSeries,
            );
            targetDir = await _getOrCreateDirectory(seriesDir, safeTitle);
          } else {
            targetDir = await _getOrCreateDirectory(authorDir, safeTitle);
          }
          break;
        case DownloadSchema.authorSortOnly:
          targetDir = await _getOrCreateDirectory(
            selectedDirectory,
            safeAuthorSort,
          );
          break;
        case DownloadSchema.authorSortBook:
          final authorDir = await _getOrCreateDirectory(
            selectedDirectory,
            safeAuthorSort,
          );
          targetDir = await _getOrCreateDirectory(authorDir, safeTitle);
          break;
        case DownloadSchema.authorSortSeriesBook:
          final authorDir = await _getOrCreateDirectory(
            selectedDirectory,
            safeAuthorSort,
          );
          if (safeSeries != null && safeSeries.isNotEmpty) {
            final seriesDir = await _getOrCreateDirectory(
              authorDir,
              safeSeries,
            );
            targetDir = await _getOrCreateDirectory(seriesDir, safeTitle);
          } else {
            targetDir = await _getOrCreateDirectory(authorDir, safeTitle);
          }
          break;
      }

      final existingFile = await targetDir.find(fileName.replaceAll(' ', '_'));

      if (reuseExistingFile && existingFile != null && existingFile.isFile) {
        logger.w('File already exists: $fileName');
        return existingFile.uri.toString();
      }

      // SAF exposes no atomic "write then rename" primitive we can drive from
      // Dart — docman can only create a document from a complete byte array.
      // Staging the transfer in a private .part file first buys the guarantee
      // that matters: the document at the final location is only ever created
      // from a fully received and validated payload, so a cancelled or
      // truncated download never leaves a half-written book behind. The cost is
      // holding the book in memory for the single platform-channel hand-off,
      // which is still one copy instead of the three the growing List<int> used
      // to need.
      final stagingDir = await _stagingDirectory();
      final staging = File(
        path.join(
          stagingDir.path,
          '${DateTime.now().microsecondsSinceEpoch}_$fileName'
          '$downloadPartSuffix',
        ),
      );

      try {
        final receivedBytes = await _streamToPartFile(
          book: book,
          format: format,
          partFile: staging,
          progressCallback: progressCallback,
          cancelToken: cancelToken,
        );

        cancelToken?.throwIfCancelled();

        final Uint8List fileData = await staging.readAsBytes();

        final createdFile = await targetDir.createFile(
          name: fileName,
          bytes: fileData,
        );

        if (createdFile == null) {
          logger.e('Failed to create file in SAF directory');
          throw Exception('Failed to create file in SAF directory');
        }

        logger.i(
          'Download complete: ${createdFile.uri} with $receivedBytes bytes',
        );
        return createdFile.uri;
      } catch (e) {
        // Only clean up when nothing was there before: a failed re-download
        // must not destroy the copy the user already had.
        if (deleteOnError && existingFile == null) {
          await _deleteSafFile(targetDir, fileName);
        }
        rethrow;
      } finally {
        await _deleteQuietly(staging);
      }
    } on CancellationException {
      logger.i('Download cancelled: ${book.title}');
      rethrow;
    } catch (e) {
      logger.e('Exception while downloading book: $e');
      throw Exception('Error downloading book: $e');
    }
  }

  Future<bool> sendBookViaEmail(
    String bookId,
    String format,
    int conversion,
  ) async {
    try {
      logger.i(
        'Sending book via email - BookId: $bookId, Format: $format, Conversion: $conversion',
      );

      final response = await apiService.post(
        endpoint: '/send/$bookId/$format/$conversion',
        authMethod: AuthMethod.cookie,
        useCsrf: true,
        csrfTokenUrl: '/me',
      );

      if (response.statusCode == 200) {
        logger.i('Successfully sent book via email');
        return true;
      } else {
        logger.e('Failed to send book via email: ${response.statusCode}');
        throw Exception('Failed to send email (${response.statusCode})');
      }
    } catch (e) {
      logger.e('Error sending book via email: $e');
      throw Exception('Error sending book via email: $e');
    }
  }

  Future<bool> openInReader(
    BookDetailsModel book,
    DocumentFile? selectedDirectory,
    DownloadSchema schema, {
    Function(int)? progressCallback,
    Future<void> Function(String path)? onFileDownloaded,
    DownloadCancellationToken? cancelToken,
  }) async {
    try {
      logger.i('Opening book in reader: ${book.title}');

      String format = 'epub';
      if (book.formats.isNotEmpty) {
        format = book.formats.first.toLowerCase();
      }

      String localPath;
      String durablePath;
      if (selectedDirectory == null) {
        localPath = await downloadBookToDevice(
          book,
          format: format,
          schema: schema,
          progressCallback: progressCallback,
          cancelToken: cancelToken,
        );
        durablePath = localPath;
      } else {
        final filePath = await downloadBookToPath(
          book: book,
          selectedDirectory: selectedDirectory,
          schema: schema,
          format: format,
          progressCallback: progressCallback,
          cancelToken: cancelToken,
        );

        final file =
            filePath.isNotEmpty ? await DocumentFile.fromUri(filePath) : null;

        if (file == null || !file.isFile) {
          logger.e('Downloaded file is not a valid file: $filePath');
          return false;
        }

        final cachedFile = await file.cache();
        if (cachedFile == null) {
          logger.e('Could not cache file for opening');
          return false;
        }
        localPath = cachedFile.path;
        durablePath = filePath;
      }

      await onFileDownloaded?.call(durablePath);

      final result = await OpenFile.open(localPath);

      if (result.type != ResultType.done) {
        logger.e('Error while opening the file: ${result.message}');
        throw Exception('Error while opening: ${result.message}');
      }

      logger.i('Opened book successfully');
      return true;
    } on CancellationException {
      logger.i('Opening book in reader cancelled: ${book.title}');
      rethrow;
    } catch (e) {
      logger.e('Error opening book in reader: $e');
      throw Exception('Error opening book in reader: $e');
    }
  }

  Future<bool> addBookToShelf(String shelfId, String bookId) async {
    try {
      logger.i('Adding book $bookId to shelf $shelfId');

      final response = await apiService.post(
        endpoint: '/shelf/add/$shelfId/$bookId',
        authMethod: AuthMethod.cookie,
        useCsrf: true,
        csrfTokenUrl: '/me',
        contentType: 'application/x-www-form-urlencoded',
      );

      if (response.statusCode == 200 ||
          response.statusCode == 204 ||
          response.statusCode == 302) {
        logger.i('Successfully added book to shelf');
        return true;
      } else {
        logger.e('Failed to add book to shelf: ${response.statusCode}');
        throw Exception('Failed to add book to shelf (${response.statusCode})');
      }
    } catch (e) {
      logger.e('Error adding book to shelf: $e');
      throw Exception('Error adding book to shelf: $e');
    }
  }

  Future<bool> removeBookFromShelf(String shelfId, String bookId) async {
    try {
      logger.i('Removing book $bookId from shelf $shelfId');

      final response = await apiService.post(
        endpoint: '/shelf/remove/$shelfId/$bookId',
        authMethod: AuthMethod.cookie,
        useCsrf: true,
        csrfTokenUrl: '/me',
        contentType: 'application/x-www-form-urlencoded',
      );

      if (response.statusCode == 200 ||
          response.statusCode == 204 ||
          response.statusCode == 302) {
        logger.i('Successfully removed book from shelf');
        return true;
      } else {
        logger.e('Failed to remove book from shelf: ${response.statusCode}');
        throw Exception(
          'Failed to remove book from shelf (${response.statusCode})',
        );
      }
    } catch (e) {
      logger.e('Error removing book from shelf: $e');
      throw Exception('Error removing book from shelf: $e');
    }
  }

  Future<StreamedResponse> getDownloadStreamWithProgress(
    String bookId,
    String format,
  ) async {
    try {
      logger.i(
        'Getting download stream with progress - BookId: $bookId, Format: $format',
      );

      final lowerFormat = format.toLowerCase();

      final response = await apiService.getStream(
        endpoint: '/download/$bookId/$lowerFormat/$bookId.$lowerFormat',
        authMethod: AuthMethod.cookie,
      );

      if (response.statusCode == 200) {
        logger.i('Successfully got download stream with progress tracking');
        return response;
      } else {
        logger.e('Failed to get download stream: ${response.statusCode}');
        throw Exception(
          'Failed to get download stream (${response.statusCode})',
        );
      }
    } catch (e) {
      logger.e('Error getting download stream with progress: $e');
      throw Exception('Error getting download stream: $e');
    }
  }

  Future<Uint8List?> fetchCoverBytes(int bookId, String? coverUrl) async {
    try {
      String endpoint;
      if (coverUrl != null && coverUrl.isNotEmpty) {
        var clean = coverUrl.split('/api/v1/opds/').last;
        if (clean.startsWith('/')) clean = clean.substring(1);
        endpoint = '/$clean';
      } else {
        endpoint = '/opds/cover/$bookId';
      }
      final response = await apiService.get(
        endpoint: endpoint,
        authMethod: AuthMethod.auto,
      );
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        return response.bodyBytes;
      }
    } catch (e) {
      logger.w('Could not fetch cover bytes for $bookId: $e');
    }
    return null;
  }

  /// Reads a book fully into memory.
  ///
  /// Only for consumers that genuinely need the bytes (the in-app reader).
  /// Anything that ends up on disk must use [downloadBookToDevice] or
  /// [downloadBookToPath], which stream to a file instead.
  Future<Uint8List> streamBookBytes(
    BookDetailsModel book, {
    String format = 'epub',
    Function(int)? progressCallback,
    DownloadCancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();

    final response = await getDownloadStream(book.id.toString(), format);
    final contentLength = _comparableContentLength(response);

    // BytesBuilder(copy: false) keeps the chunks as they arrive and joins them
    // once, instead of repeatedly growing and re-copying a List<int>.
    final builder = BytesBuilder(copy: false);
    int received = 0;

    await for (final chunk in response.stream) {
      cancelToken?.throwIfCancelled();

      builder.add(chunk);
      received += chunk.length;

      if (contentLength > 0 && progressCallback != null) {
        progressCallback(
          (received / contentLength * 100).round().clamp(0, 100),
        );
      }
    }

    cancelToken?.throwIfCancelled();

    _validateReceivedSize(
      receivedBytes: received,
      contentLength: contentLength,
      title: book.title,
    );

    return builder.takeBytes();
  }

  /// Mirrors the SAF schema layout of [downloadBookToPath] for plain
  /// filesystem targets (iOS/macOS app sandbox and other non-SAF platforms).
  Future<Directory> _getOrCreateLocalSchemaDirectory(
    Directory baseDir,
    BookDetailsModel book,
    DownloadSchema schema,
  ) async {
    final safeTitle =
        book.title.replaceAll(RegExp(r'[\\/:*?"<>|.]'), '').trim();
    final safeAuthor =
        book.authors.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    final safeAuthorSort =
        book.authorSort.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
    final safeSeries =
        book.series.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();

    final segments = <String>[];

    switch (schema) {
      case DownloadSchema.flat:
        break;
      case DownloadSchema.authorOnly:
        segments.add(safeAuthor);
        break;
      case DownloadSchema.authorBook:
        segments.addAll([safeAuthor, safeTitle]);
        break;
      case DownloadSchema.authorSeriesBook:
        segments.add(safeAuthor);
        if (safeSeries.isNotEmpty) segments.add(safeSeries);
        segments.add(safeTitle);
        break;
      case DownloadSchema.authorSortOnly:
        segments.add(safeAuthorSort);
        break;
      case DownloadSchema.authorSortBook:
        segments.addAll([safeAuthorSort, safeTitle]);
        break;
      case DownloadSchema.authorSortSeriesBook:
        segments.add(safeAuthorSort);
        if (safeSeries.isNotEmpty) segments.add(safeSeries);
        segments.add(safeTitle);
        break;
    }

    segments.removeWhere((segment) => segment.isEmpty);

    if (segments.isEmpty) {
      return baseDir;
    }

    final targetDir = Directory(path.joinAll([baseDir.path, ...segments]));
    if (!targetDir.existsSync()) {
      await targetDir.create(recursive: true);
    }
    return targetDir;
  }

  /// Downloads [book] into the app sandbox (iOS/macOS and any other non-SAF
  /// platform).
  ///
  /// The payload is streamed into a sibling `.part` file, validated and only
  /// then renamed onto [fileName]. The rename is atomic within the directory,
  /// so a file at the final path is always a complete book — even if the app is
  /// killed mid-transfer.
  Future<String> downloadBookToDevice(
    BookDetailsModel book, {
    String format = 'epub',
    DownloadSchema schema = DownloadSchema.flat,
    Function(int)? progressCallback,
    bool reuseExistingFile = true,
    DownloadCancellationToken? cancelToken,
  }) async {
    logger.i(
      'Downloading "${book.title}" to app sandbox, format: $format, schema: $schema',
    );

    final dir = await getApplicationDocumentsDirectory();
    final safeTitle =
        book.title.replaceAll(RegExp(r'[\\/:*?"<>|.]'), '').trim();
    final fileName = '${safeTitle.isEmpty ? 'book' : safeTitle}.$format';

    final targetDir = await _getOrCreateLocalSchemaDirectory(dir, book, schema);
    final file = File(path.join(targetDir.path, fileName));

    if (reuseExistingFile && file.existsSync()) {
      logger.w('File already exists: ${file.path}');
      return file.path;
    }

    final partFile = File('${file.path}$downloadPartSuffix');

    final received = await _streamToPartFile(
      book: book,
      format: format,
      partFile: partFile,
      progressCallback: progressCallback,
      cancelToken: cancelToken,
    );

    try {
      if (file.existsSync()) {
        await file.delete();
      }
      await partFile.rename(file.path);
    } catch (e) {
      logger.e('Could not publish downloaded file to ${file.path}: $e');
      await _deleteQuietly(partFile);
      rethrow;
    }

    logger.i('Saved book to ${file.path} ($received bytes)');
    return file.path;
  }

  Future<Uint8List?> readLocalEpubBytes(String path) async {
    try {
      String name;
      Uint8List bytes;

      if (Platform.isAndroid &&
          (path.startsWith('content://') || path.startsWith('file://'))) {
        final doc = await DocumentFile.fromUri(path);
        if (doc == null || !doc.isFile) return null;
        name = doc.name;
        final read = await doc.read();
        if (read == null || read.isEmpty) return null;
        bytes = read;
      } else {
        final file = File(path);
        if (!file.existsSync()) return null;
        name = file.path.split('/').last;
        bytes = await file.readAsBytes();
        if (bytes.isEmpty) return null;
      }

      final lower = name.toLowerCase();
      final isEpubName = lower.endsWith('.epub') || lower.endsWith('.kepub');
      final looksLikeZip =
          bytes.length >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B;

      if (!isEpubName || !looksLikeZip) {
        logger.i(
          'Local copy "$name" is not a readable EPUB — will stream instead.',
        );
        return null;
      }

      return Uint8List.fromList(bytes);
    } catch (e) {
      logger.w('Could not read local copy ($path), will stream instead: $e');
      return null;
    }
  }

  Future<bool> uploadToSend2Ereader(
    String url,
    String code,
    String filename,
    List<int> bookBytes, {
    bool isKindle = false,
    Function(int)? onProgressUpdate,
  }) async {
    try {
      logger.i(
        'Uploading to send2ereader - URL: $url, Code: $code, Kindle: $isKindle',
      );

      url = url.endsWith('/') ? url.substring(0, url.length - 1) : url;

      final request = http.MultipartRequest('POST', Uri.parse("$url/upload"));

      request.fields['key'] = code;
      request.fields['kepubify'] = (!isKindle).toString();
      request.fields['kindlegen'] = isKindle.toString();

      final multipartFile = http.MultipartFile.fromBytes(
        'file',
        bookBytes,
        filename: path.basename(filename),
      );
      request.files.add(multipartFile);

      _updateProgressWithDelay(onProgressUpdate, [20, 40, 70, 90, 100]);

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();
      final success = response.statusCode == 200;

      if (success) {
        logger.i('Successfully uploaded to send2ereader');
      } else {
        logger.e(
          'Failed to upload: ${response.statusCode}, Body: $responseBody',
        );
      }

      return success;
    } catch (e) {
      logger.e('Error uploading to send2ereader: $e');
      return false;
    }
  }

  Future<void> _updateProgressWithDelay(
    Function(int)? progressCallback,
    List<int> progressSteps,
  ) async {
    if (progressCallback == null) return;

    for (final progress in progressSteps) {
      progressCallback(progress);
      if (progress < progressSteps.last) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  Future<String?> getSeriesPath(String seriesName) async {
    try {
      if (seriesName.isEmpty) return null;

      final response = await apiService.getXmlAsJson(
        endpoint: '/opds/series/letter/00',
        authMethod: AuthMethod.auto,
      );

      final entriesRaw = response["feed"]['entry'];

      logger.d(entriesRaw);

      List<dynamic> entries = [];

      if (entriesRaw is List) {
        entries = entriesRaw;
      } else if (entriesRaw is Map) {
        entries = [entriesRaw];
      }

      for (var entry in entries) {
        final title = entry['title'] as String?;
        logger.i(title);
        if (title != null && title.toLowerCase() == seriesName.toLowerCase()) {
          return entry['id'] as String?;
        }
      }

      return null;
    } catch (e) {
      logger.e('Error finding series path: $e');
      return null;
    }
  }
}
