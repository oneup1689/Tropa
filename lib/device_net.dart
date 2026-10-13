import 'dart:io';

import 'package:flutter/services.dart';

import 'debug_log.dart';

/// State of the network connection, asked from the Android side (null where it is not known).
class NetInfo {
  final bool online;
  final bool wifi;
  const NetInfo(this.online, this.wifi);
}

const _channel = MethodChannel('tropa/system');

Future<NetInfo?> networkInfo() async {
  if (!Platform.isAndroid) return null;
  try {
    final m = await _channel.invokeMapMethod<String, dynamic>('network');
    if (m == null) return null;
    return NetInfo(m['online'] == true, m['wifi'] == true);
  } catch (e) {
    DebugLog.instance.log('NET', 'network state unknown: $e');
    return null;
  }
}

/// Free bytes in the folder where the maps are kept, or null when it cannot be told.
Future<int?> freeStorageBytes() async {
  if (!Platform.isAndroid) return null;
  try {
    return (await _channel.invokeMethod<num>('freeBytes'))?.toInt();
  } catch (e) {
    DebugLog.instance.log('NET', 'free space unknown: $e');
    return null;
  }
}
