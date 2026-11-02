package io.github.anmirror.feature.contacts

import android.provider.ContactsContract
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
    private val clock: () -> Long = System::currentTimeMillis,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val mutex = Mutex()

    /** `sync_ms` of the last fully sent sequence; null until the Mac has asked this process for one. */
    private var lastSyncMs: Long? = null

    /** The Mac asked for contacts: everything when `since_ms` is 0, else the changes since then. */
    suspend fun onSyncRequest(r: ContactsSyncRequest) = mutex.withLock {
        val since = r.sinceMs
        // Android forgets deletions after about 30 days; an older mark could miss one for good.
        val stale = since < clock() - ContactsContract.DeletedContacts.DAYS_KEPT_MILLISECONDS
        if (since == 0L || stale) full() else incremental(since, ackWhenEmpty = true)
    }

    /** The address book changed (the caller debounces): pushes what changed since the last sync. */
    suspend fun onChanged() = mutex.withLock {
        val since = lastSyncMs ?: return@withLock // the Mac has not asked yet: it will, with its own mark
        incremental(since, ackWhenEmpty = false)
    }

    private suspend fun full() {
        val rows = withContext(io) { source.changedSince(0) }
        val syncMs = rows.maxOfOrNull { it.updatedMs } ?: 0L
        val chunks = batches(rows).ifEmpty { listOf(emptyList()) }
        for ((i, chunk) in chunks.withIndex()) {
            val batch = ContactsBatch.newBuilder()
                .addAllUpserts(chunk)
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
        val upserts = batches(rows)
        val deletes = deleted.map { it.first }.chunked(batchSize)
        val count = maxOf(upserts.size, deletes.size, 1)
        for (i in 0 until count) {
            val batch = ContactsBatch.newBuilder()
                .addAllUpserts(upserts.getOrNull(i).orEmpty())
                .addAllDeletedIds(deletes.getOrNull(i).orEmpty())
                .setLast(i == count - 1)
                .setSyncMs(syncMs)
                .build()
            if (!send(MessageType.CONTACTS_BATCH, batch)) return
        }
        lastSyncMs = syncMs
    }

    /** Converts and groups [rows] so a batch holds at most [batchSize] contacts and about [MAX_BATCH_BYTES]. */
    private fun batches(rows: List<ContactRow>): List<List<Contact>> {
        val out = ArrayList<List<Contact>>()
        var cur = ArrayList<Contact>()
        var bytes = 0
        for (row in rows) {
            val c = toProto(row)
            val size = c.serializedSize + 8 // field tag and length prefix, with room
            if (cur.isNotEmpty() && (cur.size >= batchSize || bytes + size > MAX_BATCH_BYTES)) {
                out += cur
                cur = ArrayList()
                bytes = 0
            }
            cur += c
            bytes += size
        }
        if (cur.isNotEmpty()) out += cur
        return out
    }

    private fun toProto(row: ContactRow): Contact = Contact.newBuilder()
        .setId(row.id)
        .setDisplayName(row.displayName.take(MAX_NAME))
        .addAllPhones(row.phones.take(MAX_PHONES).map { (number, label) ->
            ContactPhone.newBuilder().setNumber(number.take(MAX_NUMBER)).setLabel(label.take(MAX_NAME)).build()
        })
        .build()

    private companion object {
        // One contact is at most ~27 KB serialized, so a batch (cut at MAX_BATCH_BYTES) stays far
        // under the 1 MiB frame limit whatever the address book holds.
        const val MAX_BATCH_BYTES = 512 * 1024
        const val MAX_NAME = 256
        const val MAX_NUMBER = 64
        const val MAX_PHONES = 20
    }
}
