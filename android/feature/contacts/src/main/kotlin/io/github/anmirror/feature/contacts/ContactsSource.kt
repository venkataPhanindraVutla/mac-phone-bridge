package io.github.anmirror.feature.contacts

import android.content.ContentResolver
import android.content.Context
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.Phone

/** One contact as read from the address book. [phones] are (number, label) pairs. */
data class ContactRow(val id: String, val displayName: String, val phones: List<Pair<String, String>>, val updatedMs: Long)

/** Reads the address book live; nothing is kept. */
interface ContactsSource {
    /** Contacts whose `CONTACT_LAST_UPDATED_TIMESTAMP` is greater than [ms], with their phones. */
    fun changedSince(ms: Long): List<ContactRow>

    /** Contacts deleted after [ms]: (id, `CONTACT_DELETED_TIMESTAMP`). */
    fun deletedSince(ms: Long): List<Pair<String, Long>>
}

/** [ContactsSource] over ContactsContract. Needs READ_CONTACTS; throws SecurityException without it. */
class AndroidContactsSource(context: Context) : ContactsSource {
    private val app = context.applicationContext
    private val resolver: ContentResolver get() = app.contentResolver

    override fun changedSince(ms: Long): List<ContactRow> {
        val phones = phonesChangedSince(ms)
        val rows = ArrayList<ContactRow>()
                resolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            arrayOf(
                ContactsContract.Contacts._ID,
                ContactsContract.Contacts.DISPLAY_NAME_PRIMARY,
                ContactsContract.Contacts.CONTACT_LAST_UPDATED_TIMESTAMP,
            ),
            "${ContactsContract.Contacts.CONTACT_LAST_UPDATED_TIMESTAMP} > ?",
            arrayOf(ms.toString()),
            "${ContactsContract.Contacts.CONTACT_LAST_UPDATED_TIMESTAMP} ASC",
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0).toString()
                rows += ContactRow(id, cursor.getString(1).orEmpty(), phones[id].orEmpty(), cursor.getLong(2))
            }
        }
        return rows
    }

    override fun deletedSince(ms: Long): List<Pair<String, Long>> {
                val out = ArrayList<Pair<String, Long>>()
        resolver.query(
            ContactsContract.DeletedContacts.CONTENT_URI,
            arrayOf(
                ContactsContract.DeletedContacts.CONTACT_ID,
                ContactsContract.DeletedContacts.CONTACT_DELETED_TIMESTAMP,
            ),
            "${ContactsContract.DeletedContacts.CONTACT_DELETED_TIMESTAMP} > ?",
            arrayOf(ms.toString()),
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) out += cursor.getLong(0).toString() to cursor.getLong(1)
        }
        return out
    }

    /** contact id to (number, label) for every changed contact that has numbers. */
    private fun phonesChangedSince(ms: Long): Map<String, List<Pair<String, String>>> {
        val out = HashMap<String, MutableList<Pair<String, String>>>()
        resolver.query(
            Phone.CONTENT_URI,
            arrayOf(Phone.CONTACT_ID, Phone.NUMBER, Phone.TYPE, Phone.LABEL),
            "${Phone.CONTACT_LAST_UPDATED_TIMESTAMP} > ?",
            arrayOf(ms.toString()),
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val number = cursor.getString(1)?.takeIf { it.isNotBlank() } ?: continue
                val label = Phone.getTypeLabel(app.resources, cursor.getInt(2), cursor.getString(3)).toString()
                out.getOrPut(cursor.getLong(0).toString()) { ArrayList() } += number to label
            }
        }
        return out
    }
}
