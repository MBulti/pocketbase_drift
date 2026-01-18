import 'package:pocketbase/pocketbase.dart';

extension RecordSyncState on RecordModel {
  /// True if the record has been synced to the server.
  bool get isSynced => data['synced'] == true;

  /// True if the record has local changes waiting to be synced.
  bool get isPendingSync => data['synced'] == false;

  /// True if the record is local-only (will never sync).
  bool get isLocalOnly => data['noSync'] == true;

  /// True if the record is marked for deletion and pending sync.
  bool get isPendingDelete => data['deleted'] == true;
}
