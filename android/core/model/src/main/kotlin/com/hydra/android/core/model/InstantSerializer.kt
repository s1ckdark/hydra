package com.hydra.android.core.model

import kotlinx.datetime.Instant
import kotlinx.serialization.KSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * RFC3339 with or without fractional seconds. Go's time.Time omits the
 * fraction when it is zero, so a single endpoint returns both shapes.
 * kotlinx-datetime's Instant.parse already accepts both; this serializer
 * exists to give a clear error message and a single point of change.
 */
object InstantSerializer : KSerializer<Instant> {
    override val descriptor =
        PrimitiveSerialDescriptor("Instant", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): Instant {
        val raw = decoder.decodeString()
        return runCatching { Instant.parse(raw) }.getOrElse {
            throw IllegalArgumentException("Invalid RFC3339 instant: $raw", it)
        }
    }

    override fun serialize(encoder: Encoder, value: Instant) =
        encoder.encodeString(value.toString())
}
