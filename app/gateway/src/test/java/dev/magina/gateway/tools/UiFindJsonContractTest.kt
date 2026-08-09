package dev.magina.gateway.tools

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test

class UiFindJsonContractTest {

    @Test
    fun `response returns normalized query and every equivalent OCR box`() {
        val elements = JSONArray()
            .put(ocrElement("box-a", "P0-DENY-O", 10))
            .put(ocrElement("box-b", "PO-DENY-0", 110))

        val matches = UiFindJsonContract.matches(
            elements = elements,
            text = "P0-DENY-0",
            role = null,
            desc = null,
        )
        val response = UiFindJsonContract.response(matches, "P0-DENY-0")

        assertEquals(2, response.getJSONArray("matches").length())
        assertEquals("p0-deny-0", response.getString("query_normalized"))
        for (index in 0 until matches.length()) {
            assertEquals("p0-deny-0", matches.getJSONObject(index).getString("normalized"))
        }
        assertEquals("box-a", matches.getJSONObject(0).getString("ref"))
        assertEquals("box-b", matches.getJSONObject(1).getString("ref"))
    }

    private fun ocrElement(ref: String, text: String, left: Int) = JSONObject()
        .put("ref", ref)
        .put("text", text)
        .put("desc", "")
        .put("role", "text")
        .put("source", "ocr")
        .put("bounds", JSONArray(listOf(left, 20, left + 80, 60)))
}
