package dev.magina.gateway.testing

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

class AtomicPrivateFileWriter(
    private val tempIdFactory: () -> String = { UUID.randomUUID().toString() },
    private val textWriter: (File, String) -> Unit = { file, text -> file.writeText(text) },
    private val bytesWriter: (File, ByteArray) -> Unit = { file, bytes -> file.writeBytes(bytes) },
    private val mover: (File, File) -> Unit = { source, target ->
        Files.move(
            source.toPath(),
            target.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.ATOMIC_MOVE,
        )
    },
) {
    fun writeText(target: File, text: String) = writeAtomically(target) { temp ->
        textWriter(temp, text)
    }

    fun writeBytes(target: File, bytes: ByteArray) = writeAtomically(target) { temp ->
        bytesWriter(temp, bytes)
    }

    private fun writeAtomically(target: File, write: (File) -> Unit) {
        target.parentFile?.mkdirs()
        val temp = File(target.parentFile, ".${target.name}.${tempIdFactory()}.tmp")
        var failure: Throwable? = null
        try {
            write(temp)
            mover(temp, target)
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            try {
                Files.deleteIfExists(temp.toPath())
            } catch (cleanupError: Throwable) {
                if (failure != null) failure.addSuppressed(cleanupError) else throw cleanupError
            }
        }
    }
}
