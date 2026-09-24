package net.activitywatch.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

sealed class VaultKeyResult {
    data class Unlocked(val key: ByteArray) : VaultKeyResult()
    object NeedsRecovery : VaultKeyResult()
    object Unavailable : VaultKeyResult()
}

internal enum class VaultKeyAction { CREATE, UNWRAP, RECOVERY }

internal fun vaultKeyAction(databaseExists: Boolean, envelopeExists: Boolean): VaultKeyAction =
    when {
        envelopeExists -> VaultKeyAction.UNWRAP
        databaseExists -> VaultKeyAction.RECOVERY
        else -> VaultKeyAction.CREATE
    }

internal fun parseVaultEnvelope(envelope: String): Pair<ByteArray, ByteArray>? {
    return try {
        val parts = envelope.split(':')
        if (parts.size != 3 || parts[0] != "v1") null else {
            val iv = Base64.getDecoder().decode(parts[1])
            val ciphertext = Base64.getDecoder().decode(parts[2])
            if (iv.size == 12 && ciphertext.size == 48) iv to ciphertext else null
        }
    } catch (_: IllegalArgumentException) {
        null
    }
}

internal fun unwrapVaultEnvelope(envelope: String?, wrappingKey: java.security.Key): VaultKeyResult {
    val (iv, ciphertext) = parseVaultEnvelope(envelope ?: return VaultKeyResult.NeedsRecovery)
        ?: return VaultKeyResult.NeedsRecovery
    return try {
        val key = Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, wrappingKey, GCMParameterSpec(128, iv))
            doFinal(ciphertext)
        }
        if (key.size == 32) VaultKeyResult.Unlocked(key) else {
            key.fill(0)
            VaultKeyResult.NeedsRecovery
        }
    } catch (_: Exception) {
        VaultKeyResult.NeedsRecovery
    }
}

object VaultKeyStore {
    private const val KEY_ALIAS = "peakactivity-vault-wrapper-v1"
    private const val PREFERENCES = "PeakActivityVault"
    private const val ENVELOPE = "wrappedKeyV1"

    fun databaseExists(context: Context): Boolean =
        listOf("sqlite.db", "sqlite.db-wal", "sqlite.db-shm")
            .any { File(context.filesDir, it).exists() }

    fun loadOrCreate(context: Context, databaseExists: Boolean): VaultKeyResult {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val envelope = preferences.getString(ENVELOPE, null)
        return when (vaultKeyAction(databaseExists, envelope != null)) {
            VaultKeyAction.RECOVERY -> VaultKeyResult.NeedsRecovery
            VaultKeyAction.UNWRAP -> unwrap(envelope)
            VaultKeyAction.CREATE -> create(preferences)
        }
    }

    fun keyForAcceptedMigration(context: Context): VaultKeyResult {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val envelope = preferences.getString(ENVELOPE, null)
        return if (envelope == null) create(preferences) else unwrap(envelope)
    }

    private fun create(preferences: android.content.SharedPreferences): VaultKeyResult {
        val key = ByteArray(32).also(SecureRandom()::nextBytes)
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, wrappingKeyForFirstUse())
            val encoded = listOf(
                "v1",
                Base64.getEncoder().encodeToString(cipher.iv),
                Base64.getEncoder().encodeToString(cipher.doFinal(key))
            ).joinToString(":")
            if (preferences.edit().putString(ENVELOPE, encoded).commit()) {
                VaultKeyResult.Unlocked(key)
            } else {
                key.fill(0)
                VaultKeyResult.Unavailable
            }
        } catch (_: Exception) {
            key.fill(0)
            VaultKeyResult.Unavailable
        }
    }

    private fun unwrap(envelope: String?): VaultKeyResult {
        val existingKey = try { loadExistingWrappingKey() } catch (_: Exception) {
            return VaultKeyResult.NeedsRecovery
        }
        val key = existingKey ?: return VaultKeyResult.NeedsRecovery
        return unwrapVaultEnvelope(envelope, key)
    }

    private fun loadExistingWrappingKey(): java.security.Key? {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return keyStore.getKey(KEY_ALIAS, null) as? java.security.Key
    }

    private fun wrappingKeyForFirstUse(): java.security.Key {
        loadExistingWrappingKey()?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return generator.generateKey()
    }
}
