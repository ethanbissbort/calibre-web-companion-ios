import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:docman/docman.dart';
import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';

import 'package:calibre_web_companion/features/offline/data/models/offline_book_model.dart';
import 'package:calibre_web_companion/features/offline/data/repositories/offline_library_repository.dart';

import 'package:calibre_web_companion/features/book_details/data/models/book_details_model.dart';
import 'package:calibre_web_companion/features/book_details/bloc/book_details_event.dart';
import 'package:calibre_web_companion/features/book_details/bloc/book_details_state.dart';

import 'package:calibre_web_companion/core/services/download_manager.dart';

import 'package:calibre_web_companion/features/book_view/data/models/book_view_model.dart';
import 'package:calibre_web_companion/core/exceptions/cancellation_exception.dart';
import 'package:calibre_web_companion/features/book_details/data/repositories/book_details_repository.dart';
import 'package:calibre_web_companion/features/book_details/data/repositories/reading_progress_repository.dart';

class BookDetailsBloc extends Bloc<BookDetailsEvent, BookDetailsState> {
  final BookDetailsRepository repository;
  final ReadingProgressRepository progressRepository;
  final DownloadManager downloadManager;
  final Logger logger;

  BookDetailsBloc({
    required this.repository,
    required this.progressRepository,
    required this.downloadManager,
    required this.logger,
  }) : super(const BookDetailsState()) {
    on<LoadBookDetails>(_onLoadBookDetails);
    on<ReloadBookDetails>(_onReloadBookDetails);
    on<ToggleReadStatus>(_onToggleReadStatus);
    on<ToggleArchiveStatus>(_onToggleArchiveStatus);
    on<DeleteBook>(_onDeleteBook);
    on<DownloadBook>(_onDownloadBook);
    on<CancelDownload>(_onCancelDownload);
    on<OpenBookInReader>(_onOpenBookInReader);
    on<OpenBookInBrowser>(_onOpenBookInBrowser);
    on<UpdateDownloadProgress>(_onUpdateDownloadProgress);
    on<UpdateBookMetadata>(_onUpdateBookMetadata);
    on<SendToEReaderViaBrowser>(_onSendToEReaderViaBrowser);
    on<SendToEReaderByEmail>(_onSendToEReaderByEmail);
    on<CancelSendToEReader>(_onCancelSendToEReader);
    on<ClearSnackBarStates>(_onClearSnackBarStates);
    on<OpenBookInInternalReader>(_openBookInInternalReader);
    on<UpdateSendToEReaderProgress>((event, emit) {
      emit(state.copyWith(sendToEReaderProgress: event.progress));
    });
    on<OpenSeries>(_onOpenSeries);
    on<LoadReadingProgress>(_onLoadReadingProgress);
    on<SyncReadingProgress>(_onSyncReadingProgress);
  }

  bool _sendToEReaderCancelled = false;

  /// Token of the device download backing a "send to e-reader" transfer.
  DownloadCancellationToken? _sendToEReaderToken;

  /// Tokens of the downloads currently in flight (device download, "open in
  /// reader" and the in-app reader stream). Tripping one aborts that transfer,
  /// removes its partial file and makes the handler report a cancellation
  /// rather than a failure.
  final Set<DownloadCancellationToken> _activeDownloadTokens = {};

  DownloadCancellationToken _startDownload() {
    final token = DownloadCancellationToken();
    _activeDownloadTokens.add(token);
    return token;
  }

  void _finishDownload(DownloadCancellationToken token) {
    _activeDownloadTokens.remove(token);
  }

  void _cancelActiveDownloads([String? reason]) {
    for (final token in _activeDownloadTokens.toList()) {
      token.cancel(reason);
    }
  }

  @override
  Future<void> close() {
    // Nobody is left to receive the result, so stop the transfers and let the
    // datasource clean up its .part files.
    _cancelActiveDownloads('Screen closed');
    _sendToEReaderToken?.cancel();
    _sendToEReaderCancelled = true;
    return super.close();
  }

