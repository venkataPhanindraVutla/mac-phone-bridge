// phone-sim: a command-line phone for interop tests. It runs the real :core:connection code
// (TlsConnector, PhonePairingClient, exchangeHello, PhoneSession) with a PKCS#12 identity and a
// JSON file store in --state-dir, and prints one machine-readable line per event.
//
// Output lines (stdout, flushed per line):
//   ID <phone-id>
//   EVENT code <6 digits>
//   EVENT paired <mac-id>
//   EVENT connected shared=<a,b>
//   EVENT ring
//   EVENT stop
//   EVENT mac-ping                                          (with --liveness; one per Mac system.ping answered)
//   EVENT files-received bytes=<n> sha256=<hex> mbps=<x>   (with --send-bytes)
//   EVENT files-sent bytes=<n>                              (with --send-bytes)
//   EVENT files-failed <id> <reason>                        (with --send-bytes; the process then exits 1)
//   EVENT notify-invoke key=<key> action=<n> reply=<text>   (with --notify; the process then exits 0)
//   EVENT media-command kind=TOGGLE playing=<bool>          (with --media; exits 0 after the second one)
//   EVENT media-ignored kind=<kind> key=<key>                (with --media; any other media.command)
//   EVENT unpaired <mac-id>
//   EVENT disconnected <reason>
//   EVENT failed <reason>
// stdin commands (optional): confirm, decline (answer the code without --auto-confirm), quit.
package io.github.anmirror.phonesim

import io.github.anmirror.connection.ControlChannel
import io.github.anmirror.connection.HelloFailure
import io.github.anmirror.connection.HelloResult
import io.github.anmirror.connection.JsonFilePairedMacStore
import io.github.anmirror.connection.LIVENESS_CAPABILITY
import io.github.anmirror.connection.PROTOCOL_VERSION
import io.github.anmirror.connection.PairedMac
import io.github.anmirror.connection.PairingResult
import io.github.anmirror.connection.PhonePairingClient
import io.github.anmirror.connection.PhoneSession
import io.github.anmirror.connection.Pkcs12Identity
import io.github.anmirror.connection.SessionEnd
import io.github.anmirror.connection.TlsConnector
import io.github.anmirror.connection.UnreachableException
import io.github.anmirror.connection.exchangeHello
import io.github.anmirror.connection.fingerprintHex
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.PairingUri
import io.github.anmirror.protocol.PairingUriException
import io.github.anmirror.protocol.v1.Channel
import io.github.anmirror.protocol.v1.Hello
import io.github.anmirror.protocol.v1.InvokeAction
import io.github.anmirror.protocol.v1.NetworkKind
import io.github.anmirror.protocol.v1.PhoneNotification
import io.github.anmirror.protocol.v1.RingState
import io.github.anmirror.protocol.v1.SetupLevel
import io.github.anmirror.protocol.v1.StatusUpdate
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.concurrent.thread
import kotlin.system.exitProcess
import kotlinx.coroutines.channels.Channel as KChannel

private const val USAGE = """usage: phone-sim pair --uri <uri> --identity <p12> --state-dir <dir> [--auto-confirm]
                      [--status <battery>,<charging>,<signal>,<network>] [--notify] [--media] [--send-bytes <n>] [common options]
       phone-sim connect --state-dir <dir> --identity <p12>
                      [--status <battery>,<charging>,<signal>,<network>] [--notify] [--media] [common options]
common options: [--password <pw>] (default test) [--name <device name>] [--model <device model>] [--liveness]
                [--ping-interval-ms <n>]
  --status example: 55,true,3,wifi   (network: wifi|cellular|none|other; signal -1..4)
  --notify: advertise notify.v1, send one notification after hello, exit 0 on notify.invoke (else 1 after 10 s)
  --media: advertise media.v1, send media.availability and a paused session "sim"; a TOGGLE for it flips it; exit 0 after the second TOGGLE
  --send-bytes <n>: advertise files.v1, send n seeded bytes, store what the Mac sends back; exit 0 when both are done
  --liveness: advertise liveness.v1 (the Mac pings; the phone answers and pings only after 45 s of quiet)
  --ping-interval-ms <n>: sim speed for the phone's keep-alive: 0.1 pings every n ms, the liveness.v1
    fallback ping after 3n/2 ms of quiet, and n ms to wait for an answer (default 30 s, 45 s, 10 s)
  Exit status: 0 after a session ends, 1 after EVENT failed, 2 on bad arguments."""

