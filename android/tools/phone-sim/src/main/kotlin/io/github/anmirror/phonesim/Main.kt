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
//   EVENT unpaired <mac-id>
//   EVENT disconnected <reason>
//   EVENT failed <reason>
// stdin commands (optional): confirm, decline (answer the code without --auto-confirm), quit.
package io.github.anmirror.phonesim

import io.github.anmirror.connection.ControlChannel
import io.github.anmirror.connection.HelloResult
import io.github.anmirror.connection.JsonFilePairedMacStore
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
import io.github.anmirror.protocol.v1.NetworkKind
import io.github.anmirror.protocol.v1.RingState
import io.github.anmirror.protocol.v1.SetupLevel
import io.github.anmirror.protocol.v1.StatusUpdate
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.concurrent.thread
import kotlin.system.exitProcess
import kotlinx.coroutines.channels.Channel as KChannel

private const val USAGE = """usage: phone-sim pair --uri <uri> --identity <p12> --state-dir <dir> [--auto-confirm]
                      [--status <battery>,<charging>,<signal>,<network>] [common options]
       phone-sim connect --state-dir <dir> --identity <p12>
                      [--status <battery>,<charging>,<signal>,<network>] [common options]
common options: [--password <pw>] (default test) [--name <device name>] [--model <device model>]
  --status example: 55,true,3,wifi   (network: wifi|cellular|none|other; signal -1..4)
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
        autoConfirm, status, name, model,
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
    val connector = TlsConnector(identity)
    val hello = Hello.newBuilder()
        .setProtocolVersion(PROTOCOL_VERSION)
        .setAppVersion("0.1.0-sim")
        .addAllCapabilities(CAPABILITIES)
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
        val end = session(mac, channel, hello, options.status, store)
        if (end == SessionEnd.UNPAIRED) {
            store.remove(mac.id)
            emit("EVENT unpaired ${mac.id}")
        } else {
            emit("EVENT disconnected ${end.name}")
        }
    }
    exitProcess(0)
}

/** Hello, optional status, then answers find.ring/find.stop until the connection ends. */
private suspend fun session(
    mac: PairedMac,
    channel: ControlChannel,
    hello: Hello,
    status: StatusUpdate?,
    store: JsonFilePairedMacStore,
): SessionEnd {
    val shared = when (val r = exchangeHello(channel, hello)) {
        is HelloResult.Failed -> failed(r.reason.name)
        is HelloResult.Ok -> r.shared
    }
    store.save(mac.copy(lastHost = channel.host, lastPort = channel.port, lastConnectedAt = System.currentTimeMillis()))
    emit("EVENT connected shared=${shared.sorted().joinToString(",")}")
    if (status != null && "status.v1" in shared) {
        channel.send(Channel.CHANNEL_STATUS, MessageType.STATUS_UPDATE, status)
    }
    return PhoneSession(channel, shared).run { env ->
        when (env.type) {
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
}
