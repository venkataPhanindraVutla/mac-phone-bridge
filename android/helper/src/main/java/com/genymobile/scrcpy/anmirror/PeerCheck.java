package com.genymobile.scrcpy.anmirror;

import com.genymobile.scrcpy.util.Ln;

import android.net.LocalServerSocket;
import android.net.LocalSocket;

import java.io.IOException;

/**
 * Android Mirroring patch P1 (see android/helper/UPSTREAM.md): only {@code adbd} may connect.
 *
 * <p>With {@code tunnel_forward=true} the helper listens on {@code localabstract:scrcpy_<scid>}, and the
 * scid is only 31 random bits. Any app on the phone could race the real client's connect and receive the
 * screen or inject input. The real client always arrives through {@code adbd}, which runs as {@code shell}
 * (uid 2000), or as root (uid 0) on debuggable builds, so every other peer is closed and the accept repeated.
 */
public final class PeerCheck {

    private static final int ROOT_UID = 0;
    private static final int SHELL_UID = 2000;

    private PeerCheck() {
        // not instantiable
    }

    public static boolean isAllowed(int uid) {
        return uid == SHELL_UID || uid == ROOT_UID;
    }

    /** {@link LocalServerSocket#accept()}, repeated until a peer passes {@link #isAllowed(int)}. */
    public static LocalSocket accept(LocalServerSocket serverSocket) throws IOException {
        while (true) {
            LocalSocket socket = serverSocket.accept();
            int uid;
            try {
                uid = socket.getPeerCredentials().getUid();
            } catch (IOException e) {
                socket.close();
                continue;
            }
            if (isAllowed(uid)) {
                return socket;
            }
            // Never logged at warn: the client reads warnings to classify failures.
            Ln.d("Refused a local connection from uid " + uid);
            socket.close();
        }
    }
}
