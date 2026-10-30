package com.genymobile.scrcpy.anmirror;

import com.genymobile.scrcpy.FakeContext;
import com.genymobile.scrcpy.util.Ln;

import android.content.ClipDescription;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.Build;
import android.os.PersistableBundle;

/**
 * Android Mirroring patch P2 (see android/helper/UPSTREAM.md): clipboard autosync skips sensitive clips.
 *
 * <p>Apps mark passwords and other secrets with {@code ClipDescription.EXTRA_IS_SENSITIVE}
 * ({@code android.content.extra.IS_SENSITIVE}, documented from Android 13). Such a clip is never sent to the
 * computer automatically. An explicit copy from the computer (GET_CLIPBOARD) is unchanged.
 */
public final class SensitiveClip {

    // ClipDescription.EXTRA_IS_SENSITIVE (API 33); apps set it on older versions too.
    private static final String EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE";

    private SensitiveClip() {
        // not instantiable
    }

    public static boolean isPrimaryClipSensitive() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return false; // ClipDescription.getExtras() is API 24
        }
        try {
            ClipboardManager manager = (ClipboardManager) FakeContext.get().getSystemService(Context.CLIPBOARD_SERVICE);
            if (manager == null) {
                return false;
            }
            ClipDescription description = manager.getPrimaryClipDescription();
            if (description == null) {
                return false;
            }
            PersistableBundle extras = description.getExtras();
            return extras != null && extras.getBoolean(EXTRA_IS_SENSITIVE, false);
        } catch (RuntimeException e) {
            // If the description can't be read, don't risk sending a secret. Debug only, no content.
            Ln.d("Clip description unreadable; not synced");
            return true;
        }
    }
}
