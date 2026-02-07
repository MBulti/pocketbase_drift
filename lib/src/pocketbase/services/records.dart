import 'dart:async';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;

import '../../../pocketbase_drift.dart';

class $RecordService extends RecordService with ServiceMixin<RecordModel> {
  $RecordService(this.client, this.service) : super(client, service);

  @override
  final $PocketBase client;

  @override
  final String service;

  Selectable<RecordModel> search(String query) {
    return client.db.search(query, service: service).map(
          (p0) => itemFactoryFunc({
            ...p0.data,
            'created': p0.created,
            'updated': p0.updated,
            'id': p0.id,
          }),
        );
  }

  Selectable<RecordModel> pending() {
    // This query now correctly fetches only records that are unsynced
    // AND are NOT marked as local-only.
    return client.db
        .$query(service,
            filter: "synced = false && (noSync = null || noSync = false)")
        .map(itemFactoryFunc);
  }

  Stream<RetryProgressEvent?> retryLocal({
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
    int? batch,
  }) async* {
    final items = await pending().get();
    final total = items.length;

    client.logger
        .info('Starting retry for $total pending items in service: $service');
    yield RetryProgressEvent(current: 0, total: total);

    if (total == 0) {
      return;
    }

    // Get the collection schema to identify file fields
    final collection =
        await client.db.$collections(service: service).getSingleOrNull();
    final fileFieldNames = collection?.fields
            .where((f) => f.type == 'file')
            .map((f) => f.name)
            .toList() ??
        [];

    for (var i = 0; i < total; i++) {
      final item = items[i];
      try {
        final tempId = item.id;
        client.logger.fine('Retrying item $tempId (${i + 1}/$total)');

        // The record was marked for deletion while offline.
        if (item.data['deleted'] == true) {
          await delete(
            tempId,
            requestPolicy: RequestPolicy.cacheAndNetwork,
            query: query,
            headers: headers,
          );
          client.logger.fine('Successfully synced deletion for item $tempId');

          // The record was newly created offline.
        } else if (item.data['isNew'] == true) {
          // Prepare body for creation by removing server-generated and local-only fields.
          final createBody = Map<String, dynamic>.from(item.toJson());
          createBody.remove('created');
          createBody.remove('updated');
          createBody.remove('collectionId');
          createBody.remove('collectionName');
          createBody.remove('expand');
          createBody.remove('synced');
          createBody.remove('isNew');
          createBody.remove('deleted');
          createBody.remove('noSync');

          // Get cached files for this record
          final files =
              await _getFilesForSync(tempId, item.data, fileFieldNames);

          // Also remove file field names from body since they'll be sent as multipart files
          // (The server generates new filenames anyway)
          for (final fieldName in fileFieldNames) {
            createBody.remove(fieldName);
          }

          // Create the record on the server with our local ID.
          await create(
            body: createBody,
            files: files,
            requestPolicy: RequestPolicy.cacheAndNetwork,
            query: query,
            headers: headers,
          );
          client.logger.fine(
              'Successfully synced new item with ID ${item.id} (${files.length} files)');

          // The record was an existing one that was updated offline.
        } else {
          // Get cached files for this record
          final files =
              await _getFilesForSync(tempId, item.data, fileFieldNames);

          // Prepare update body - don't include file field names
          final updateBody = Map<String, dynamic>.from(item.toJson());
          for (final fieldName in fileFieldNames) {
            updateBody.remove(fieldName);
          }

          await update(
            tempId,
            body: updateBody,
            files: files,
            requestPolicy: RequestPolicy.cacheAndNetwork,
            query: query,
            headers: headers,
          );
          client.logger.fine(
              'Successfully synced update for item $tempId (${files.length} files)');
        }
      } catch (e) {
        client.logger
            .warning('Error retrying local change for item ${item.id}', e);
        // Continue with other items even if one fails
      }
      yield RetryProgressEvent(current: i + 1, total: total);
    }

    client.logger.info('Completed retry for service: $service');
  }

  /// Retrieves cached file blobs for a record and converts them to MultipartFile.
  ///
  /// This method looks at the file field values in the record data to determine
  /// which files need to be synced, then fetches them from the local blob cache.
  Future<List<http.MultipartFile>> _getFilesForSync(
    String recordId,
    Map<String, dynamic> recordData,
    List<String> fileFieldNames,
  ) async {
    final files = <http.MultipartFile>[];

    // Get all cached files for this record
    final cachedFiles = await client.db.getFilesForRecord(recordId).get();
    if (cachedFiles.isEmpty) return files;

    // If schema lookup failed or service was referenced differently (id vs name),
    // infer candidate file fields from record payload values.
    final effectiveFileFieldNames = fileFieldNames.isNotEmpty
        ? fileFieldNames
        : _inferFileFieldNames(recordData, cachedFiles);

    if (effectiveFileFieldNames.isEmpty) {
      client.logger.warning(
          'No file fields resolved for $service/$recordId while ${cachedFiles.length} cached file blobs exist.');
      return files;
    }

    // Create a map for quick lookup by filename
    final fileByName = {for (final f in cachedFiles) f.filename: f};

    for (final fieldName in effectiveFileFieldNames) {
      final dynamic fieldValue = recordData[fieldName];
      if (fieldValue == null) continue;

      // Handle single file field
      if (fieldValue is String && fieldValue.isNotEmpty) {
        final cachedFile = fileByName[fieldValue];
        if (cachedFile != null) {
          files.add(http.MultipartFile.fromBytes(
            fieldName,
            cachedFile.data,
            filename: cachedFile.filename,
          ));
          client.logger.fine(
              'Including file "${cachedFile.filename}" for field "$fieldName" in sync');
        }
      }
      // Handle multi-file field
      else if (fieldValue is List) {
        for (final filename in fieldValue.whereType<String>()) {
          if (filename.isEmpty) continue;
          final cachedFile = fileByName[filename];
          if (cachedFile != null) {
            files.add(http.MultipartFile.fromBytes(
              fieldName,
              cachedFile.data,
              filename: cachedFile.filename,
            ));
            client.logger.fine(
                'Including file "${cachedFile.filename}" for field "$fieldName" in sync');
          }
        }
      }
    }

    return files;
  }

