package net.activitywatch.android

import org.junit.Assert.*
import org.junit.Test
import javax.crypto.spec.SecretKeySpec

class EntitlementStoreTest {
    @Test
    fun importRejectsEmptyAndOversizeStreamsBeforeNativeInvocation() {
        val proof = "{\"entitlement\":{},\"revocations\":null}".toByteArray()
        assertArrayEquals(proof, readEntitlementDocument(proof.inputStream()))
        assertThrows(IllegalArgumentException::class.java) { readEntitlementDocument(byteArrayOf().inputStream()) }
        assertThrows(IllegalArgumentException::class.java) { readEntitlementDocument(ByteArray(MAX_ENTITLEMENT_PROOF_BYTES + 1).inputStream()) }
    }

    @Test
    fun olderApplicationProofCannotLowerKeystoreCheckpoint() {
        val prefix = entitlementFloorPrefix(ENTITLEMENT_REVOCATION_SCOPE)
        val markers = listOf(prefix + "4", prefix + "2", prefix + "18446744073709551615")
        assertEquals(ULong.MAX_VALUE, entitlementFloor(markers, ENTITLEMENT_REVOCATION_SCOPE))
        assertEquals(ULong.MAX_VALUE, entitlementSequence(ULong.MAX_VALUE.toString()))
        assertEquals(0uL, entitlementFloor(emptyList(), ENTITLEMENT_REVOCATION_SCOPE))
    }

    @Test
    fun damagedOrUnrelatedCheckpointFailsClosed() {
        val prefix = entitlementFloorPrefix(ENTITLEMENT_REVOCATION_SCOPE)
        for (value in listOf("01", "-1", "18446744073709551616", "", "1.0")) {
            assertThrows(IllegalArgumentException::class.java) { entitlementFloor(listOf(prefix + value), ENTITLEMENT_REVOCATION_SCOPE) }
        }
        assertThrows(IllegalArgumentException::class.java) { entitlementFloor(listOf("unrelated.9"), ENTITLEMENT_REVOCATION_SCOPE) }
        assertThrows(IllegalArgumentException::class.java) { entitlementFloorPrefix("activity-account") }
    }

    @Test
    fun billingProofIsAuthenticatedWithAnIndependentKey() {
        val key = SecretKeySpec(ByteArray(32) { 7 }, "AES")
        val proof = "{\"entitlement\":{\"billing\":\"private\"},\"revocations\":null}".toByteArray()
        val envelope = sealEntitlementProof(proof, key)
        assertArrayEquals(proof, openEntitlementProof(envelope, key))
        assertFalse(String(envelope).contains("private"))
        val tampered = envelope.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
        assertThrows(Exception::class.java) { openEntitlementProof(tampered, key) }
        assertThrows(Exception::class.java) { openEntitlementProof(envelope, SecretKeySpec(ByteArray(32) { 8 }, "AES")) }
        assertThrows(IllegalArgumentException::class.java) { sealEntitlementProof(ByteArray(MAX_ENTITLEMENT_PROOF_BYTES + 1), key) }
        assertThrows(IllegalArgumentException::class.java) { openEntitlementProof(ByteArray(29), key) }
    }
}
