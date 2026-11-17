package com.dalsc.voicemail_assistant

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import android.os.Build
import android.provider.CallLog
import android.provider.ContactsContract
import android.telephony.SmsManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.util.UUID

object AfterCallMessageManager {

    private const val TAG = "AfterCallMsgManager"
    private const val CHANNEL_ID = "after_call_auto_msg_channel"
    private const val NOTIFICATION_ID_BASE = 6000

    const val ACTION_DISMISS = "com.dalsc.voicemail_assistant.ACTION_DISMISS_AFTER_CALL"
    const val ACTION_SEND_SMS = "com.dalsc.voicemail_assistant.ACTION_SEND_SMS_AFTER_CALL"
    const val EXTRA_RECIPIENT = "extra_recipient"
    const val EXTRA_MESSAGE = "extra_message"
    const val EXTRA_NOTIFICATION_ID = "extra_notification_id"

    // Deduplication tracking: number -> timestamp
    private val recentDispatches = mutableMapOf<String, Long>()
    private const val DEDUP_WINDOW_MS = 20_000L // 20 seconds dedup per call

    private val scope = CoroutineScope(Dispatchers.IO)

    fun ensureDatabase(context: Context): SQLiteDatabase {
        val dbPath = context.getDatabasePath("voicemail_app.db")
        dbPath.parentFile?.mkdirs()
        val db = SQLiteDatabase.openOrCreateDatabase(dbPath, null)
        db.execSQL("""
            CREATE TABLE IF NOT EXISTS after_call_logs (
                id TEXT PRIMARY KEY,
                caller_number TEXT NOT NULL,
                caller_name TEXT,
                call_type TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                whatsapp_found INTEGER NOT NULL,
                dispatch_method TEXT NOT NULL,
                status TEXT NOT NULL,
                reason TEXT NOT NULL
            )
        """.trimIndent())
        return db
    }

    fun processCallEnded(context: Context, fallbackNumber: String? = null, previousState: String? = null) {
        scope.launch {
            try {
                handleCallEndedInternal(context, fallbackNumber, previousState)
            } catch (e: Exception) {
                Log.e(TAG, "Error processing call ended: ${e.message}", e)
            }
        }
    }

    private fun handleCallEndedInternal(context: Context, fallbackNumber: String?, previousState: String?) {
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)

        // 1. Master Switch check
        val isAssistantActive = prefs.getBoolean("flutter.assistant_active", true)
        if (!isAssistantActive) {
            Log.i(TAG, "Master switch is OFF. After-call messaging inactive.")
            return
        }

        // 2. Feature Switch check
        val isFeatureEnabled = prefs.getBoolean("flutter.after_call_auto_msg_enabled", true)
        if (!isFeatureEnabled) {
            Log.i(TAG, "After-call auto-messaging feature is disabled in settings.")
            return
        }

        // 3. Capture Number & Call Type (Handling Android 10+ restrictions)
        val callInfo = resolveLatestCallInfo(context, fallbackNumber, previousState)
        val rawNumber = callInfo.number
        if (rawNumber.isBlank()) {
            Log.w(TAG, "Could not capture caller number. Skipping auto-message.")
            return
        }

        // 4. Normalize to E.164
        val countryCode = prefs.getString("flutter.user_selected_region", "IN") ?: "IN"
        val normalizedE164 = normalizeToE164(rawNumber, countryCode)

        // Deduplication check (within 20s)
        val now = System.currentTimeMillis()
        val lastProcessed = recentDispatches[normalizedE164] ?: 0L
        if (now - lastProcessed < DEDUP_WINDOW_MS) {
            Log.i(TAG, "Call from $normalizedE164 already processed in dedup window. Skipping duplicate.")
            return
        }
        recentDispatches[normalizedE164] = now

        // 5. Check Call Type Trigger Filter
        val triggerType = prefs.getString("flutter.after_call_trigger_type", "ANY") ?: "ANY"
        if (!matchesTrigger(callInfo.type, triggerType)) {
            Log.i(TAG, "Call type '${callInfo.type}' does not match trigger '$triggerType'. Skipped.")
            recordLog(
                context = context,
                callerNumber = normalizedE164,
                callerName = callInfo.name,
                callType = callInfo.type,
                whatsappFound = false,
                dispatchMethod = "NONE",
                status = "FILTERED_CALL_TYPE",
                reason = "Call type '${callInfo.type}' excluded by trigger filter ($triggerType)"
            )
            return
        }

