package com.genymobile.scrcpy.anmirror;

import com.genymobile.scrcpy.FakeContext;
import com.genymobile.scrcpy.Workarounds;

import android.content.Context;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Mac Phone Bridge, hotspot.v1 (SPEC 25): turns the Wi-Fi hotspot on or off as the shell user,
 * which holds TETHER_PRIVILEGED and NETWORK_SETTINGS, and prints one line for the app:
 *
 * <pre>
 *   ok &lt;ssid hex&gt; &lt;passphrase hex&gt; &lt;security&gt;   (on; security: open, wpa2, wpa3, wpa3_transition)
 *   off                                              (off)
 *   fail refused|failed &lt;detail&gt;
 * </pre>
 *
 * Started with {@code CLASSPATH=<jar> app_process / com.genymobile.scrcpy.anmirror.Hotspot on|off}
 * over the app's own ADB link, and exits. It uses the hotspot settings the user set on the phone
 * and never changes them. The passphrase goes to stdout only (the app reads it), never to the log.
 */
public final class Hotspot {

    /** TetheringManager.TETHERING_WIFI. */
    private static final int TETHERING_WIFI = 0;
    /** TetheringManager.TETHER_ERROR_NO_ERROR. */
    private static final int NO_ERROR = 0;
    private static final long START_TIMEOUT_S = 15;

    private Hotspot() {
        // not instantiable
    }

    public static void main(String... args) {
        String line;
        try {
            Workarounds.apply();
            line = args.length == 1 && "off".equals(args[0]) ? stop() : start();
        } catch (Throwable t) {
            line = "fail failed " + t.getClass().getSimpleName();
        }
        System.out.println(line);
        System.out.flush();
        // Binder threads would keep the process alive.
        System.exit(0);
    }

    private static String start() throws Exception {
        Object tethering = FakeContext.get().getSystemService("tethering");
        if (tethering == null) {
            return "fail failed no-tethering-service";
        }
        Class<?> managerClass = tethering.getClass();
        Class<?> requestBuilderClass = Class.forName("android.net.TetheringManager$TetheringRequest$Builder");
        Object builder = requestBuilderClass.getConstructor(int.class).newInstance(TETHERING_WIFI);
        Object request = requestBuilderClass.getMethod("build").invoke(builder);
        Class<?> callbackClass = Class.forName("android.net.TetheringManager$StartTetheringCallback");

        CountDownLatch done = new CountDownLatch(1);
        AtomicInteger error = new AtomicInteger(-1);
        InvocationHandler handler = (proxy, method, methodArgs) -> {
            String name = method.getName();
            if ("onTetheringStarted".equals(name)) {
                error.set(NO_ERROR);
                done.countDown();
            } else if ("onTetheringFailed".equals(name)) {
                error.set(methodArgs != null && methodArgs.length > 0 ? (Integer) methodArgs[0] : -1);
                done.countDown();
            } else if ("hashCode".equals(name)) {
                return System.identityHashCode(proxy);
            } else if ("equals".equals(name)) {
                return proxy == methodArgs[0];
            } else if ("toString".equals(name)) {
                return "HotspotCallback";
            }
            return null;
        };
        Object callback = Proxy.newProxyInstance(callbackClass.getClassLoader(), new Class<?>[] {callbackClass}, handler);
        Executor direct = Runnable::run;
        Method startTethering = managerClass.getMethod("startTethering", request.getClass(), Executor.class, callbackClass);
        startTethering.invoke(tethering, request, direct, callback);
        if (!done.await(START_TIMEOUT_S, TimeUnit.SECONDS)) {
            return "fail failed timeout";
        }
        if (error.get() != NO_ERROR) {
            return "fail refused tether-error-" + error.get();
        }
        return config();
    }

    /** The hotspot's settings as the user set them, as an "ok" line. */
    private static String config() throws Exception {
        Object wifi = FakeContext.get().getSystemService(Context.WIFI_SERVICE);
        Object config = wifi.getClass().getMethod("getSoftApConfiguration").invoke(wifi);
        Class<?> c = config.getClass();
        String ssid = (String) c.getMethod("getSsid").invoke(config);
        String passphrase = (String) c.getMethod("getPassphrase").invoke(config);
        int security = (Integer) c.getMethod("getSecurityType").invoke(config);
        return okLine(ssid, passphrase, security);
    }

    private static String stop() throws Exception {
        Object tethering = FakeContext.get().getSystemService("tethering");
        if (tethering == null) {
            return "fail failed no-tethering-service";
        }
        tethering.getClass().getMethod("stopTethering", int.class).invoke(tethering, TETHERING_WIFI);
        return "off";
    }

    /** The "ok" line: hex so names with spaces or any bytes survive one line. */
    static String okLine(String ssid, String passphrase, int securityType) {
        return "ok " + hex(ssid) + " " + hex(passphrase) + " " + securityName(securityType);
    }

    /**
     * SoftApConfiguration.SECURITY_TYPE_*: 0 open, 1 WPA2-PSK, 2 WPA3-SAE transition, 3 WPA3-SAE;
     * 4 and 5 are OWE (open, encrypted), joined as open.
     */
    static String securityName(int type) {
        switch (type) {
            case 1: return "wpa2";
            case 2: return "wpa3_transition";
            case 3: return "wpa3";
            default: return "open";
        }
    }

    static String hex(String s) {
        if (s == null || s.isEmpty()) {
            return "-";
        }
        StringBuilder out = new StringBuilder();
        for (byte b : s.getBytes(StandardCharsets.UTF_8)) {
            out.append(String.format("%02x", b & 0xff));
        }
        return out.toString();
    }
}
