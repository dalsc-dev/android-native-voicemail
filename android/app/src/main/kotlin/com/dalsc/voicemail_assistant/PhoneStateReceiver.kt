package com.dalsc.voicemail_assistant

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONArray

class PhoneStateReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "PhoneStateReceiver"
        private var lastState = TelephonyManager.EXTRA_STATE_IDLE
        private var ringingNumber = ""
        private val recentSmsDispatched = mutableMapOf<String, Long>()
        private const val DEDUP_WINDOW_MS = 15_000L // 15 seconds deduplication
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return

        val stateStr = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
        val incomingNumber = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER) ?: ""

        Log.i(TAG, "PhoneState: $stateStr, incomingNumber: $incomingNumber")

        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val isAssistantActive = prefs.getBoolean("flutter.assistant_active", true)
        val selectedMode = prefs.getString("flutter.call_handling_mode", "MODE_1_SERVER_RELAY") ?: "MODE_1_SERVER_RELAY"

        if (stateStr == TelephonyManager.EXTRA_STATE_RINGING) {
            if (incomingNumber.isNotBlank()) {
                ringingNumber = incomingNumber
            }
            if (isAssistantActive && selectedMode == "MODE_3_AUTO_ANSWER") {
                Log.i(TAG, "Mode 3 detected in PhoneStateReceiver. Starting AutoAnswerAssistantService.")
                AutoAnswerAssistantService.start(context, incomingNumber)
            }
        } else if (stateStr == TelephonyManager.EXTRA_STATE_IDLE && lastState == TelephonyManager.EXTRA_STATE_RINGING) {
            val targetNumber = if (incomingNumber.isNotBlank()) incomingNumber else ringingNumber
            ringingNumber = ""

            if (isAssistantActive && (selectedMode == "MODE_2_AUTO_DECLINE" || selectedMode == "MODE_2_AUTO_DECLINE_SMS")) {
                handleMode2Decline(context, targetNumber, prefs)
            }
        }
        lastState = stateStr
    }

    private fun handleMode2Decline(context: Context, rawNumber: String, prefs: SharedPreferences) {
        val cleanNumber = rawNumber.filter { it.isDigit() || it == '+' }
        if (cleanNumber.isEmpty()) return

        val now = System.currentTimeMillis()
        val lastSent = recentSmsDispatched[cleanNumber] ?: 0L
        if (now - lastSent < DEDUP_WINDOW_MS) {
            Log.i(TAG, "SMS already dispatched recently for $cleanNumber within dedup window. Skipping.")
            return
        }

        val targetMode = prefs.getString("flutter.auto_msg_target_mode", "ALL") ?: "ALL"
        val normalized = normalizePhoneNumber(cleanNumber)

        if (checkAutoMsgAudience(context, targetMode, normalized, prefs)) {
            val message = getEffectiveAutoReplyMessage(prefs)
            val success = sendAutoReplySms(context, cleanNumber, message)
            if (success) {
                recentSmsDispatched[cleanNumber] = now
                DiagnosticLogger.logCall(
                    context,
                    DiagnosticLogger.CallEvent(
                        rawNumber = cleanNumber,
                        carrier = "PhoneStateReceiver",
                        dndActive = true,
                        selectedMode = "MODE_2_AUTO_DECLINE",
                        ruleMatched = "AUTO_MSG_SENT",
                        decision = "DECLINE_AND_SMS",
                        latencyMs = 0L,
                        success = true
                    )
                )
            }
        } else {
            Log.i(TAG, "Caller $cleanNumber filtered by audience ($targetMode)")
            DiagnosticLogger.logCall(
                context,
                DiagnosticLogger.CallEvent(
                    rawNumber = cleanNumber,
                    carrier = "PhoneStateReceiver",
                    dndActive = true,
                    selectedMode = "MODE_2_AUTO_DECLINE",
                    ruleMatched = "AUTO_MSG_AUDIENCE_FILTERED ($targetMode)",
                    decision = "FILTERED",
                    latencyMs = 0L,
                    success = true
                )
            )
        }
    }

    private fun checkAutoMsgAudience(
        context: Context,
        targetMode: String,
        normalizedNumber: String,
        prefs: SharedPreferences
    ): Boolean {
        if (normalizedNumber.isEmpty()) return false
        return when (targetMode) {
            "ALL" -> true

            "SELECTED_ONLY" -> {
                val selectedNumbersJson = prefs.getString("flutter.auto_msg_selected_numbers", "[]") ?: "[]"
                val contactsJson = prefs.getString("flutter.auto_msg_selected_contacts", "[]") ?: "[]"
                try {
                    val arr = JSONArray(selectedNumbersJson)
                    for (i in 0 until arr.length()) {
                        val raw = arr.getString(i)
                        val num = normalizePhoneNumber(raw)
                        val digits = raw.filter { it.isDigit() }
                        if (num == normalizedNumber || digits.endsWith(normalizedNumber) || normalizedNumber.endsWith(digits)) return true
                    }
                    val contactsArr = JSONArray(contactsJson)
                    for (i in 0 until contactsArr.length()) {
                        val obj = contactsArr.getJSONObject(i)
                        val raw = obj.optString("number", "")
                        val num = normalizePhoneNumber(raw)
                        val digits = raw.filter { it.isDigit() }
                        if (num == normalizedNumber || digits.endsWith(normalizedNumber) || normalizedNumber.endsWith(digits)) return true
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error parsing selected numbers: ${e.message}")
                }
                false
            }

            "UNSAVED_ONLY" -> {
                !isContactSaved(context, normalizedNumber)
            }

            "EXCLUDE_SELECTED" -> {
                val selectedNumbersJson = prefs.getString("flutter.auto_msg_selected_numbers", "[]") ?: "[]"
                val contactsJson = prefs.getString("flutter.auto_msg_selected_contacts", "[]") ?: "[]"
                try {
                    val arr = JSONArray(selectedNumbersJson)
                    for (i in 0 until arr.length()) {
                        val raw = arr.getString(i)
                        val num = normalizePhoneNumber(raw)
                        val digits = raw.filter { it.isDigit() }
                        if (num == normalizedNumber || digits.endsWith(normalizedNumber) || normalizedNumber.endsWith(digits)) return false
                    }
                    val contactsArr = JSONArray(contactsJson)
                    for (i in 0 until contactsArr.length()) {
                        val obj = contactsArr.getJSONObject(i)
                        val raw = obj.optString("number", "")
                        val num = normalizePhoneNumber(raw)
                        val digits = raw.filter { it.isDigit() }
                        if (num == normalizedNumber || digits.endsWith(normalizedNumber) || normalizedNumber.endsWith(digits)) return false
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Error parsing excluded numbers: ${e.message}")
                }
                true
            }

            else -> true
        }
    }

    private fun isContactSaved(context: Context, number: String): Boolean {
        if (number.isEmpty()) return false
        if (ContextCompat.checkSelfPermission(context, android.Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            return false
        }
        return try {
            val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
            val projection = arrayOf(ContactsContract.PhoneLookup._ID)
            context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                cursor.moveToFirst()
            } ?: false
        } catch (e: Exception) {
            false
        }
    }

    private fun getEffectiveAutoReplyMessage(prefs: SharedPreferences): String {
        var msg = prefs.getString("flutter.active_greeting_text", null)
        if (msg.isNullOrBlank()) {
            msg = prefs.getString("flutter.dnd_msg", null)
        }
        if (msg.isNullOrBlank()) {
            msg = "Hi, Danish here. I can't take your call right now. Please WhatsApp or SMS me. Thanks!"
        }

        val includeWa = prefs.getBoolean("flutter.auto_msg_include_whatsapp", false)
        val waNumber = prefs.getString("flutter.auto_msg_whatsapp_number", "") ?: ""
        val cleanWa = waNumber.filter { it.isDigit() }
        if (includeWa && cleanWa.isNotEmpty() && !msg.contains("wa.me")) {
            msg += "\n\nChat: https://wa.me/$cleanWa"
        }

        val allowRepeat = prefs.getBoolean("flutter.dnd_allow_repeat", true)
        if (allowRepeat && !msg.contains("urgent") && !msg.contains("emergency")) {
            msg += "\n(If urgent, call back within 3 mins to ring through)"
        }

        return msg
    }

    private fun normalizePhoneNumber(phone: String): String {
        val digits = phone.filter { it.isDigit() }
        return if (digits.length >= 10) digits.takeLast(10) else digits
    }

    private fun sendAutoReplySms(context: Context, recipientNumber: String, messageText: String): Boolean {
        val cleanRecipient = recipientNumber.filter { it.isDigit() || it == '+' }
        if (cleanRecipient.isEmpty()) return false

        if (ContextCompat.checkSelfPermission(context, android.Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "SEND_SMS permission not granted. Skipping.")
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
            smsManager.sendMultipartTextMessage(cleanRecipient, null, parts, null, null)
            Log.i(TAG, "PhoneStateReceiver: Auto-reply SMS dispatched to $cleanRecipient")
            true
        } catch (e: Exception) {
            Log.e(TAG, "PhoneStateReceiver: Failed to send auto-reply SMS: ${e.message}")
            false
        }
    }
}