  Future<void> _onLoadBookDetails(
    LoadBookDetails event,
    Emitter<BookDetailsState> emit,
  ) async {
    try {
      logger.i('Loading book details: ${event.bookUuid}');
      emit(
        state.copyWith(
          status: BookDetailsStatus.loading,
          errorMessage: null,
          isBookRead: event.bookViewModel.readStatus,
          isBookArchived: event.bookViewModel.isArchived,
        ),
      );

      final bookDetails = await repository.getBookDetails(
        event.bookViewModel,
        event.bookUuid,
      );

      final isDownloaded = await downloadManager.checkFileExistence(
        event.bookUuid,
      );

      add(LoadReadingProgress(event.bookUuid));

      logger.i(bookDetails.tags);

      emit(
        state.copyWith(
          status: BookDetailsStatus.loaded,
          bookViewModel: event.bookViewModel,
          bookDetails: bookDetails,
          isDownloaded: isDownloaded,
          isBookRead: bookDetails.readStatus,
          isBookArchived: bookDetails.isArchived,
        ),
      );
    } catch (e) {
      logger.e('Error loading book details: $e');
      emit(
        state.copyWith(
          status: BookDetailsStatus.error,
          errorMessage: e.toString(),
        ),
      );
    }
  }

  void _onClearSnackBarStates(
    ClearSnackBarStates event,
    Emitter<BookDetailsState> emit,
  ) {
    emit(
      state.copyWith(
        readStatusState: ReadStatusState.initial,
        archiveStatusState: ArchiveStatusState.initial,
        deleteBookState: DeleteBookState.initial,
        openInReaderState: OpenInReaderState.initial,
        openInInternalReaderState: OpenInInternalReaderState.initial,
        metadataUpdateState: MetadataUpdateState.initial,
        sendToEReaderState: SendToEReaderState.initial,
        seriesNavigationStatus: SeriesNavigationStatus.initial,
        errorMessage: null,
        downloadErrorMessage: null,
      ),
    );
  }

  Future<void> _onReloadBookDetails(
    ReloadBookDetails event,
    Emitter<BookDetailsState> emit,
  ) async {
    try {
      logger.i('Reloading book details: ${event.bookUuid}');
      emit(
        state.copyWith(status: BookDetailsStatus.loading, errorMessage: null),
      );

      final bookDetails = await repository.getBookDetails(
        event.bookViewModel,
        event.bookUuid,
      );

      emit(
        state.copyWith(
          status: BookDetailsStatus.loaded,
          bookDetails: bookDetails,
          isBookRead: event.bookViewModel.readStatus,
          isBookArchived: event.bookViewModel.isArchived,
          bookViewModel: event.bookViewModel,
        ),
      );
    } catch (e) {
      logger.e('Error reloading book details: $e');
      emit(
        state.copyWith(
          status: BookDetailsStatus.error,
          errorMessage: e.toString(),
        ),
      );
    }
  }

  Future<void> _onToggleReadStatus(
    ToggleReadStatus event,
    Emitter<BookDetailsState> emit,
  ) async {
    try {
      logger.i('Toggling read status: ${event.bookId}');
      emit(state.copyWith(readStatusState: ReadStatusState.loading));

      final success = await repository.toggleReadStatus(event.bookId);

      if (success) {
        emit(
          state.copyWith(
            readStatusState: ReadStatusState.success,
            isBookRead: !state.isBookRead,
          ),
        );
      } else {
        emit(
          state.copyWith(
            readStatusState: ReadStatusState.error,
            errorMessage: 'Failed to toggle read status',
          ),
        );
      }
    } catch (e) {
      logger.e('Error toggling read status: $e');
      emit(
        state.copyWith(
          readStatusState: ReadStatusState.error,
          errorMessage: e.toString(),
        ),
      );
    }
  }

