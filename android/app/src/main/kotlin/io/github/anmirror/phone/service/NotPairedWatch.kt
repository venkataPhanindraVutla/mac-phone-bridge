package io.github.anmirror.phone.service

import io.github.anmirror.phone.platform.StoreRead
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/**
 * What the service does while the manager says `NotPaired`. The manager starts there before it
 * has read the store, and it also lands there when the store cannot be read, so the store is
 * asked: confirmed empty (and no pairing under way) stops the service; anything else keeps it
 * running. Then, every [intervalMs], the store is read again and the manager kicked, for as
 * long as [stillNotPaired] holds. It does not wait for a state flow to emit again: a repeated
 * `NotPaired` is not re-emitted. The caller also cancels this when the state changes.
 */
suspend fun watchNotPaired(
    intervalMs: Long,
    read: suspend () -> StoreRead,
    pairingUnderWay: () -> Boolean,
    stillNotPaired: () -> Boolean,
    kick: () -> Unit,
    onUnreadable: () -> Unit,
    onSelfStop: () -> Unit,
) {
    while (stillNotPaired()) {
        // An unexpected failure is an unreadable store: never a crash, never "no Mac".
        val r = try {
            read()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            StoreRead.Unreadable(e.javaClass.simpleName)
        }
        val confirmedEmpty = r is StoreRead.Macs && r.macs.isEmpty()
        if (BootDecision.shouldSelfStop(pairingUnderWay(), confirmedEmpty)) {
            onSelfStop()
            return
        }
        if (r is StoreRead.Unreadable) onUnreadable()
        delay(intervalMs)
        if (!stillNotPaired()) return
        kick()
    }
}
