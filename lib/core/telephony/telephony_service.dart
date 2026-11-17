import 'package:flutter/services.dart';

class TelephonyService {
  static const MethodChannel _channel = MethodChannel('com.dalsc.voicemail_assistant/telephony');

  static Future<String> getCarrierName() async {
    try {
      final String carrier = await _channel.invokeMethod('getCarrierName') ?? 'Unknown';
      return carrier;
    } catch (e) {
      return 'Unknown';
    }
  }

  static Future<List<Map<String, dynamic>>> getActiveSims() async {
    try {
      final List<dynamic>? sims = await _channel.invokeMethod('getActiveSims');
      if (sims != null) {
        return sims.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Sends USSD in background with automatic 4-second timeout protection
  static Future<Map<String, dynamic>> sendUssd(String ussdCode, {int subId = -1}) async {
    try {
      final dynamic result = await _channel.invokeMethod('sendUssdRequest', {
        'ussdCode': ussdCode,
        'subId': subId,
      }).timeout(const Duration(seconds: 4), onTimeout: () {
        return {
          'status': 'TIMEOUT_FALLBACK',
          'message': 'Modem USSD timeout (common on Jio/Airtel VoLTE). Sent to phone dialer.'
        };
      });
      return Map<String, dynamic>.from(result as Map);
    } on PlatformException catch (e) {
      return {'status': 'ERROR', 'message': e.message ?? e.code};
    } catch (e) {
      return {'status': 'ERROR', 'message': e.toString()};
    }
  }

  /// Directly dials the MMI code using the Android native phone dialer (standard telephony intent)
  static Future<Map<String, dynamic>> dialMmi(String ussdCode, {int subId = -1}) async {
    try {
      final dynamic result = await _channel.invokeMethod('dialMmiDirect', {
        'ussdCode': ussdCode,
        'subId': subId,
      }).timeout(const Duration(seconds: 4), onTimeout: () {
        return {
          'status': 'TIMEOUT',
          'message': 'Dialer dispatch timeout.'
        };
      });
      return Map<String, dynamic>.from(result as Map);
    } on PlatformException catch (e) {
      return {'status': 'ERROR', 'message': e.message ?? e.code};
    } catch (e) {
      return {'status': 'ERROR', 'message': e.toString()};
    }
  }

  /// Opens native Android Phone App Call Settings (TelecomManager.ACTION_SHOW_CALL_SETTINGS)
  static Future<void> openCallSettings() async {
    try {
      await _channel.invokeMethod('openCallSettings');
    } catch (_) {}
  }

  /// Sends SMS message directly via Android SmsManager and records diagnostic audit
  static Future<Map<String, dynamic>> sendSms({
    required String recipient,
    required String message,
  }) async {
    try {
      final dynamic result = await _channel.invokeMethod('sendSms', {
        'recipient': recipient,
        'message': message,
      });
      return Map<String, dynamic>.from(result as Map);
    } on PlatformException catch (e) {
      return {'success': false, 'error': e.message ?? e.code};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Checks if SEND_SMS permission is granted
  static Future<bool> isSmsPermissionGranted() async {
    try {
      final bool? granted = await _channel.invokeMethod('isSmsPermissionGranted');
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Requests SEND_SMS runtime permission
  static Future<bool> requestSmsPermission() async {
    try {
      final bool? result = await _channel.invokeMethod('requestSmsPermission');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Checks if READ_CALL_LOG permission is granted
  static Future<bool> isCallLogPermissionGranted() async {
    try {
      final bool? granted = await _channel.invokeMethod('isCallLogPermissionGranted');
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Requests READ_CALL_LOG runtime permission
  static Future<bool> requestCallLogPermission() async {
    try {
      final bool? result = await _channel.invokeMethod('requestCallLogPermission');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Retrieves live after-call message logs from SQLite
  static Future<List<Map<String, dynamic>>> getAfterCallLogs({int limit = 100}) async {
    try {
      final List<dynamic>? res = await _channel.invokeMethod('getAfterCallLogs', {'limit': limit});
      if (res != null) {
        return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Clears after-call logs from SQLite
  static Future<bool> clearAfterCallLogs() async {
    try {
      final bool? res = await _channel.invokeMethod('clearAfterCallLogs');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Checks if number has a WhatsApp account / availability
  static Future<Map<String, dynamic>> checkWhatsAppAvailability(String number, {String country = 'IN'}) async {
    try {
      final dynamic res = await _channel.invokeMethod('checkWhatsAppAvailability', {
        'number': number,
        'country': country,
      });
      if (res != null) {
        return Map<String, dynamic>.from(res as Map);
      }
      return {'isAvailable': false, 'detail': 'Check failed', 'normalizedNumber': number};
    } catch (e) {
      return {'isAvailable': false, 'detail': e.toString(), 'normalizedNumber': number};
    }
  }

  /// Triggers a test after-call event for a phone number
  static Future<Map<String, dynamic>> testAfterCallMessage(String number) async {
    try {
      final dynamic res = await _channel.invokeMethod('testAfterCallMessage', {'number': number});
      if (res != null) {
        return Map<String, dynamic>.from(res as Map);
      }
      return {'success': false, 'message': 'Unknown response'};
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  /// Directly opens personal WhatsApp chat with message pre-filled
  static Future<bool> openWhatsAppChat(String number, String message) async {
    try {
      final bool? res = await _channel.invokeMethod('openWhatsAppChat', {
        'number': number,
        'message': message,
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }
}
