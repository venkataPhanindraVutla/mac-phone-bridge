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

private fun request(since: Long) = ContactsSyncRequest.newBuilder().setSinceMs(since).build()

class ContactsSyncTest {
    private val sent = mutableListOf<ContactsBatch>()
    private val send: suspend (String, MessageLite) -> Boolean = { type, m ->
        assertEquals(MessageType.CONTACTS_BATCH, type)
        sent += m as ContactsBatch
        true
    }

    @Test fun fullSyncBatchesBy200WithLastFlag() = runTest {
        val sync = ContactsSync(FakeSource((1..450).map { row(it) }), send)
        sync.onSyncRequest(request(0))
        assertEquals(listOf(200, 200, 50), sent.map { it.upsertsCount })
        assertTrue(sent.all { it.full })
        assertEquals(listOf(false, false, true), sent.map { it.last })
        assertEquals("Mobile", sent[0].getUpserts(0).getPhones(0).label)
        assertEquals("Name 1", sent[0].getUpserts(0).displayName)
    }

    @Test fun emptyBookSendsOneEmptyLastBatch() = runTest {
        ContactsSync(FakeSource(), send).onSyncRequest(request(0))
        assertEquals(1, sent.size)
        assertEquals(0, sent[0].upsertsCount)
        assertTrue(sent[0].full)
        assertTrue(sent[0].last)
    }

    @Test fun incrementalSendsUpsertsAndDeletes() = runTest {
        val source = FakeSource((1..5).map { row(it, updated = it * 10L) }, deleted = listOf("gone" to 35L, "old" to 5L))
        ContactsSync(source, send).onSyncRequest(request(25))
        assertEquals(1, sent.size)
        val b = sent[0]
        assertFalse(b.full)
        assertTrue(b.last)
        assertEquals(listOf("id3", "id4", "id5"), b.upsertsList.map { it.id })
        assertEquals(listOf("gone"), b.deletedIdsList)
        assertEquals(50L, b.syncMs)
    }

    @Test fun syncMsIsMaxUpdated() = runTest {
        val sync = ContactsSync(FakeSource(listOf(row(1, 300), row(2, 900), row(3, 100))), send)
        sync.onSyncRequest(request(0))
        assertEquals(900L, sent.last().syncMs)
    }

    @Test fun deletionsCountTowardsTheHighWaterMark() = runTest {
        val source = FakeSource(emptyList(), deleted = listOf("gone" to 700L))
        ContactsSync(source, send).onSyncRequest(request(500))
        assertEquals(700L, sent.last().syncMs)
    }

    @Test fun onChangedPushesSinceTheLastSync() = runTest {
        val source = FakeSource(listOf(row(1, 100)))
        val sync = ContactsSync(source, send)
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
        ContactsSync(source, send).onChanged()
        assertTrue(sent.isEmpty())
        assertTrue(source.changedCalls.isEmpty())
    }

    @Test fun aFailedSendDoesNotAdvanceTheMark() = runTest {
        val source = FakeSource(listOf(row(1, 100)))
        var ok = true
        val sync = ContactsSync(source, send = { _, m -> if (ok) { sent += m as ContactsBatch; true } else false })
        sync.onSyncRequest(request(50)) // mark 100
        sent.clear()
        source.rows = listOf(row(1, 100), row(2, 200))
        ok = false
        sync.onChanged()
        ok = true
        sync.onChanged()
        assertEquals(listOf("id2"), sent.single().upsertsList.map { it.id })
    }
}
