package net.activitywatch.android

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import androidx.annotation.Keep
import java.io.File
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.file.Files
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec

internal const val MAX_ENTITLEMENT_PROOF_BYTES = 4 * 1024 * 1024
internal const val ENTITLEMENT_REVOCATION_SCOPE = "entitlement-revocations-v1"
private const val FLOOR_PREFIX = "peakactivity-entitlement-floor-v1."

internal fun readEntitlementDocument(input: InputStream): ByteArray {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    try {
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            require(output.size() + count <= MAX_ENTITLEMENT_PROOF_BYTES)
            output.write(buffer, 0, count)
        }
        require(output.size() > 0)
        return output.toByteArray()
    } finally { buffer.fill(0) }
}

internal fun entitlementFloorPrefix(scope: String): String {
    require(scope == ENTITLEMENT_REVOCATION_SCOPE)
    val digest = MessageDigest.getInstance("SHA-256").digest(scope.toByteArray(Charsets.UTF_8))
    return FLOOR_PREFIX + digest.joinToString("") { "%02x".format(it) } + "."
}

internal fun entitlementSequence(value: String): ULong {
    require(value.isNotEmpty() && value.length <= 20 && value.all { it in '0'..'9' })
    val sequence = value.toULong()
    require(sequence.toString() == value)
    return sequence
}

internal fun entitlementFloor(aliases: List<String>, scope: String): ULong {
    val prefix = entitlementFloorPrefix(scope)
    var floor = 0uL
    for (alias in aliases) {
        require(alias.startsWith(prefix))
        floor = maxOf(floor, entitlementSequence(alias.removePrefix(prefix)))
    }
    return floor
}

internal fun sealEntitlementProof(proof: ByteArray, key: SecretKey): ByteArray {
    require(proof.isNotEmpty() && proof.size <= MAX_ENTITLEMENT_PROOF_BYTES)
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.ENCRYPT_MODE, key)
    cipher.updateAAD("peakactivity-entitlement-proof-v1".toByteArray(Charsets.UTF_8))
    return byteArrayOf(1) + cipher.iv + cipher.doFinal(proof)
}

internal fun openEntitlementProof(envelope: ByteArray, key: SecretKey): ByteArray {
    require(envelope.size in 30..(MAX_ENTITLEMENT_PROOF_BYTES + 29) && envelope[0] == 1.toByte())
    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, envelope.copyOfRange(1, 13)))
    cipher.updateAAD("peakactivity-entitlement-proof-v1".toByteArray(Charsets.UTF_8))
    return cipher.doFinal(envelope, 13, envelope.size - 13)
}

// JNI owns this source separately from the activity vault; callbacks never receive activity IDs.
@Keep
class EntitlementStore(context: Context) {
    private val appContext = context.applicationContext
    private val proofFile = File(context.applicationContext.noBackupFilesDir, "entitlement-proof-v1.bin")
    private val atomicFile = AtomicFile(proofFile)