private val CAPABILITIES = listOf("find.v1", "status.v1")

private fun emit(line: String) {
    synchronized(System.out) {
        println(line)
        System.out.flush()
    }
}

private fun usageError(message: String): Nothing {
    System.err.println("phone-sim: $message\n$USAGE")
    exitProcess(2)
}

private fun failed(reason: String): Nothing {
    emit("EVENT failed $reason")
    exitProcess(1)
}

private class Options(
    val command: String,
    val uri: String?,
    val identity: String,
    val password: String,
    val stateDir: String,
    val autoConfirm: Boolean,
    val status: StatusUpdate?,
    val notify: Boolean,
    val media: Boolean,
    val sendBytes: Long?,
    val liveness: Boolean,
    val pingIntervalMs: Long?,
    val name: String,
    val model: String,
)

private fun parseStatus(s: String): StatusUpdate {
    val parts = s.split(',')
    if (parts.size != 4) usageError("--status needs <battery>,<charging>,<signal>,<network>")
    val battery = parts[0].toIntOrNull()?.takeIf { it in 0..100 } ?: usageError("--status battery must be 0..100")
    val charging = parts[1].toBooleanStrictOrNull() ?: usageError("--status charging must be true or false")
    val signal = parts[2].toIntOrNull()?.takeIf { it in -1..4 } ?: usageError("--status signal must be -1..4")
    val network = when (parts[3]) {
        "wifi" -> NetworkKind.NETWORK_KIND_WIFI
        "cellular" -> NetworkKind.NETWORK_KIND_CELLULAR
        "none" -> NetworkKind.NETWORK_KIND_NONE
        "other" -> NetworkKind.NETWORK_KIND_OTHER
        else -> usageError("--status network must be wifi, cellular, none or other")
    }
    return StatusUpdate.newBuilder()
        .setBatteryPercent(battery)
        .setCharging(charging)
        .setSignalLevel(signal)
        .setNetwork(network)
        .build()
}

private fun parse(args: Array<String>): Options {
    if (args.isEmpty()) usageError("missing command")
    if (args[0] == "-h" || args[0] == "--help") {
        println(USAGE)
        exitProcess(0)
    }
    val command = args[0]
    if (command != "pair" && command != "connect") usageError("unknown command $command")
    var uri: String? = null
    var identity: String? = null
    var password = "test"
    var stateDir: String? = null
    var autoConfirm = false
    var status: StatusUpdate? = null
    var notify = false
    var media = false
    var sendBytes: Long? = null
    var liveness = false
    var pingIntervalMs: Long? = null
    var name = "phone-sim"
    var model = "phone-sim"
    var i = 1
    fun value(flag: String): String = args.getOrNull(++i) ?: usageError("$flag needs a value")
    while (i < args.size) {
        when (val arg = args[i]) {
            "--uri" -> uri = value(arg)
            "--identity" -> identity = value(arg)
            "--password" -> password = value(arg)
            "--state-dir" -> stateDir = value(arg)
            "--auto-confirm" -> autoConfirm = true
            "--status" -> status = parseStatus(value(arg))
            "--notify" -> notify = true
            "--media" -> media = true
            "--send-bytes" -> sendBytes = value(arg).toLongOrNull()?.takeIf { it >= 0 } ?: usageError("--send-bytes needs a size in bytes")
            "--liveness" -> liveness = true
            "--ping-interval-ms" -> pingIntervalMs = value(arg).toLongOrNull()?.takeIf { it > 0 }
                ?: usageError("--ping-interval-ms must be a positive integer")
            "--name" -> name = value(arg)
            "--model" -> model = value(arg)
            "-h", "--help" -> {
                println(USAGE)
                exitProcess(0)
            }
            else -> usageError("unknown argument $arg")
        }
        i++
    }
    if (command == "pair" && uri == null) usageError("--uri is required")
    return Options(
        command, uri,
        identity ?: usageError("--identity is required"),
        password,
        stateDir ?: usageError("--state-dir is required"),
        autoConfirm, status, notify, media, sendBytes, liveness, pingIntervalMs, name, model,
    )
}

