package com.hydra.android.core.network

/** A network failure already translated into something the UI can display. */
class ApiException(
    val status: Int?,
    override val message: String,
) : Exception(message)