  Future<void> _onToggleArchiveStatus(
    ToggleArchiveStatus event,
    Emitter<BookDetailsState> emit,
  ) async {
    try {
      logger.i('Toggling archive status: ${event.bookId}');
      emit(state.copyWith(archiveStatusState: ArchiveStatusState.loading));

      final success = await repository.toggleArchiveStatus(event.bookId);

      if (success) {
        emit(
          state.copyWith(
            archiveStatusState: ArchiveStatusState.success,
            isBookArchived: !state.isBookArchived,
          ),
        );
      } else {
        emit(
          state.copyWith(
            archiveStatusState: ArchiveStatusState.error,
            errorMessage: 'Failed to toggle archive status',
          ),
        );
      }
    } catch (e) {
      logger.e('Error toggling archive status: $e');
      emit(
        state.copyWith(
          archiveStatusState: ArchiveStatusState.error,
          errorMessage: e.toString(),
        ),
      );
    }
  }

  Future<void> _onDeleteBook(
    DeleteBook event,
    Emitter<BookDetailsState> emit,
  ) async {
    try {
      logger.i('Deleting book: ${event.bookId}');
      emit(state.copyWith(deleteBookState: DeleteBookState.loading));

      final success = await repository.deleteBook(event.bookId);

      if (success) {
        emit(state.copyWith(deleteBookState: DeleteBookState.success));
      } else {
        emit(
          state.copyWith(
            deleteBookState: DeleteBookState.error,
            errorMessage: 'Failed to delete book',
          ),
        );
      }
    } catch (e) {
      logger.e('Error deleting book: $e');
      emit(
        state.copyWith(
          deleteBookState: DeleteBookState.error,
          errorMessage: e.toString(),
        ),
      );
    }
  }

  Future<void> _onDownloadBook(
    DownloadBook event,
    Emitter<BookDetailsState> emit,
  ) async {
    logger.i(
      'Starting download for book ${event.bookId}, format: ${event.format}',
    );

    emit(
      state.copyWith(
        downloadState: DownloadState.downloading,
        downloadProgress: 0,
        downloadErrorMessage: null,
      ),
    );

    final cancelToken = _startDownload();
    final throttle = DownloadProgressThrottle();

    void reportProgress(int progress) {
      // Progress arrives per network chunk. Emitting (and logging) every one of
      // them rebuilds the UI hundreds of times per second and floods the log
      // ring buffer, so only let a bounded number through.
      if (emit.isDone) return;
      if (!throttle.shouldEmit(progress)) return;
      emit(state.copyWith(downloadProgress: progress));
    }

    try {
      if (state.bookDetails == null) {
        throw Exception('Book details not available');
      }

      final schema = event.schema;

      final String filePath;
      if (event.directory == null) {
        filePath = await repository.downloadBookToDevice(
          state.bookDetails!,
          format: event.format,
          schema: schema,
          progressCallback: reportProgress,
          cancelToken: cancelToken,
        );
      } else {
        filePath = await repository.downloadBook(
          state.bookDetails!,
          event.directory!,
          schema,
          format: event.format,
          progressCallback: reportProgress,
          cancelToken: cancelToken,
        );
      }

      final uuid = state.bookViewModel?.uuid ?? state.bookDetails!.uuid;
      await downloadManager.registerDownload(uuid, filePath);
      await _cacheOfflineSnapshot(
        uuid,
        state.bookDetails!,
        filePath,
        event.format,
      );

      logger.i('Download completed successfully: $filePath');
      emit(
        state.copyWith(
          downloadFilePath: filePath,
          downloadState: DownloadState.success,
          downloadProgress: 100,
          isDownloaded: true,
        ),
      );
    } catch (e) {
      if (e is CancellationException) {
        logger.i('Download cancelled: ${e.message}');
        if (!emit.isDone) {
          emit(
            state.copyWith(
              downloadState: DownloadState.canceled,
              downloadErrorMessage: e.message,
            ),
          );
        }
      } else {
        logger.e('Error in download process: $e');
        if (!emit.isDone) {
          emit(
            state.copyWith(
              downloadState: DownloadState.failed,
              downloadErrorMessage: e.toString(),
            ),
          );
        }
      }
    } finally {
      _finishDownload(cancelToken);
    }
  }