/** stdin lines: "quit" exits; the rest are handed to whoever waits for a decision. */
private val stdinLines = KChannel<String>(KChannel.UNLIMITED)

private fun startStdinReader() {
    thread(isDaemon = true, name = "phone-sim-stdin") {
        while (true) {
            val line = readlnOrNull()?.trim() ?: break // EOF (e.g. </dev/null): stop reading
            if (line == "quit") exitProcess(0)
            stdinLines.trySend(line)
        }
    }
}

fun main(args: Array<String>) {
    val options = parse(args)
    val identity = try {
        Pkcs12Identity(File(options.identity), options.password.toCharArray())
    } catch (e: Exception) {
        usageError("cannot load identity: ${e.message}")
    }
    val stateDir = File(options.stateDir)
    if (!stateDir.isDirectory && !stateDir.mkdirs()) usageError("cannot create state dir ${options.stateDir}")
    val store = JsonFilePairedMacStore(File(stateDir, "paired-macs.json"))
    val connector = TlsConnector(identity, tuner = JdkKeepAliveTuner)
    val hello = Hello.newBuilder()
        .setProtocolVersion(PROTOCOL_VERSION)
        .setAppVersion("0.1.0-sim")
        .addAllCapabilities(
            (CAPABILITIES + listOfNotNull(
                "notify.v1".takeIf { options.notify },
                "media.v1".takeIf { options.media },
                "files.v1".takeIf { options.sendBytes != null },
                LIVENESS_CAPABILITY.takeIf { options.liveness },
            )).sorted(),
        )
        .setSetupLevel(SetupLevel.SETUP_LEVEL_BASIC)
        .setDeviceName(options.name)
        .setDeviceModel(options.model)
        .build()

    emit("ID ${fingerprintHex(identity.certificateDer)}")
    startStdinReader()

    runBlocking {
        val (mac, channel) = when (options.command) {
            "pair" -> {
                val uri = try {
                    PairingUri.parse(options.uri!!)
                } catch (e: PairingUriException) {
                    failed(e.reason.name)
                }
                val client = PhonePairingClient(connector, identity, options.name, options.model)
                val result = client.pair(uri) { code ->
                    emit("EVENT code $code")
                    if (options.autoConfirm) {
                        true
                    } else {
                        var answer: Boolean? = null
                        while (answer == null) {
                            when (stdinLines.receive()) {
                                "confirm" -> answer = true
                                "decline" -> answer = false
                            }
                        }
                        answer
                    }
                }
                when (result) {
                    is PairingResult.Failed -> failed(result.reason.name)
                    is PairingResult.Paired -> {
                        store.save(result.mac)
                        emit("EVENT paired ${result.mac.id}")
                        result.mac to result.channel
                    }
                }
            }
            else -> {
                val mac = store.all().maxByOrNull { it.lastConnectedAt } ?: failed("NO_PAIRED_MAC")
                val host = mac.lastHost
                val port = mac.lastPort
                if (host == null || port == null) failed("UNREACHABLE")
                val channel = try {
                    connector.connect(listOf(host), port, mac.fingerprintHex)
                } catch (e: UnreachableException) {
                    // The Mac refused this phone's certificate at TLS: it does not know us.
                    failed(if (e.refusedByPeer) "NOT_PAIRED" else "UNREACHABLE")
                }
                mac to channel
            }
        }
        val end = session(mac, channel, hello, options, connector, store)
        if (end == SessionEnd.UNPAIRED) {
            store.remove(mac.id)
            emit("EVENT unpaired ${mac.id}")
        } else {
            emit("EVENT disconnected ${end.name}")
        }
    }
    exitProcess(0)
}

