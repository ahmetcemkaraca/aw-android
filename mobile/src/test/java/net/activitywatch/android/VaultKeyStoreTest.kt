package net.activitywatch.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

class VaultKeyStoreTest {
    @Test
    fun newDatabaseCanCreateKey() {
        assertEquals(VaultKeyAction.CREATE, vaultKeyAction(databaseExists = false, envelopeExists = false))
    }

    @Test
    fun existingDatabaseWithoutEnvelopeRequiresRecovery() {
        assertEquals(VaultKeyAction.RECOVERY, vaultKeyAction(databaseExists = true, envelopeExists = false))
    }

    @Test
    fun existingEnvelopeMustBeUnwrapped() {
        assertEquals(VaultKeyAction.UNWRAP, vaultKeyAction(databaseExists = true, envelopeExists = true))
    }

    @Test
    fun malformedEnvelopeRequiresRecovery() {
        assertNull(parseVaultEnvelope("v2:not-base64:not-base64"))
        assertNull(parseVaultEnvelope("v1:AA==:AA=="))
        val envelope = "v1:${Base64.getEncoder().encodeToString(ByteArray(12))}:${Base64.getEncoder().encodeToString(ByteArray(48))}"
        assertNotNull(parseVaultEnvelope(envelope))
    }

    @Test
    fun authenticatedEnvelopeUnlocksExactlyOneSqlCipherKey() {
        val key = ByteArray(32) { it.toByte() }
        val wrappingKey = SecretKeySpec(ByteArray(32) { (it + 1).toByte() }, "AES")
        val envelope = encryptVaultKeyForTest(key, wrappingKey)

        val result = unwrapVaultEnvelope(envelope, wrappingKey)
        assertTrue(result is VaultKeyResult.Unlocked)
        assertArrayEquals(key, (result as VaultKeyResult.Unlocked).key)
    }

    @Test
    fun alteredCiphertextOrWrongWrappingKeyRequiresRecovery() {
        val key = ByteArray(32) { it.toByte() }
        val wrappingKey = SecretKeySpec(ByteArray(32) { (it + 1).toByte() }, "AES")
        val envelope = encryptVaultKeyForTest(key, wrappingKey)
        val parts = envelope.split(':')
        val ciphertext = Base64.getDecoder().decode(parts[2]).also { it[0] = (it[0].toInt() xor 1).toByte() }
        val modified = "v1:${parts[1]}:${Base64.getEncoder().encodeToString(ciphertext)}"

        assertEquals(VaultKeyResult.NeedsRecovery, unwrapVaultEnvelope(modified, wrappingKey))
        assertEquals(
            VaultKeyResult.NeedsRecovery,
            unwrapVaultEnvelope(envelope, SecretKeySpec(ByteArray(32) { (it + 2).toByte() }, "AES")),
        )
    }

    private fun encryptVaultKeyForTest(key: ByteArray, wrappingKey: SecretKeySpec): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey)
        return "v1:${Base64.getEncoder().encodeToString(cipher.iv)}:" +
            Base64.getEncoder().encodeToString(cipher.doFinal(key))
    }
}
