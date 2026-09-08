package com.github.tfox.flutter_vless.xray.core

import org.junit.Assert.assertEquals
import org.junit.Test

class RuntimeGenerationTest {
    @Test
    fun ownedRuntimeTokenWinsOverCallerConfirmation() {
        assertEquals(
            "old-generation",
            XrayCoreManager.runtimeConfirmationToken(
                ownedRuntimeToken = "old-generation",
                requestedConfirmationToken = "new-generation",
            ),
        )
    }

    @Test
    fun callerConfirmationIsUsedOnlyWhenNoRuntimeIsOwned() {
        assertEquals(
            "requested-generation",
            XrayCoreManager.runtimeConfirmationToken(
                ownedRuntimeToken = null,
                requestedConfirmationToken = "requested-generation",
            ),
        )
    }

    @Test
    fun missingOwnershipAndConfirmationStayUnclaimed() {
        assertEquals(
            "",
            XrayCoreManager.runtimeConfirmationToken(
                ownedRuntimeToken = null,
                requestedConfirmationToken = null,
            ),
        )
    }
}