    @Keep
    fun releaseTrust(): ByteArray = appContext.assets.open("entitlement-trust.json").use { input ->
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            check(output.size() + count <= 16_384)
            output.write(buffer, 0, count)
        }
        output.toByteArray()
    }

    @Keep
    fun load(): ByteArray? = synchronized(lock) {
        checkProofPaths()
        if (!proofFile.exists() && !File(proofFile.path + ".bak").exists()) return@synchronized null
        val key = wrappingKey(create = false)
        atomicFile.openRead().use { input ->
            val length = proofFile.length()
            check(length in 30..(MAX_ENTITLEMENT_PROOF_BYTES + 29).toLong())
            val envelope = ByteArray(length.toInt())
            try {
                java.io.DataInputStream(input).readFully(envelope)
                check(input.read() == -1)
                openEntitlementProof(envelope, key)
            } finally { envelope.fill(0) }
        }
    }

    @Keep
    fun save(proof: ByteArray): Boolean = synchronized(lock) {
        var stream: java.io.FileOutputStream? = null
        var envelope = byteArrayOf()
        try {
            checkProofPaths()
            envelope = sealEntitlementProof(proof, wrappingKey(create = true))
            stream = atomicFile.startWrite()
            stream.write(envelope)
            atomicFile.finishWrite(stream)
            true
        } catch (_: Exception) {
            stream?.let { atomicFile.failWrite(it) }
            false
        } finally { envelope.fill(0) }
    }

    @Keep
    fun floor(scope: String): String = synchronized(lock) {
        entitlementFloorPrefix(scope)
        wrappingKey(create = true)
        val store = keyStore()
        val markers = floorAliases(store)
        markers.forEach { protectedKey(store, it) }
        entitlementFloor(markers, scope).toString()
    }

    @Keep
    fun advance(scope: String, sequence: String): Boolean = synchronized(lock) {
        try {
            val requested = entitlementSequence(sequence)
            val current = entitlementSequence(floor(scope))
            if (requested < current) return@synchronized false
            if (requested == current) return@synchronized true
            val store = keyStore()
            check(floorAliases(store).size < 4096)
            createKey(entitlementFloorPrefix(scope) + sequence)
            entitlementSequence(floor(scope)) >= requested
        } catch (_: Exception) { false }
    }

    fun protection(): String = synchronized(lock) {
        try { protectionOf(wrappingKey(create = true)) } catch (_: Exception) { "unavailable" }
    }

    private fun checkProofPaths() {
        // Android's trusted /data/user/0 ancestor can alias /data/data; check the app-owned directory itself.
        check(!Files.isSymbolicLink(proofFile.parentFile!!.toPath()))
        for (file in listOf(proofFile, File(proofFile.path + ".bak"), File(proofFile.path + ".new"))) {
            check(!Files.isSymbolicLink(file.toPath()))
            if (file.exists()) check(file.isFile && file.length() <= MAX_ENTITLEMENT_PROOF_BYTES + 29)
        }
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun floorAliases(store: KeyStore): List<String> {
        val aliases = store.aliases().toList().filter { it.startsWith(FLOOR_PREFIX) }
        check(aliases.size <= 4096)
        return aliases
    }

    private fun wrappingKey(create: Boolean): SecretKey {
        checkProofPaths()
        val store = keyStore()
        if (store.containsAlias(KEY_ALIAS)) return protectedKey(store, KEY_ALIAS)
        check(create && !proofFile.exists() && !File(proofFile.path + ".bak").exists()
            && !File(proofFile.path + ".new").exists() && floorAliases(store).isEmpty())
        return createKey(KEY_ALIAS)
    }

    private fun protectedKey(store: KeyStore, alias: String): SecretKey {
        val key = store.getKey(alias, null) as? SecretKey ?: error("Entitlement storage unavailable")
        protectionOf(key)
        return key
    }

    private fun protectionOf(key: SecretKey): String {
        val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java) as KeyInfo
        if (Build.VERSION.SDK_INT < 31) return if (info.isInsideSecureHardware) "secure hardware" else "OS Keystore software"
        return when (info.securityLevel) {
            KeyProperties.SECURITY_LEVEL_SOFTWARE -> "OS Keystore software"
            KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "trusted environment"
            KeyProperties.SECURITY_LEVEL_STRONGBOX -> "StrongBox"
            else -> error("Unknown entitlement key protection")
        }
    }

    private fun createKey(alias: String): SecretKey {
        check(!keyStore().containsAlias(alias))
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setRandomizedEncryptionRequired(true).build())
        return generator.generateKey().also { protectionOf(it) }
    }

    companion object {
        private const val KEY_ALIAS = "peakactivity-entitlement-wrapper-v1"
        private val lock = Any()
        // shortcut: append-only OS Keystore markers resist app-file rollback only; use a platform monotonic service for whole-OS rollback protection.
    }
}
