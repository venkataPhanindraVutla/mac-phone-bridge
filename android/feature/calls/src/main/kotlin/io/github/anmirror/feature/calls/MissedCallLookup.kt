package io.github.anmirror.feature.calls

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CallLog

/** Asks the call log whether a call that just stopped ringing was really missed. */
interface MissedCallLookup {
    /** True/false from the call log; null = cannot tell (no permission, no log). */
    fun wasMissed(number: String?, sinceMs: Long): Boolean?
}

/** Reads `CallLog.Calls` of type MISSED (READ_CALL_LOG). */
class CallLogMissedCallLookup(context: Context) : MissedCallLookup {
    private val app = context.applicationContext

    override fun wasMissed(number: String?, sinceMs: Long): Boolean? {
        if (number.isNullOrBlank()) return null // nothing to match a row against: cannot tell
        if (app.checkSelfPermission(Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED) return null
        return try {
            app.contentResolver.query(
                CallLog.Calls.CONTENT_URI,
                arrayOf(CallLog.Calls.NUMBER),
                "${CallLog.Calls.TYPE} = ? AND ${CallLog.Calls.DATE} >= ?",
                arrayOf(CallLog.Calls.MISSED_TYPE.toString(), (sinceMs - SLACK_MS).toString()),
                null,
            )?.use { c ->
                while (c.moveToNext()) if (sameNumber(number, c.getString(0))) return true
                false
            }
        } catch (e: SecurityException) {
            null
        } catch (e: RuntimeException) {
            null
        }
    }

    private companion object {
        const val SLACK_MS = 5_000L
    }
}

/** Unknown on either side matches; else the last 7 digits must agree (formats differ: +91 / national). */
internal fun sameNumber(a: String?, b: String?): Boolean {
    val x = a.orEmpty().filter(Char::isDigit)
    val y = b.orEmpty().filter(Char::isDigit)
    if (x.isEmpty() || y.isEmpty()) return true
    val n = minOf(7, x.length, y.length)
    return x.takeLast(n) == y.takeLast(n)
}