        // 6. Check "Skip Saved Contacts" / "Only Unknown Numbers" filter
        val onlyUnknown = prefs.getBoolean("flutter.after_call_only_unknown", false)
        val isSavedContact = isContactSavedInPhonebook(context, normalizedE164)
        if (onlyUnknown && isSavedContact) {
            Log.i(TAG, "Caller $normalizedE164 is a saved contact (${callInfo.name}). Skipped per rule.")
            recordLog(
                context = context,
                callerNumber = normalizedE164,
                callerName = callInfo.name,
                callType = callInfo.type,
                whatsappFound = false,
                dispatchMethod = "NONE",
                status = "FILTERED_SAVED_CONTACT",
                reason = "Caller is in contacts (${callInfo.name ?: "Saved"}). Skipped per unknown-only rule."
            )
            return
        }

        // 7. Check Cooldown (e.g. 24 hours)
        val cooldownHours = prefs.getInt("flutter.after_call_cooldown_hours", 24)
        if (isCooldownActive(context, normalizedE164, cooldownHours)) {
            Log.i(TAG, "Cooldown active for $normalizedE164 ($cooldownHours h). Skipped.")
            recordLog(
                context = context,
                callerNumber = normalizedE164,
                callerName = callInfo.name,
                callType = callInfo.type,
                whatsappFound = false,
                dispatchMethod = "NONE",
                status = "BLOCKED_COOLDOWN",
                reason = "Cooldown active. Auto-message sent to this number within last $cooldownHours hours."
            )
            return
        }

        // 8. Resolve Message Template
        val defaultTemplate = "Hi, Danish here. Thanks for calling! I can't take your call right now. Please WhatsApp or SMS me. Thanks!"
        val messageText = prefs.getString("flutter.after_call_message_template", defaultTemplate)
            ?.ifBlank { defaultTemplate } ?: defaultTemplate

        // 9. Check WhatsApp availability
        val whatsappResult = checkWhatsAppAvailability(context, normalizedE164)
        Log.i(TAG, "WhatsApp status for $normalizedE164: $whatsappResult")

        val allowSmsFallback = prefs.getBoolean("flutter.after_call_sms_fallback", true)

