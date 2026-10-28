package io.github.anmirror.feature.contacts

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.Contact
import io.github.anmirror.protocol.v1.ContactPhone
import io.github.anmirror.protocol.v1.ContactsBatch
import io.github.anmirror.protocol.v1.ContactsSyncRequest
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Sends the address book to the Mac in batches (SPEC 11). Reads it live and keeps only the
 * high-water mark of the last successful sync, in memory. Every entry point runs under one mutex,
 * so a sync request and a change push never interleave their batches.
 */
class ContactsSync(
    private val source: ContactsSource,
    private val send: suspend (type: String, payload: MessageLite) -> Boolean,
    private val batchSize: Int = 200,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val mutex = Mutex()

    /** `sync_ms` of the last fully sent sequence; null until the Mac has asked this process for one. */
    private var lastSyncMs: Long? = null

    /** The Mac asked for contacts: everything when `since_ms` is 0, else the changes since then. */
    suspend fun onSyncRequest(r: ContactsSyncRequest) = mutex.withLock {
        val since = r.sinceMs
        if (since == 0L) full() else incremental(since, ackWhenEmpty = true)
    }

    /** The address book changed (the caller debounces): pushes what changed since the last sync. */
    suspend fun onChanged() = mutex.withLock {
        val since = lastSyncMs ?: return@withLock // the Mac has not asked yet: it will, with its own mark
        incremental(since, ackWhenEmpty = false)
    }

    private suspend fun full() {
        val rows = withContext(io) { source.changedSince(0) }
        val syncMs = rows.maxOfOrNull { it.updatedMs } ?: 0L
        val chunks = rows.chunked(batchSize).ifEmpty { listOf(emptyList()) }
        for ((i, chunk) in chunks.withIndex()) {
            val batch = ContactsBatch.newBuilder()
                .addAllUpserts(chunk.map(::toProto))
                .setFull(true)
                .setLast(i == chunks.lastIndex)
                .setSyncMs(syncMs)
                .build()
            if (!send(MessageType.CONTACTS_BATCH, batch)) return
        }
        lastSyncMs = syncMs
    }

    private suspend fun incremental(since: Long, ackWhenEmpty: Boolean) {
        val (rows, deleted) = withContext(io) { source.changedSince(since) to source.deletedSince(since) }
        if (rows.isEmpty() && deleted.isEmpty() && !ackWhenEmpty) return
        val syncMs = maxOf(since, rows.maxOfOrNull { it.updatedMs } ?: 0L, deleted.maxOfOrNull { it.second } ?: 0L)
        val upserts = rows.chunked(batchSize)
        val deletes = deleted.map { it.first }.chunked(batchSize)
        val count = maxOf(upserts.size, deletes.size, 1)
        for (i in 0 until count) {
            val batch = ContactsBatch.newBuilder()
                .addAllUpserts(upserts.getOrNull(i).orEmpty().map(::toProto))
                .addAllDeletedIds(deletes.getOrNull(i).orEmpty())
                .setLast(i == count - 1)
                .setSyncMs(syncMs)
                .build()
            if (!send(MessageType.CONTACTS_BATCH, batch)) return
        }
        lastSyncMs = syncMs
    }

    private fun toProto(row: ContactRow): Contact = Contact.newBuilder()
        .setId(row.id)
        .setDisplayName(row.displayName.take(MAX_NAME))
        .addAllPhones(row.phones.take(MAX_PHONES).map { (number, label) ->
            ContactPhone.newBuilder().setNumber(number.take(MAX_NUMBER)).setLabel(label.take(MAX_NAME)).build()
        })
        .build()

    private companion object {
        // Keeps a 200-contact batch far under the 1 MiB frame limit whatever the address book holds.
        const val MAX_NAME = 256
        const val MAX_NUMBER = 64
        const val MAX_PHONES = 20
    }
}
