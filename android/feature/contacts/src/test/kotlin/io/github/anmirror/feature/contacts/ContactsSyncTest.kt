package io.github.anmirror.feature.contacts

import com.google.protobuf.MessageLite
import io.github.anmirror.protocol.MessageType
import io.github.anmirror.protocol.v1.ContactsBatch
import io.github.anmirror.protocol.v1.ContactsSyncRequest
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private class FakeSource(
    var rows: List<ContactRow> = emptyList(),
    var deleted: List<Pair<String, Long>> = emptyList(),
) : ContactsSource {
    val changedCalls = mutableListOf<Long>()
    override fun changedSince(ms: Long): List<ContactRow> {
        changedCalls += ms
        return rows.filter { it.updatedMs > ms }
    }
    override fun deletedSince(ms: Long): List<Pair<String, Long>> = deleted.filter { it.second > ms }
}

private fun row(i: Int, updated: Long = i.toLong()) =
    ContactRow("id$i", "Name $i", listOf("+9198765${i.toString().padStart(5, '0')}" to "Mobile"), updated)

private const val NOW = 10_000_000_000L // far enough from 0 that "30 days ago" is positive
private const val DAY = 86_400_000L

private fun request(since: Long) = ContactsSyncRequest.newBuilder().setSinceMs(since).build()

class ContactsSyncTest {
    private val sent = mutableListOf<ContactsBatch>()
    private val send: suspend (String, MessageLite) -> Boolean = { type, m ->
        assertEquals(MessageType.CONTACTS_BATCH, type)
        sent += m as ContactsBatch
        true
    }

    @Test fun fullSyncBatchesBy200WithLastFlag() = runTest {
        val sync = ContactsSync(FakeSource((1..450).map { row(it) }), send, clock = { 0L })
        sync.onSyncRequest(request(0))
        assertEquals(listOf(200, 200, 50), sent.map { it.upsertsCount })
        assertTrue(sent.all { it.full })
        assertEquals(listOf(false, false, true), sent.map { it.last })
        assertEquals("Mobile", sent[0].getUpserts(0).getPhones(0).label)
        assertEquals("Name 1", sent[0].getUpserts(0).displayName)
    }

    @Test fun emptyBookSendsOneEmptyLastBatch() = runTest {
        ContactsSync(FakeSource(), send, clock = { 0L }).onSyncRequest(request(0))
        assertEquals(1, sent.size)
        assertEquals(0, sent[0].upsertsCount)
        assertTrue(sent[0].full)
        assertTrue(sent[0].last)
    }

    @Test fun incrementalSendsUpsertsAndDeletes() = runTest {
        val source = FakeSource((1..5).map { row(it, updated = it * 10L) }, deleted = listOf("gone" to 35L, "old" to 5L))
        ContactsSync(source, send, clock = { 0L }).onSyncRequest(request(25))
        assertEquals(1, sent.size)
        val b = sent[0]
        assertFalse(b.full)
        assertTrue(b.last)
        assertEquals(listOf("id3", "id4", "id5"), b.upsertsList.map { it.id })
        assertEquals(listOf("gone"), b.deletedIdsList)
        assertEquals(50L, b.syncMs)
    }

    @Test fun syncMsIsMaxUpdated() = runTest {
        val sync = ContactsSync(FakeSource(listOf(row(1, 300), row(2, 900), row(3, 100))), send, clock = { 0L })
        sync.onSyncRequest(request(0))
        assertEquals(900L, sent.last().syncMs)
    }

    @Test fun deletionsCountTowardsTheHighWaterMark() = runTest {
        val source = FakeSource(emptyList(), deleted = listOf("gone" to 700L))
        ContactsSync(source, send, clock = { 0L }).onSyncRequest(request(500))
        assertEquals(700L, sent.last().syncMs)
    }