private const val SAMPLE_KEY = "0|com.whatsapp|1|null|10123"

/** The `notify_posted_minimal` vector from protocol/vectors/framing.json. */
private fun sampleNotification(): PhoneNotification = PhoneNotification.newBuilder()
    .setKey(SAMPLE_KEY)
    .setPackage("com.whatsapp")
    .setTitle("Ana")
    .setText("hi \uD83D\uDC4B")
    .setAlert(true)
    .build()

/** Hello, optional status, then answers find.ring/find.stop until the connection ends. */
private suspend fun session(
    mac: PairedMac,
    channel: ControlChannel,
    hello: Hello,
    options: Options,
    connector: TlsConnector,
    store: JsonFilePairedMacStore,
): SessionEnd {
    val shared = when (val r = exchangeHello(channel, hello)) {
        // A TLS refusal after the handshake prints like a refusal at connect: NOT_PAIRED.
        is HelloResult.Failed -> failed(if (r.reason == HelloFailure.TLS_REFUSED) "NOT_PAIRED" else r.reason.name)
        is HelloResult.Ok -> r.shared
    }
    store.save(mac.copy(lastHost = channel.host, lastPort = channel.port, lastConnectedAt = System.currentTimeMillis()))
    val status = options.status
    val notify = options.notify
    emit("EVENT connected shared=${shared.sorted().joinToString(",")}")
    if (status != null && "status.v1" in shared) {
        channel.send(Channel.CHANNEL_STATUS, MessageType.STATUS_UPDATE, status)
    }
    if (notify && "notify.v1" in shared) {
        // Success is the Mac's invoke; give up after 10 s.
        thread(isDaemon = true, name = "phone-sim-notify-timeout") {
            Thread.sleep(10_000)
            failed("NO_INVOKE")
        }
        channel.send(Channel.CHANNEL_NOTIFY, MessageType.NOTIFY_POSTED, sampleNotification())
    }
    val transfers = options.sendBytes?.takeIf { "files.v1" in shared }?.let { bytes ->
        val tempDir = File(options.stateDir, "received").apply { mkdirs() }
        SimTransfers(channel, connector, mac.fingerprintHex, bytes, tempDir, ::emit) { ok -> exitProcess(if (ok) 0 else 1) }
            .also { it.start() }
    }
    val media = if (options.media && "media.v1" in shared) SimMedia(channel, ::emit) { exitProcess(0) } else null
    media?.start()
    val session = options.pingIntervalMs?.let { n ->
        PhoneSession(channel, shared, pingIntervalMs = n, pongTimeoutMs = n, fallbackIdleMs = n * 3 / 2)
    } ?: PhoneSession(channel, shared)
    val end = session.run(onMacPing = { emit("EVENT mac-ping") }) { env ->
        if (transfers?.onMessage(env) == true) return@run
        if (media?.onMessage(env) == true) return@run
        when (env.type) {
            MessageType.NOTIFY_INVOKE -> {
                val i = InvokeAction.parseFrom(env.payload)
                emit("EVENT notify-invoke key=${i.key} action=${i.actionIndex} reply=${i.replyText}")
                if (i.key == SAMPLE_KEY && i.actionIndex == 0 && i.replyText == "hi") exitProcess(0)
                failed("BAD_INVOKE")
            }
            MessageType.FIND_RING -> {
                if ("find.v1" in shared) {
                    channel.send(Channel.CHANNEL_FIND, MessageType.FIND_STATE, RingState.newBuilder().setRinging(true).build(), env.id)
                }
                emit("EVENT ring")
            }
            MessageType.FIND_STOP -> {
                if ("find.v1" in shared) {
                    channel.send(Channel.CHANNEL_FIND, MessageType.FIND_STATE, RingState.newBuilder().setRinging(false).build(), env.id)
                }
                emit("EVENT stop")
            }
        }
    }
    transfers?.onDisconnected()
    return end
}
