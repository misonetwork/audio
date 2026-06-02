// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A verified audio file with technical metadata — a standalone, wrapped
/// primitive that any protocol can embed (e.g. as a recording's master).
///
/// ### Key Features:
///
/// - Audio format parameters (channels, bit depth, sample rate)
/// - Walrus blob ID for storage reference
/// - Witness-gated creation: only packages that can produce an `Ingester` witness
///   type (with `drop`) can create `Audio`. The `Audio` records which ingester
///   attested it, so multiple ingester implementations can coexist.
module audio::file;

use std::type_name::{TypeName, with_defining_ids};
use sui::event::emit;
use ori::walrus_data::WalrusData;

// === Structs ===

/// A verified audio file with technical metadata.
/// Can only be created by a package that provides an ingester witness.
public struct Audio has drop, store {
    /// The ingester that attested this audio.
    ingester: TypeName,
    /// Number of audio channels (1 = mono, 2 = stereo).
    channels: u8,
    /// Bits per sample (8, 16, 24, or 32).
    bit_depth: u8,
    /// Sample rate in hertz (e.g., 44100, 48000, 96000).
    sample_rate_hz: u32,
    /// Total number of PCM samples in the audio.
    samples: u64,
    /// Walrus data reference for the audio (must be a blob).
    data: WalrusData,
}

// === Events ===

/// Emitted when an audio file is ingested.
public struct AudioIngestedEvent<phantom Ingester: drop> has copy, drop {
    blob_id: u256,
    channels: u8,
    bit_depth: u8,
    sample_rate_hz: u32,
    samples: u64,
    duration_ms: u64,
}

// === Constants ===

/// Maximum number of samples to prevent overflow in duration_ms (u64::MAX / 1_000).
const MAX_SAMPLES: u64 = 18_446_744_073_709_551;

// === Errors ===

// Validation errors (20-29)
/// Audio must have at least one channel.
const EInvalidChannels: u64 = 21;
/// Bit depth must be 8, 16, 24, or 32.
const EInvalidBitDepth: u64 = 22;
/// Sample rate must be greater than zero.
const EInvalidSampleRate: u64 = 23;
/// Audio must have at least one sample.
const EInvalidSamples: u64 = 24;
/// Sample count would cause overflow in duration calculation.
const ESamplesOverflow: u64 = 25;
// === Public Functions ===

/// Creates a new verified audio. The `Ingester` witness type gates creation —
/// only the package that defines the witness can call this function.
public fun new<Ingester: drop>(
    channels: u8,
    bit_depth: u8,
    sample_rate_hz: u32,
    samples: u64,
    data: WalrusData,
    _ingester: Ingester,
): Audio {
    // Assert the channels are greater than 0.
    assert!(channels > 0, EInvalidChannels);
    // Assert the bit depth is 8, 16, 24, or 32.
    assert!(vector[8, 16, 24, 32].contains(&bit_depth), EInvalidBitDepth);
    // Assert the sample rate is greater than 0.
    assert!(sample_rate_hz > 0, EInvalidSampleRate);
    // Assert the samples are greater than 0.
    assert!(samples > 0, EInvalidSamples);
    // Assert the samples are less than or equal to the maximum number of samples.
    assert!(samples <= MAX_SAMPLES, ESamplesOverflow);

    // Assert the data is a blob, not a patch quilt.
    // Source files should be lossless, and are typically 10-20MB, which doesn't benefit from quilt effiency.
    // Storing audio files as blobs makes them directly addressable.
    data.assert_is_blob();

    let duration_ms = samples * 1_000 / (sample_rate_hz as u64);

    emit(AudioIngestedEvent<Ingester> {
        blob_id: data.blob_id(),
        channels,
        bit_depth,
        sample_rate_hz,
        samples,
        duration_ms,
    });

    Audio {
        ingester: with_defining_ids<Ingester>(),
        channels,
        bit_depth,
        sample_rate_hz,
        samples,
        data,
    }
}

// === Audio View Functions ===

/// Returns the number of audio channels (1 = mono, 2 = stereo).
public fun channels(self: &Audio): u8 {
    self.channels
}

/// Returns the bit depth of the audio (8, 16, 24, or 32 bits).
public fun bit_depth(self: &Audio): u8 {
    self.bit_depth
}

/// Returns the sample rate in Hz.
public fun sample_rate_hz(self: &Audio): u32 {
    self.sample_rate_hz
}

/// Returns the total number of samples in the audio.
public fun samples(self: &Audio): u64 {
    self.samples
}

/// Returns a reference to the Walrus data.
public fun data(self: &Audio): &WalrusData {
    &self.data
}

/// Returns the duration of the audio in milliseconds (truncated).
/// Multiplies first to preserve precision before integer division.
public fun duration_ms(self: &Audio): u64 {
    self.samples * 1_000 / (self.sample_rate_hz as u64)
}

/// Returns a reference to the ingester type name.
public fun ingester_type(self: &Audio): &TypeName {
    &self.ingester
}