        if (whatsappResult.isAvailable) {
            // WhatsApp is available! Dispatch WhatsApp notification / intent
            dispatchWhatsAppAction(context, normalizedE164, callInfo.name, messageText, callInfo.type)
            recordLog(
                context = context,
                callerNumber = normalizedE164,
                callerName = callInfo.name,
                callType = callInfo.type,
                whatsappFound = true,
                dispatchMethod = "WHATSAPP",
                status = "SENT_WHATSAPP_ACTION",
                reason = "WhatsApp available (${whatsappResult.detail}). 1-tap dispatch notification ready."
            )
        } else {
            // WhatsApp not available or not installed
            if (allowSmsFallback) {
                val smsSent = sendSmsFallback(context, normalizedE164, messageText)
                val status = if (smsSent) "SENT_SMS_FALLBACK" else "SMS_FAILED"
                val reason = if (smsSent)
                    "WhatsApp not found (${whatsappResult.detail}). Sent via SMS fallback."
                else
                    "WhatsApp not found. SMS delivery failed (Permission or Carrier issue)."

                recordLog(
                    context = context,
                    callerNumber = normalizedE164,
                    callerName = callInfo.name,
                    callType = callInfo.type,
                    whatsappFound = false,
                    dispatchMethod = "SMS_FALLBACK",
                    status = status,
                    reason = reason
                )
            } else {
                recordLog(
                    context = context,
                    callerNumber = normalizedE164,
                    callerName = callInfo.name,
                    callType = callInfo.type,
                    whatsappFound = false,
                    dispatchMethod = "NONE",
                    status = "SKIPPED_NO_WHATSAPP",
                    reason = "WhatsApp not available and SMS fallback is turned OFF."
                )
            }
        }
    }

    data class CallInfo(val number: String, val name: String?, val type: String)

    private fun resolveLatestCallInfo(context: Context, fallbackNumber: String?, previousState: String?): CallInfo {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALL_LOG) == PackageManager.PERMISSION_GRANTED) {
            try {
                val projection = arrayOf(
                    CallLog.Calls.NUMBER,
                    CallLog.Calls.TYPE,
                    CallLog.Calls.CACHED_NAME,
                    CallLog.Calls.DATE
                )
                val cursor = context.contentResolver.query(
                    CallLog.Calls.CONTENT_URI,
                    projection,
                    null,
                    null,
                    "${CallLog.Calls.DATE} DESC"
                )

                cursor?.use {
                    if (it.moveToFirst()) {
                        val numIdx = it.getColumnIndex(CallLog.Calls.NUMBER)
                        val typeIdx = it.getColumnIndex(CallLog.Calls.TYPE)
                        val nameIdx = it.getColumnIndex(CallLog.Calls.CACHED_NAME)
                        val dateIdx = it.getColumnIndex(CallLog.Calls.DATE)

                        val number = if (numIdx >= 0) it.getString(numIdx) ?: "" else ""
                        val rawType = if (typeIdx >= 0) it.getInt(typeIdx) else 0
                        val name = if (nameIdx >= 0) it.getString(nameIdx) else null
                        val date = if (dateIdx >= 0) it.getLong(dateIdx) else 0L

                        // Ensure call happened within the last 60 seconds
                        if (System.currentTimeMillis() - date < 60_000 && number.isNotBlank()) {
                            val typeStr = when (rawType) {
                                CallLog.Calls.MISSED_TYPE -> "MISSED"
                                CallLog.Calls.INCOMING_TYPE -> "ANSWERED"
                                CallLog.Calls.REJECTED_TYPE -> "DECLINED"
                                CallLog.Calls.BLOCKED_TYPE -> "BLOCKED"
                                else -> "ENDED"
                            }
                            return CallInfo(number, name, typeStr)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error reading CallLog: ${e.message}")
            }
        }

        // Fallback to in-memory state
        val num = fallbackNumber ?: ""
        val typeStr = if (previousState == "RINGING") "MISSED_OR_DECLINED" else "ENDED"
        val resolvedName = resolveContactName(context, num)
        return CallInfo(num, resolvedName, typeStr)
    }

    private fun matchesTrigger(callType: String, trigger: String): Boolean {
        return when (trigger.uppercase()) {
            "ANY" -> true
            "MISSED_ONLY" -> callType == "MISSED" || callType == "MISSED_OR_DECLINED"
            "DECLINED_ONLY" -> callType == "DECLINED" || callType == "MISSED_OR_DECLINED"
            "ANSWERED_ONLY" -> callType == "ANSWERED"
            else -> true
        }
    }

    fun normalizeToE164(phone: String, defaultCountry: String): String {
        val clean = phone.trim()
        if (clean.isEmpty()) return ""

        if (clean.startsWith("+")) {
            return "+" + clean.filter { it.isDigit() }
        }

        val digits = clean.filter { it.isDigit() }
        val prefix = getCountryPrefix(defaultCountry)

        if (digits.startsWith("0")) {
            // Domestic trunk prefix (e.g. 09845012345 in India/UK) -> strip leading 0 and prepend prefix
            return prefix + digits.substring(1)
        }

        if (digits.length == 10) {
            return prefix + digits
        }

        return if (digits.startsWith(prefix.filter { it.isDigit() })) "+$digits" else prefix + digits
    }

    private fun getCountryPrefix(country: String): String {
        return when (country.uppercase()) {
            "IN" -> "+91"
            "US", "CA" -> "+1"
            "GB", "UK" -> "+44"
            "AE" -> "+971"
            "AU" -> "+61"
            "SG" -> "+65"
            "DE" -> "+49"
            else -> "+91"
        }
    }

    data class WhatsAppCheckResult(val isAvailable: Boolean, val detail: String)

    fun checkWhatsAppAvailability(context: Context, normalizedE164: String): WhatsAppCheckResult {
        val pm = context.packageManager

        val isStandardInstalled = isPackageInstalled(pm, "com.whatsapp")
        val isBusinessInstalled = isPackageInstalled(pm, "com.whatsapp.w4b")

        if (!isStandardInstalled && !isBusinessInstalled) {
            return WhatsAppCheckResult(false, "WhatsApp app not installed on device")
        }

        // Check if caller is saved in Contacts and WhatsApp sync adapter registered a profile
        val hasSyncedProfile = isContactSyncedWithWhatsApp(context, normalizedE164)
        if (hasSyncedProfile) {
            return WhatsAppCheckResult(true, "Confirmed on WhatsApp (Synced Contact)")
        }

        // For unsaved numbers, WhatsApp intent protocol is available
        return WhatsAppCheckResult(true, "Available via WhatsApp Intent")
    }

    private fun isPackageInstalled(pm: PackageManager, packageName: String): Boolean {
        return try {
            pm.getPackageInfo(packageName, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun isContactSyncedWithWhatsApp(context: Context, e164: String): Boolean {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            return false
        }
        val digits = e164.filter { it.isDigit() }
        val last10 = if (digits.length >= 10) digits.takeLast(10) else digits

        return try {
            val uri = ContactsContract.Data.CONTENT_URI
            val projection = arrayOf(
                ContactsContract.Data._ID,
                ContactsContract.Data.DATA1,
                ContactsContract.Data.MIMETYPE
            )
            val selection = "${ContactsContract.Data.MIMETYPE} = ?"
            val selectionArgs = arrayOf("vnd.android.cursor.item/vnd.com.whatsapp.profile")

            context.contentResolver.query(uri, projection, selection, selectionArgs, null)?.use { cursor ->
                val data1Idx = cursor.getColumnIndex(ContactsContract.Data.DATA1)
                while (cursor.moveToNext()) {
                    if (data1Idx >= 0) {
                        val data1 = cursor.getString(data1Idx) ?: ""
                        val numDigits = data1.filter { it.isDigit() }
                        if (numDigits.endsWith(last10) || last10.endsWith(numDigits)) {
                            return true
                        }
                    }
                }
            }
            false
        } catch (e: Exception) {
            false
        }
    }

    private fun isContactSavedInPhonebook(context: Context, e164: String): Boolean {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            return false
        }
        return try {
            val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(e164))
            val projection = arrayOf(ContactsContract.PhoneLookup._ID)
            context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                cursor.moveToFirst()
            } ?: false
        } catch (_: Exception) {
            false
        }
    }

    private fun resolveContactName(context: Context, e164: String): String? {
        if (e164.isEmpty() || ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            return null
        }
        return try {
            val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(e164))
            val projection = arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME)
            context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(ContactsContract.PhoneLookup.DISPLAY_NAME)
                    if (idx >= 0) cursor.getString(idx) else null
                } else null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun isCooldownActive(context: Context, e164: String, cooldownHours: Int): Boolean {
        if (cooldownHours <= 0) return false
        val db = ensureDatabase(context)
        val cutoff = System.currentTimeMillis() - (cooldownHours * 3600L * 1000L)
        return try {
            val cursor = db.rawQuery("""
                SELECT id FROM after_call_logs 
                WHERE caller_number = ? AND status IN ('SENT_WHATSAPP_ACTION', 'SENT_SMS_FALLBACK', 'SENT_DIRECT') 
                AND timestamp > ? LIMIT 1
            """.trimIndent(), arrayOf(e164, cutoff.toString()))
            val active = cursor.use { it.moveToFirst() }
            active
        } catch (e: Exception) {
            false
        }
    }

    private fun dispatchWhatsAppAction(
        context: Context,
        e164: String,
        callerName: String?,
        messageText: String,
        callType: String
    ) {
        val cleanE164Digits = e164.filter { it.isDigit() }
        val waUri = Uri.parse("https://wa.me/$cleanE164Digits?text=${Uri.encode(messageText)}")

        val waIntent = Intent(Intent.ACTION_VIEW, waUri).apply {
            setPackage("com.whatsapp")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        // Notification channel
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "After-Call Auto-Messaging",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Heads-up alert to dispatch WhatsApp or SMS response to recent callers"
                enableVibration(true)
            }
            nm.createNotificationChannel(channel)
        }

        val notifId = NOTIFICATION_ID_BASE + (System.currentTimeMillis() % 1000).toInt()

        val pendingWaIntent = PendingIntent.getActivity(
            context,
            notifId,
            waIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Action: Send SMS fallback
        val smsActionIntent = Intent(context, CallActionReceiver::class.java).apply {
            action = ACTION_SEND_SMS
            putExtra(EXTRA_RECIPIENT, e164)
            putExtra(EXTRA_MESSAGE, messageText)
            putExtra(EXTRA_NOTIFICATION_ID, notifId)
        }
        val pendingSmsIntent = PendingIntent.getBroadcast(
            context,
            notifId + 1,
            smsActionIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val displayName = callerName ?: e164
        val title = "Message $displayName"
        val subtitle = "$callType Call ended • Tap to send WhatsApp message"

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.launcher_icon)
            .setContentTitle(title)
            .setContentText(subtitle)
            .setStyle(NotificationCompat.BigTextStyle().bigText("Pre-filled Message: \"$messageText\""))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(pendingWaIntent)
            .addAction(android.R.drawable.ic_dialog_email, "Send on WhatsApp", pendingWaIntent)
            .addAction(android.R.drawable.ic_menu_send, "Send SMS", pendingSmsIntent)
            .build()

        nm.notify(notifId, notification)
        Log.i(TAG, "Heads-up action notification posted for $displayName on $e164")
    }

    fun sendSmsFallback(context: Context, e164: String, messageText: String): Boolean {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "SEND_SMS permission not granted. Cannot send SMS fallback.")
            return false
        }
        return try {
            val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }
            val parts = smsManager.divideMessage(messageText)
            smsManager.sendMultipartTextMessage(e164, null, parts, null, null)
            Log.i(TAG, "SMS fallback successfully sent to $e164")
            true
        } catch (e: Exception) {
            Log.e(TAG, "SMS fallback failed: ${e.message}")
            false
        }
    }

    private fun recordLog(
        context: Context,
        callerNumber: String,
        callerName: String?,
        callType: String,
        whatsappFound: Boolean,
        dispatchMethod: String,
        status: String,
        reason: String
    ) {
        val db = ensureDatabase(context)
        try {
            val values = ContentValues().apply {
                put("id", "acl_${System.currentTimeMillis()}_${UUID.randomUUID().toString().take(6)}")
                put("caller_number", callerNumber)
                if (callerName != null) put("caller_name", callerName)
                put("call_type", callType)
                put("timestamp", System.currentTimeMillis())
                put("whatsapp_found", if (whatsappFound) 1 else 0)
                put("dispatch_method", dispatchMethod)
                put("status", status)
                put("reason", reason)
            }
            db.insertWithOnConflict("after_call_logs", null, values, SQLiteDatabase.CONFLICT_REPLACE)
            Log.i(TAG, "Logged after-call event: $callerNumber, status=$status, method=$dispatchMethod")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to record after-call log: ${e.message}")
        }
    }

    fun getLogs(context: Context, limit: Int = 100): List<Map<String, Any>> {
        val db = ensureDatabase(context)
        val list = mutableListOf<Map<String, Any>>()
        try {
            val cursor = db.rawQuery(
                "SELECT * FROM after_call_logs ORDER BY timestamp DESC LIMIT ?",
                arrayOf(limit.toString())
            )
            cursor.use {
                while (it.moveToNext()) {
                    val map = mutableMapOf<String, Any>()
                    map["id"] = it.getString(it.getColumnIndexOrThrow("id")) ?: ""
                    map["caller_number"] = it.getString(it.getColumnIndexOrThrow("caller_number")) ?: ""
                    map["caller_name"] = it.getString(it.getColumnIndexOrThrow("caller_name")) ?: ""
                    map["call_type"] = it.getString(it.getColumnIndexOrThrow("call_type")) ?: "ENDED"
                    map["timestamp"] = it.getLong(it.getColumnIndexOrThrow("timestamp"))
                    map["whatsapp_found"] = it.getInt(it.getColumnIndexOrThrow("whatsapp_found")) == 1
                    map["dispatch_method"] = it.getString(it.getColumnIndexOrThrow("dispatch_method")) ?: "NONE"
                    map["status"] = it.getString(it.getColumnIndexOrThrow("status")) ?: ""
                    map["reason"] = it.getString(it.getColumnIndexOrThrow("reason")) ?: ""
                    list.add(map)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error querying after_call_logs: ${e.message}")
        }
        return list
    }

    fun clearLogs(context: Context): Boolean {
        val db = ensureDatabase(context)
        return try {
            db.delete("after_call_logs", null, null)
            true
        } catch (e: Exception) {
            false
        }
    }
}
