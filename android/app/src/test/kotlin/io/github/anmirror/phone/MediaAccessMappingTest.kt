package io.github.anmirror.phone

import android.Manifest
import io.github.anmirror.phone.ui.photosAccess
import io.github.anmirror.phone.ui.photosPermissions
import io.github.anmirror.phone.ui.screenshotAccess
import io.github.anmirror.phone.ui.screenshotPermissions
import kotlin.test.Test
import kotlin.test.assertEquals

class MediaAccessMappingTest {
    private val images = Manifest.permission.READ_MEDIA_IMAGES
    private val video = Manifest.permission.READ_MEDIA_VIDEO
    private val picked = Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
    private val storage = Manifest.permission.READ_EXTERNAL_STORAGE

    private fun grants(vararg p: String): (String) -> Boolean = { it in p }

    @Test fun photosNeedImagesAndVideosForFull() {
        assertEquals(MediaAccess.FULL, photosAccess(33, grants(images, video)))
        assertEquals(MediaAccess.FULL, photosAccess(34, grants(images, video, picked)))
        // Images allowed (for screenshots, say) but not videos: only part of the library is listed.
        assertEquals(MediaAccess.PARTIAL, photosAccess(33, grants(images)))
        assertEquals(MediaAccess.PARTIAL, photosAccess(34, grants(video)))
        assertEquals(MediaAccess.PARTIAL, photosAccess(34, grants(picked)))
        assertEquals(MediaAccess.NONE, photosAccess(33, grants(picked)), "no partial grant before API 34")
        assertEquals(MediaAccess.NONE, photosAccess(34, grants()))
        assertEquals(MediaAccess.FULL, photosAccess(29, grants(storage)))
        assertEquals(MediaAccess.NONE, photosAccess(32, grants(images, video)))
    }

    @Test fun screenshotsNeedOnlyImages() {
        assertEquals(MediaAccess.FULL, screenshotAccess(33, grants(images)))
        assertEquals(MediaAccess.PARTIAL, screenshotAccess(34, grants(picked)))
        assertEquals(MediaAccess.NONE, screenshotAccess(33, grants(video)))
        assertEquals(MediaAccess.FULL, screenshotAccess(32, grants(storage)))
        assertEquals(MediaAccess.NONE, screenshotAccess(30, grants()))
    }

    @Test fun api34AsksForThePickedGrantTooSoSelectPhotosLasts() {
        assertEquals(listOf(images, video, picked), photosPermissions(34))
        assertEquals(listOf(images, video), photosPermissions(33))
        assertEquals(listOf(storage), photosPermissions(32))
        assertEquals(listOf(images, picked), screenshotPermissions(36))
        assertEquals(listOf(images), screenshotPermissions(33))
        assertEquals(listOf(storage), screenshotPermissions(29))
    }
}
