package io.github.anmirror.phone.full

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import io.github.anmirror.adb.AdbPeerProof
import io.github.anmirror.phone.AppGraph
import io.github.anmirror.phone.MIRROR_TAG

/**
 * The phone side of the ADB peer proof (ruling R58): each new ADB connection runs
 * `am broadcast -a <package>.ADB_PROOF -n <package>/.full.AdbProofReceiver --es n <nonce>` over
 * itself. The manifest makes this receiver require `android.permission.DUMP`, which only the shell
 * (and the system) hold, so the broadcast arrives only when the peer really ran the command as the
 * phone's shell, that is, when it is the phone's own adbd. The nonce goes to the pending proof;
 * nothing is logged but whether it matched.
 */
class AdbProofReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != action(context)) return
        val matched = AppGraph.get(context.applicationContext).adbProof.deliver(intent.getStringExtra(AdbPeerProof.EXTRA_NONCE))
        Log.i(MIRROR_TAG, "setup: adb proof broadcast matched=$matched")
    }

    companion object {
        fun action(context: Context): String = "${context.packageName}.ADB_PROOF"
    }
}
