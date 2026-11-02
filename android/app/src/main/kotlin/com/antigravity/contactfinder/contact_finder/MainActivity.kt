package com.antigravity.contactfinder.contact_finder

import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.Settings
import android.telecom.TelecomManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.antigravity.contactfinder/dialer"
    private val REQUEST_ID_SET_DEFAULT_DIALER = 1234

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isDefaultDialer" -> {
                    result.success(isDefaultDialer())
                }
                "requestDefaultDialer" -> {
                    val opened = requestDefaultDialer()
                    result.success(opened)
                }
                "getCallLogs" -> {
                    val logs = getCallLogs()
                    result.success(logs)
                }
                "openNewContact" -> {
                    val number = call.argument<String>("number") ?: ""
                    openNewContact(number)
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun isDefaultDialer(): Boolean {
        return try {
            val telecomManager = getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
            telecomManager?.defaultDialerPackage == packageName
        } catch (e: Exception) {
            false
        }
    }

    private fun requestDefaultDialer(): Boolean {
        return try {
            if (isDefaultDialer()) return true

            // Try RoleManager first on Android 10+
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val roleManager = getSystemService(Context.ROLE_SERVICE) as? RoleManager
                if (roleManager != null && roleManager.isRoleAvailable(RoleManager.ROLE_DIALER)) {
                    if (!roleManager.isRoleHeld(RoleManager.ROLE_DIALER)) {
                        val intent = roleManager.createRequestRoleIntent(RoleManager.ROLE_DIALER)
                        startActivityForResult(intent, REQUEST_ID_SET_DEFAULT_DIALER)
                        return true
                    }
                }
            }

            // Fallback 1: TelecomManager intent
            try {
                val intent = Intent(TelecomManager.ACTION_CHANGE_DEFAULT_DIALER).apply {
                    putExtra(TelecomManager.EXTRA_CHANGE_DEFAULT_DIALER_PACKAGE_NAME, packageName)
                }
                startActivity(intent)
                return true
            } catch (e: Exception) {
                // Fallback 2: Open System Default Apps Settings
                val intent = Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS)
                startActivity(intent)
                return true
            }
        } catch (e: Exception) {
            // Ultimate fallback: App Info Settings
            try {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", packageName, null)
                }
                startActivity(intent)
                return true
            } catch (ex: Exception) {
                false
            }
        }
    }

    private fun getCallLogs(): List<Map<String, Any?>> {
        val callLogs = mutableListOf<Map<String, Any?>>()
        if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED) {
            return callLogs
        }

        try {
            val projection = arrayOf(
                CallLog.Calls._ID,
                CallLog.Calls.NUMBER,
                CallLog.Calls.CACHED_NAME,
                CallLog.Calls.TYPE,
                CallLog.Calls.DATE,
                CallLog.Calls.DURATION
            )

            val cursor = contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                projection,
                null,
                null,
                "${CallLog.Calls.DATE} DESC"
            )

            cursor?.use {
                val idIdx = it.getColumnIndex(CallLog.Calls._ID)
                val numberIdx = it.getColumnIndex(CallLog.Calls.NUMBER)
                val nameIdx = it.getColumnIndex(CallLog.Calls.CACHED_NAME)
                val typeIdx = it.getColumnIndex(CallLog.Calls.TYPE)
                val dateIdx = it.getColumnIndex(CallLog.Calls.DATE)
                val durationIdx = it.getColumnIndex(CallLog.Calls.DURATION)

                var count = 0
                while (it.moveToNext() && count < 200) {
                    val id = if (idIdx >= 0) it.getString(idIdx) else ""
                    val number = if (numberIdx >= 0) it.getString(numberIdx) ?: "" else ""
                    val name = if (nameIdx >= 0) it.getString(nameIdx) else null
                    val type = if (typeIdx >= 0) it.getInt(typeIdx) else 1
                    val date = if (dateIdx >= 0) it.getLong(dateIdx) else 0L
                    val duration = if (durationIdx >= 0) it.getLong(durationIdx) else 0L

                    val map = HashMap<String, Any?>()
                    map["id"] = id
                    map["number"] = number
                    map["name"] = name
                    map["type"] = type // 1: Incoming, 2: Outgoing, 3: Missed, 5: Rejected
                    map["date"] = date
                    map["duration"] = duration
                    callLogs.add(map)
                    count++
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }

        return callLogs
    }

    private fun openNewContact(phoneNumber: String) {
        try {
            val intent = Intent(Intent.ACTION_INSERT).apply {
                type = ContactsContract.Contacts.CONTENT_TYPE
                putExtra(ContactsContract.Intents.Insert.PHONE, phoneNumber)
            }
            startActivity(intent)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