  List<String> _inferFileFieldNames(
    Map<String, dynamic> recordData,
    List<BlobFile> cachedFiles,
  ) {
    final cachedNames = cachedFiles.map((f) => f.filename).toSet();
    final inferred = <String>{};

    for (final entry in recordData.entries) {
      final key = entry.key;
      final value = entry.value;

      if (value is String && cachedNames.contains(value)) {
        inferred.add(key);
      } else if (value is List) {
        final hasMatch = value
            .whereType<String>()
            .any((filename) => cachedNames.contains(filename));
        if (hasMatch) {
          inferred.add(key);
        }
      }
    }

    return inferred.toList();
  }

  @override
  Future<UnsubscribeFunc> subscribe(
    String topic,
    RecordSubscriptionFunc callback, {
    String? expand,
    String? filter,
    String? fields,
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
  }) {
    return super.subscribe(
      topic,
      (e) {
        onEvent(e);
        callback(e);
      },
      expand: expand,
      filter: filter,
      fields: fields,
      query: query,
      headers: headers,
    );
  }

  Future<void> onEvent(RecordSubscriptionEvent e) async {
    if (e.record != null) {
      if (e.action == 'create') {
        await client.db.$create(
          service,
          {
            ...e.record!.toJson(),
            'deleted': false,
            'synced': true,
          },
        );
      } else if (e.action == 'update') {
        await client.db.$update(
          service,
          e.record!.id,
          {
            ...e.record!.toJson(),
            'deleted': false,
            'synced': true,
          },
        );
      } else if (e.action == 'delete') {
        await client.db.$delete(
          service,
          e.record!.id,
        );
      }
    }
  }

  Stream<RecordModel?> watchRecord(
    String id, {
    String? expand,
    String? fields,
    RequestPolicy? requestPolicy,
  }) {
    final policy = resolvePolicy(requestPolicy);
    final controller = StreamController<RecordModel?>(
      onListen: () async {
        if (policy.isNetwork) {
          try {
            await subscribe(id, (e) {});
          } catch (e) {
            client.logger
                .warning('Error subscribing to record $service/$id', e);
          }
        }
        await getOneOrNull(id,
            expand: expand, fields: fields, requestPolicy: policy);
      },
      onCancel: () async {
        if (policy.isNetwork) {
          try {
            await unsubscribe(id);
          } catch (e) {
            client.logger.fine(
                'Error unsubscribing from record $service/$id (may be intentional)',
                e);
          }
        }
      },
    );
    final stream = client.db
        .$query(
          service,
          filter: "id = '$id'",
          expand: expand,
          fields: fields,
        )
        .map(itemFactoryFunc)
        .watchSingleOrNull();
    controller.addStream(stream);
    return controller.stream;
  }

  Stream<List<RecordModel>> watchRecords({
    String? expand,
    String? filter,
    String? sort,
    int? limit,
    String? fields,
    RequestPolicy? requestPolicy,
  }) {
    final policy = resolvePolicy(requestPolicy);
    final controller = StreamController<List<RecordModel>>(
      onListen: () async {
        if (policy.isNetwork) {
          try {
            await subscribe('*', (e) {});
          } catch (e) {
            client.logger
                .warning('Error subscribing to collection $service', e);
          }
        }
        final items = await getFullList(
          requestPolicy: policy,
          filter: filter,
          expand: expand,
          sort: sort,
          fields: fields,
        );
        client.logger.fine(
            'Realtime initial full list for "$service" [${policy.name}]: ${items.length} items');
      },
      onCancel: () async {
        if (policy.isNetwork) {
          try {
            await unsubscribe('*');
          } catch (e) {
            client.logger.fine(
                'Error unsubscribing from collection $service (may be intentional)',
                e);
          }
        }
      },
    );
    final stream = client.db
        .$query(
          service,
          filter: filter,
          expand: expand,
          sort: sort,
          limit: limit,
          fields: fields,
        )
        .map(itemFactoryFunc)
        .watch();
    controller.addStream(stream);
    return controller.stream;
  }
}