    @Test fun onChangedPushesSinceTheLastSync() = runTest {
        val source = FakeSource(listOf(row(1, 100)))
        val sync = ContactsSync(source, send, clock = { 0L })
        sync.onSyncRequest(request(0))
        sent.clear()
        source.rows = listOf(row(1, 100), row(2, 200))
        sync.onChanged()
        assertEquals(1, sent.size)
        assertFalse(sent[0].full)
        assertEquals(listOf("id2"), sent[0].upsertsList.map { it.id })
        assertEquals(200L, sent[0].syncMs)
        sent.clear()
        sync.onChanged() // nothing new: nothing sent
        assertTrue(sent.isEmpty())
    }

    @Test fun onChangedBeforeAnyRequestSendsNothing() = runTest {
        val source = FakeSource(listOf(row(1)))
        ContactsSync(source, send, clock = { 0L }).onChanged()
        assertTrue(sent.isEmpty())
        assertTrue(source.changedCalls.isEmpty())
    }

    @Test fun aFailedSendDoesNotAdvanceTheMark() = runTest {
        val source = FakeSource(listOf(row(1, 100)))
        var ok = true
        val sync = ContactsSync(source, clock = { 0L }, send = { _, m -> if (ok) { sent += m as ContactsBatch; true } else false })
        sync.onSyncRequest(request(50)) // mark 100
        sent.clear()
        source.rows = listOf(row(1, 100), row(2, 200))
        ok = false
        sync.onChanged()
        ok = true
        sync.onChanged()
        assertEquals(listOf("id2"), sent.single().upsertsList.map { it.id })
    }

    @Test fun aMarkOlderThanTheDeletionRetentionGetsAFullSync() = runTest {
        // Android forgets deletions after ~30 days, so an incremental sync could miss one for good.
        val source = FakeSource(listOf(row(1, NOW - 40 * DAY)), deleted = listOf("gone" to NOW - 35 * DAY))
        ContactsSync(source, send, clock = { NOW }).onSyncRequest(request(NOW - 31 * DAY))
        assertEquals(1, sent.size)
        assertTrue(sent[0].full)
        assertEquals(listOf("id1"), sent[0].upsertsList.map { it.id })
        assertEquals(listOf(0L), source.changedCalls)
    }

    @Test fun idleContactsDoNotMakeTheMarkStale() = runTest {
        // Content untouched for 100 days, but the Mac syncs every few days: never a full sync.
        var now = NOW
        val source = FakeSource(listOf(row(1, NOW - 100 * DAY)))
        val sync = ContactsSync(source, send, clock = { now })
        sync.onSyncRequest(request(0))
        val mark = sent.last().syncMs
        assertEquals(NOW - 1, mark, "the mark is the phone clock before the read, not the old content time")
        sent.clear()
        now += 10 * DAY
        sync.onSyncRequest(request(mark))
        assertFalse(sent.single().full)
        assertEquals(0, sent.single().upsertsCount)
        assertEquals(now - 1, sent.single().syncMs)
        sent.clear()
        now += 40 * DAY // the Mac really did stay away for over 30 days
        sync.onSyncRequest(request(mark))
        assertTrue(sent.single().full)
    }

    @Test fun aMarkInsideTheRetentionStaysIncremental() = runTest {
        val source = FakeSource(listOf(row(1, NOW - 5 * DAY)))
        ContactsSync(source, send, clock = { NOW }).onSyncRequest(request(NOW - 29 * DAY))
        assertFalse(sent.single().full)
    }

    @Test fun batchesAreCutBySerializedSizeAsWellAsCount() = runTest {
        // Worst case per contact: long multi-byte name and label, 20 numbers (~17 KB each).
        val big = "\u20ac".repeat(256)
        val fat = (1..100).map { ContactRow("id$it", big, List(20) { "1".repeat(64) to big }, it.toLong()) }
        ContactsSync(FakeSource(fat), send, clock = { 0L }).onSyncRequest(request(0))
        assertTrue(sent.size > 1)
        assertTrue(sent.all { it.serializedSize <= 600 * 1024 })
        assertEquals(100, sent.sumOf { it.upsertsCount })
        assertEquals(listOf(sent.lastIndex), sent.indices.filter { sent[it].last })
    }
}
