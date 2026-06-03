// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A verified audio file with technical metadata — a standalone, wrapped
/// primitive that any protocol can embed (e.g. as a recording's master).
///
/// ### Key Features:
///
/// - Format (codec/container, e.g. `flac`) and PCM parameters (channels, bit
///   depth, sample rate, samples)
/// - Walrus blob ID for storage reference
/// - Witness-gated creation: only packages that can produce an `Ingester` witness
///   type (with `drop`) can create `Audio`. The `Audio` records which ingester
///   attested it, so multiple ingester implementations can coexist.
module audio::audio;

use std::string::String;
use std::type_name::{TypeName, with_defining_ids};
use sui::event::emit;
use walrus_data::walrus_data::WalrusData;

// === Structs ===

/// A verified audio file with technical metadata.
/// Can only be created by a package that provides an ingester witness.
public struct Audio has drop, store {
    /// The ingester that attested this audio.
    ingester: TypeName,
    /// Codec/container of the stored blob, as a bare lowercase short name
    /// (e.g. `flac`, `wav`, `opus`). No `audio/` prefix — the type is already audio.
    format: String,
    /// Number of audio channels (1 = mono, 2 = stereo).
    channels: u8,
    /// Bits per sample (8, 16, 24, or 32).
    bit_depth: u8,
    /// Sample rate in hertz (e.g., 44100, 48000, 96000).
    sample_rate_hz: u32,
    /// Total number of PCM samples in the audio.
    samples: u64,
    /// `blake2b-256` digest of the canonical decoded PCM (codec-independent
    /// content fingerprint). 32 bytes.
    pcm_digest: vector<u8>,
    /// Walrus data reference for the audio (must be a blob).
    data: WalrusData,
}

// === Events ===

/// Emitted when an audio file is ingested.
public struct AudioIngestedEvent<phantom Ingester: drop> has copy, drop {
    blob_id: u256,
    format: String,
    channels: u8,
    bit_depth: u8,
    sample_rate_hz: u32,
    samples: u64,
    duration_ms: u64,
    pcm_digest: vector<u8>,
}

// === Constants ===

/// Maximum number of samples to prevent overflow in duration_ms (u64::MAX / 1_000).
const MAX_SAMPLES: u64 = 18_446_744_073_709_551;
/// Maximum length of a format short name in bytes (generous; real names are <=8).
const MAX_FORMAT_LENGTH: u64 = 16;
/// Required length of the PCM digest in bytes (blake2b-256).
const PCM_DIGEST_LENGTH: u64 = 32;

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
/// Format must not be empty.
const EEmptyFormat: u64 = 26;
/// Format exceeds maximum length.
const EFormatTooLong: u64 = 27;
/// Format contains an invalid character (must be lowercase `a`-`z` or `0`-`9`).
const EInvalidFormatChar: u64 = 28;
/// PCM digest must be exactly 32 bytes (blake2b-256).
const EInvalidDigestLength: u64 = 29;
// === Public Functions ===

/// Creates a new verified audio. The `Ingester` witness type gates creation —
/// only the package that defines the witness can call this function.
public fun new<Ingester: drop>(
    format: String,
    channels: u8,
    bit_depth: u8,
    sample_rate_hz: u32,
    samples: u64,
    pcm_digest: vector<u8>,
    data: WalrusData,
    _ingester: Ingester,
): Audio {
    // Format must be a non-empty, lowercase alphanumeric short name (e.g. `flac`).
    let format_bytes = format.as_bytes();
    assert!(!format_bytes.is_empty(), EEmptyFormat);
    assert!(format_bytes.length() <= MAX_FORMAT_LENGTH, EFormatTooLong);
    assert!(
        format_bytes.all!(|c| (*c >= 0x61 && *c <= 0x7a) || (*c >= 0x30 && *c <= 0x39)),
        EInvalidFormatChar,
    );
    // PCM digest must be a 32-byte blake2b-256 hash.
    assert!(pcm_digest.length() == PCM_DIGEST_LENGTH, EInvalidDigestLength);
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
        format,
        channels,
        bit_depth,
        sample_rate_hz,
        samples,
        duration_ms,
        pcm_digest,
    });

    Audio {
        ingester: with_defining_ids<Ingester>(),
        format,
        channels,
        bit_depth,
        sample_rate_hz,
        samples,
        pcm_digest,
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

/// Returns the codec/container format of the stored blob (e.g. `flac`).
public fun format(self: &Audio): &String {
    &self.format
}

/// Returns the `blake2b-256` digest of the canonical decoded PCM (32 bytes).
public fun pcm_digest(self: &Audio): &vector<u8> {
    &self.pcm_digest
}
