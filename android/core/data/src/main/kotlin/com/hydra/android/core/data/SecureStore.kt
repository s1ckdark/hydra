package com.hydra.android.core.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

interface SecureStore {
    fun getApiKey(): String?
    fun setApiKey(value: String)
}

/**
 * The iOS client keeps secrets in the Keychain via CredentialStore. v1 has
 * exactly one secret (the server API key), and androidx.security-crypto is
 * deprecated in Jetpack, so this wraps Android Keystore AES/GCM directly and
 * stores the ciphertext in a plain SharedPreferences file.
 *
 * Stored layout: "<base64 iv>:<base64 ciphertext>".
 */
class KeystoreSecureStore(context: Context) : SecureStore {

    private val prefs = context.getSharedPreferences("hydra_secure", Context.MODE_PRIVATE)

    override fun getApiKey(): String? {
        val stored = prefs.getString(KEY_API, null) ?: return null
        val parts = stored.split(':')
        if (parts.size != 2) return null
        return runCatching {
            val iv = Base64.decode(parts[0], Base64.NO_WRAP)
            val cipherText = Base64.decode(parts[1], Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, iv))
            String(cipher.doFinal(cipherText), Charsets.UTF_8)
        }.getOrNull()
    }

    override fun setApiKey(value: String) {
        if (value.isEmpty()) {
            prefs.edit().remove(KEY_API).apply()
            return
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val cipherText = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val encoded = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
            Base64.encodeToString(cipherText, Base64.NO_WRAP)
        prefs.edit().putString(KEY_API, encoded).apply()
    }

    private fun secretKey(): SecretKey {
        val ks = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build()
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "hydra_api_key"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val KEY_API = "server_api_key"
        const val TAG_BITS = 128
    }
}
