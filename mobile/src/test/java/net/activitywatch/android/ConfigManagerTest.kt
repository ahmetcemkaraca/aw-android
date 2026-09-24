package net.activitywatch.android

import org.junit.Assert.assertEquals
import org.junit.Test

class ConfigManagerTest {
    @Test
    fun clearsOnlyApiKeyInAuthSection() {
        val config = "address = \"127.0.0.1\"\n[auth]\napi_key = \"legacy\"\nother = true\n[custom]\napi_key = \"keep\"\n"
        assertEquals(
            "address = \"127.0.0.1\"\n[auth]\nother = true\n[custom]\napi_key = \"keep\"\n",
            removeLegacyApiKeyFromConfig(config)
        )
    }

    @Test
    fun leavesConfigWithoutLegacyKeyUnchanged() {
        val config = "[auth]\n# api_key = \"commented\"\n"
        assertEquals(config, removeLegacyApiKeyFromConfig(config))
    }
}
