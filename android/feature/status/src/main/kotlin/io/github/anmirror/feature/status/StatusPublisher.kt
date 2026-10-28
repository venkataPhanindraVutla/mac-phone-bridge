package io.github.anmirror.feature.status

import io.github.anmirror.protocol.v1.StatusUpdate
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

/**
 * Sends [source] values to the Mac while [connected]: at once on every (re)connect, then only
 * changed values, at most one per [minIntervalMs]. The latest value always goes out when a
 * throttled window ends.
 */
class StatusPublisher(
    private val source: Flow<PhoneStatus>,
    private val connected: Flow<Boolean>,
    private val send: suspend (StatusUpdate) -> Unit,
    private val minIntervalMs: Long = 5_000,
) {
    fun launchIn(scope: CoroutineScope): Job = scope.launch {
        connected.distinctUntilChanged().collectLatest { isConnected ->
            if (!isConnected) return@collectLatest
            var last: PhoneStatus? = null // new on each connect: the first value always goes out
            // conflate: while we wait out the window, only the newest value is kept.
            source.distinctUntilChanged().conflate().collect { status ->
                if (status == last) return@collect
                send(status.toProto())
                last = status
                delay(minIntervalMs)
            }
        }
    }
}