  void _onCancelDownload(CancelDownload event, Emitter<BookDetailsState> emit) {
    logger.i('Download cancellation requested');
    // Aborts the in-flight transfer between chunks; the download handler then
    // deletes the .part file and reports DownloadState.canceled itself.
    _cancelActiveDownloads();
    emit(state.copyWith(downloadState: DownloadState.canceled));
  }

  void _onUpdateDownloadProgress(
    UpdateDownloadProgress event,
    Emitter<BookDetailsState> emit,
  ) {
    emit(state.copyWith(downloadProgress: event.progress));
  }

  Future<void> _cacheOfflineSnapshot(
    String uuid,
    BookDetailsModel details,
    String filePath,
    String format,
  ) async {
    try {
      final coverBytes = await repository.fetchCoverBytes(
        details.id,
        details.coverUrl,
      );
      await GetIt.instance<OfflineLibraryRepository>().saveBook(
        OfflineBookModel(
          uuid: uuid,
          id: details.id,
          title: details.title,
          authors: details.authors,
          series: details.series,
          seriesIndex: details.seriesIndex,
          filePath: filePath,
          format: format,
          savedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        coverBytes: coverBytes,
      );
    } catch (e) {
      logger.w('Could not cache offline metadata: $e');
    }
  }

  Future<void> _onOpenBookInReader(
    OpenBookInReader event,
    Emitter<BookDetailsState> emit,
  ) async {
    if (state.bookDetails == null) {
      emit(
        state.copyWith(
          openInReaderState: OpenInReaderState.error,
          errorMessage: 'Book details not available',
        ),
      );
      return;
    }

    final cancelToken = _startDownload();

    try {
      logger.i('Opening book in reader: ${state.bookDetails!.title}');
      emit(
        state.copyWith(
          openInReaderState: OpenInReaderState.loading,
          downloadProgress: 0,
        ),
      );

      final details = state.bookDetails!;
      final uuid = state.bookViewModel?.uuid ?? details.uuid;
      final format =
          details.formats.isNotEmpty
              ? details.formats.first.toLowerCase()
              : 'epub';

      final throttle = DownloadProgressThrottle();

      final success = await repository.openInReader(
        details,
        event.selectedDirectory,
        event.schema,
        progressCallback: (progress) {
          if (emit.isDone) return;
          if (!throttle.shouldEmit(progress)) return;
          emit(state.copyWith(downloadProgress: progress));
        },
        onFileDownloaded: (path) async {
          await downloadManager.registerDownload(uuid, path);
          await _cacheOfflineSnapshot(uuid, details, path, format);
          emit(state.copyWith(downloadFilePath: path, isDownloaded: true));
        },
        cancelToken: cancelToken,
      );

      if (success) {
        emit(
          state.copyWith(
            openInReaderState: OpenInReaderState.success,
            downloadProgress: 100,
          ),
        );
      } else {
        emit(
          state.copyWith(
            openInReaderState: OpenInReaderState.error,
            errorMessage: 'Failed to open book in reader',
          ),
        );
      }
    } on CancellationException catch (e) {
      logger.i('Opening book in reader cancelled: ${e.message}');
      if (!emit.isDone) {
        emit(
          state.copyWith(
            openInReaderState: OpenInReaderState.initial,
            downloadState: DownloadState.canceled,
            downloadProgress: 0,
          ),
        );
      }
    } catch (e) {
      logger.e('Error opening book in reader: $e');
      if (!emit.isDone) {
        emit(
          state.copyWith(
            openInReaderState: OpenInReaderState.error,
            errorMessage: e.toString(),
          ),
        );
      }
    } finally {
      _finishDownload(cancelToken);
    }
  }

  Future<void> _openBookInInternalReader(
    OpenBookInInternalReader event,
    Emitter<BookDetailsState> emit,
  ) async {
    if (state.bookDetails == null) {
      emit(
        state.copyWith(
          openInInternalReaderState: OpenInInternalReaderState.error,
          errorMessage: 'Book details not available',
        ),
      );
      return;
    }

    final cancelToken = _startDownload();

    try {
      logger.i('Opening book in internal reader: ${state.bookDetails!.title}');
      emit(
        state.copyWith(
          openInInternalReaderState: OpenInInternalReaderState.loading,
        ),
      );

      final uuid = state.bookViewModel?.uuid ?? state.bookDetails!.uuid;

      Uint8List? bytes;

      if (await downloadManager.checkFileExistence(uuid)) {
        final path = downloadManager.getBookPath(uuid)!;
        logger.i('Trying downloaded copy for reader from: $path');
        bytes = await repository.readLocalEpubBytes(path);
      }

      if (bytes == null) {
        logger.i('Streaming EPUB bytes into reader (no local EPUB copy).');
        final throttle = DownloadProgressThrottle();
        bytes = await repository.streamBookBytes(
          event.book,
          format: event.format,
          progressCallback: (progress) {
            if (emit.isDone) return;
            if (!throttle.shouldEmit(progress)) return;
            emit(state.copyWith(downloadProgress: progress));
          },
          cancelToken: cancelToken,
        );
      }

      emit(
        state.copyWith(
          openInInternalReaderState: OpenInInternalReaderState.success,
          readerBytes: bytes,
        ),
      );
    } on CancellationException catch (e) {
      logger.i('Reader stream cancelled: ${e.message}');
      if (!emit.isDone) {
        emit(
          state.copyWith(
            openInInternalReaderState: OpenInInternalReaderState.initial,
            downloadProgress: 0,
          ),
        );
      }
    } catch (e) {
      logger.e('Error opening book in internal reader: $e');
      if (!emit.isDone) {
        emit(
          state.copyWith(
            openInInternalReaderState: OpenInInternalReaderState.error,
            errorMessage: e.toString(),
          ),
        );
      }
    } finally {
      _finishDownload(cancelToken);
    }
  }

  Future<void> _onOpenBookInBrowser(
    OpenBookInBrowser event,
    Emitter<BookDetailsState> emit,
  ) async {
    if (state.bookDetails == null) {
      return;
    }

    try {
      logger.i('Opening book in browser: ${state.bookDetails!.title}');
      await repository.openInBrowser(state.bookDetails!);
    } catch (e) {
      logger.e('Error opening book in browser: $e');
    }
  }

  Future<void> _onUpdateBookMetadata(
    UpdateBookMetadata event,
    Emitter<BookDetailsState> emit,
  ) async {
    emit(state.copyWith(metadataUpdateState: MetadataUpdateState.loading));

    try {
      final result = await repository.updateBookMetadata(
        event.bookId,
        title: event.title,
        authors: event.authors,
        comments: event.comments,
        tags: event.tags,
        series: event.series,
        seriesIndex: event.seriesIndex,
        pubdate: event.pubdate,
        publisher: event.publisher,
        languages: event.languages,
        rating: event.rating,
        coverImageBytes: event.coverImageBytes,
        coverFileName: event.coverFileName,
      );

      if (!result) {
        emit(
          state.copyWith(
            metadataUpdateState: MetadataUpdateState.error,
            errorMessage: 'Update failed',
          ),
        );
        return;
      }

      final currentVm = state.bookViewModel;
      final currentDetails = state.bookDetails;

      BookViewModel? patchedVm;
      if (currentVm != null) {
        final parsedSeriesIndex =
            int.tryParse(event.seriesIndex) ?? currentVm.seriesIndex;

        patchedVm = currentVm.copyWith(
          title: event.title,
          authors: event.authors,
          series: event.series,
          seriesIndex: parsedSeriesIndex,
          pubdate: event.pubdate,
          publishers: event.publisher,
          languages: event.languages,
        );

        logger.i(
          'Patched ViewModel created. New Publisher: ${patchedVm.publishers}',
        );

        emit(state.copyWith(bookViewModel: patchedVm));
      }

      emit(state.copyWith(metadataUpdateState: MetadataUpdateState.success));

      if (currentDetails != null) {
        final vmForReload = patchedVm ?? currentVm;

        if (vmForReload != null) {
          add(ReloadBookDetails(vmForReload, currentDetails.uuid));
        } else {
          logger.w('Cannot reload book details: bookViewModel is null');
        }
      }
    } catch (e) {
      emit(
        state.copyWith(
          metadataUpdateState: MetadataUpdateState.error,
          errorMessage: e.toString(),
        ),
      );
    }
  }

  Future<void> _onSendToEReaderViaBrowser(
    SendToEReaderViaBrowser event,
    Emitter<BookDetailsState> emit,
  ) async {
    emit(
      state.copyWith(
        sendToEReaderState: SendToEReaderState.loading,
        sendToEReaderProgress: 0,
      ),
    );

    _sendToEReaderCancelled = false;
    final sendCancelToken = DownloadCancellationToken();
    _sendToEReaderToken = sendCancelToken;

    try {
      emit(state.copyWith(sendToEReaderState: SendToEReaderState.downloading));

      final BytesBuilder bookBytesBuilder = BytesBuilder(copy: false);

      if (event.downloadToDeviceFirst) {
        if (state.bookDetails == null) {
          throw Exception('Book details not available for device download');
        }
        if (event.selectedDirectory == null || event.schema == null) {
          throw Exception('Download directory is missing');
        }

        final downloadThrottle = DownloadProgressThrottle();
        final localFileUri = await repository.downloadBook(
          state.bookDetails!,
          event.selectedDirectory!,
          event.schema!,
          format: 'epub',
          progressCallback: (progress) {
            if (_sendToEReaderCancelled || emit.isDone) return;
            if (!downloadThrottle.shouldEmit(progress)) return;
            emit(state.copyWith(sendToEReaderProgress: progress));
          },
          cancelToken: sendCancelToken,
        );

        if (_sendToEReaderCancelled) {
          emit(
            state.copyWith(sendToEReaderState: SendToEReaderState.cancelled),
          );
          return;
        }

        final downloadedFile = await DocumentFile.fromUri(localFileUri);
        if (downloadedFile == null || !downloadedFile.isFile) {
          throw Exception('Downloaded file could not be read from device');
        }

        final bytes = await downloadedFile.read();
        if (bytes == null || bytes.isEmpty) {
          throw Exception('Downloaded file is empty');
        }
        bookBytesBuilder.add(bytes);
      } else {
        final response = await repository.getDownloadStream(
          event.bookId,
          'epub',
        );

        final contentLength =
            isContentLengthComparable(response.headers)
                ? (response.contentLength ?? -1)
                : -1;
        int receivedBytes = 0;
        final streamThrottle = DownloadProgressThrottle();

        await for (final chunk in response.stream) {
          if (_sendToEReaderCancelled) {
            emit(
              state.copyWith(sendToEReaderState: SendToEReaderState.cancelled),
            );
            return;
          }

          receivedBytes += chunk.length;
          bookBytesBuilder.add(chunk);

          if (contentLength > 0) {
            final progress = (receivedBytes / contentLength * 100)
                .round()
                .clamp(0, 100);
            if (!emit.isDone && streamThrottle.shouldEmit(progress)) {
              emit(state.copyWith(sendToEReaderProgress: progress));
            }
          }
        }

        final check = checkDownloadSize(
          receivedBytes: receivedBytes,
          contentLength: contentLength,
        );
        if (!check.isUsable) {
          throw Exception(
            downloadSizeMessage(
              check,
              receivedBytes: receivedBytes,
              contentLength: contentLength,
            ),
          );
        }
      }

      if (_sendToEReaderCancelled) {
        emit(state.copyWith(sendToEReaderState: SendToEReaderState.cancelled));
        return;
      }

      final bookBytes = bookBytesBuilder.takeBytes();

      if (bookBytes.isEmpty) {
        throw Exception('Failed to download book');
      }

      emit(
        state.copyWith(
          sendToEReaderState: SendToEReaderState.uploading,
          sendToEReaderProgress: 0,
        ),
      );

      logger.i(
        'Uploading book to Send2Ereader: ${event.title}, URL: ${event.send2ereaderUrl}',
      );

      final success = await repository.uploadToSend2Ereader(
        event.send2ereaderUrl,
        event.code,
        '${event.title}.epub',
        bookBytes,
        isKindle: event.isKindle,
        onProgressUpdate: (progress) {
          if (!_sendToEReaderCancelled) {
            logger.d('Upload progress: $progress%');
            add(UpdateSendToEReaderProgress(progress));
          }
        },
      );

      if (_sendToEReaderCancelled) {
        emit(state.copyWith(sendToEReaderState: SendToEReaderState.cancelled));
        return;
      }

      emit(
        state.copyWith(
          sendToEReaderState:
              success ? SendToEReaderState.success : SendToEReaderState.error,
        ),
      );
    } catch (e) {
      if (emit.isDone) return;
      if (_sendToEReaderCancelled || e is CancellationException) {
        emit(state.copyWith(sendToEReaderState: SendToEReaderState.cancelled));
      } else {
        emit(
          state.copyWith(
            sendToEReaderState: SendToEReaderState.error,
            errorMessage: e.toString(),
          ),
        );
      }
    } finally {
      if (identical(_sendToEReaderToken, sendCancelToken)) {
        _sendToEReaderToken = null;
      }
    }
  }

  Future<void> _onSendToEReaderByEmail(
    SendToEReaderByEmail event,
    Emitter<BookDetailsState> emit,
  ) async {
    emit(
      state.copyWith(
        sendToEReaderState: SendToEReaderState.loading,
        sendToEReaderProgress: 0,
      ),
    );

    try {
      emit(state.copyWith(sendToEReaderState: SendToEReaderState.uploading));

      final success = await repository.sendBookViaEmail(
        event.bookId,
        event.format,
        0,
      );

      emit(
        state.copyWith(
          sendToEReaderState:
              success ? SendToEReaderState.success : SendToEReaderState.error,
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(
          sendToEReaderState: SendToEReaderState.error,
          errorMessage: e.toString(),
        ),
      );
    }
  }

  void _onCancelSendToEReader(
    CancelSendToEReader event,
    Emitter<BookDetailsState> emit,
  ) {
    _sendToEReaderCancelled = true;
    // Aborts a device download started for "send to e-reader" between chunks.
    _sendToEReaderToken?.cancel('Send to e-reader cancelled');
  }

  Future<void> _onOpenSeries(
    OpenSeries event,
    Emitter<BookDetailsState> emit,
  ) async {
    emit(
      state.copyWith(seriesNavigationStatus: SeriesNavigationStatus.loading),
    );

    final path = await repository.getSeriesPath(event.seriesName);

    if (path != null) {
      emit(
        state.copyWith(
          seriesNavigationStatus: SeriesNavigationStatus.success,
          seriesNavigationPath: path,
        ),
      );
      emit(
        state.copyWith(
          seriesNavigationStatus: SeriesNavigationStatus.initial,
          seriesNavigationPath: null,
        ),
      );
    } else {
      emit(
        state.copyWith(
          seriesNavigationStatus: SeriesNavigationStatus.error,
          errorMessage: 'Series not found',
        ),
      );
      emit(
        state.copyWith(seriesNavigationStatus: SeriesNavigationStatus.initial),
      );
    }
  }

  Future<void> _onLoadReadingProgress(
    LoadReadingProgress event,
    Emitter<BookDetailsState> emit,
  ) async {
    final cfi = await progressRepository.getBestLocation(event.bookUuid);

    emit(state.copyWith(startCfi: cfi));
  }

  Future<void> _onSyncReadingProgress(
    SyncReadingProgress event,
    Emitter<BookDetailsState> emit,
  ) async {
    progressRepository.saveProgress(event.bookUuid, event.locatorJson);
  }
}
