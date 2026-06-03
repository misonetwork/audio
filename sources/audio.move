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
use ori::walrus_data::WalrusData;

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
    /// Walrus data reference for the audio (must be a blob). When encrypted,
    /// this points to the AES-ciphertext blob.
    data: WalrusData,
    /// Whether `data` is stored in the clear or encrypted (and if so, how it's
    /// gated). See `Confidentiality`.
    confidentiality: Confidentiality,
}

/// Confidentiality of the stored blob: cleartext, or encrypted with an
/// access policy.
public enum Confidentiality has copy, drop, store {
    /// `data` is stored in the clear.
    Unencrypted,
    /// `data` is an AES-encrypted blob. `dek` is the AES data-encryption key
    /// sealed via Seal (a small ciphertext, stored on-chain — NOT the audio
    /// bytes, which stay on Walrus). Decryption is gated by `policy`: the Seal
    /// access PTB must present a `drop`-only witness whose type equals `policy`,
    /// and that witness is minted only by its defining module's gate (e.g.
    /// "holds a Record"). The witness type is the single source of truth for
    /// the policy and is immutable once set.
    Encrypted { policy: TypeName, dek: vector<u8> },
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
    /// Whether the stored blob is encrypted.
    encrypted: bool,
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
/// Encrypted audio must carry a non-empty sealed data-encryption key.
const EEmptyDek: u64 = 30;

// Access errors (30-39)
/// Audio is not encrypted, so it has no policy / sealed key.
const ENotEncrypted: u64 = 31;
// === Public Functions ===

/// Creates a new verified, **unencrypted** audio. The `Ingester` witness type
/// gates creation — only the package that defines the witness can call this.
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
    build<Ingester>(
        format, channels, bit_depth, sample_rate_hz, samples, pcm_digest, data,
        Confidentiality::Unencrypted,
    )
}

/// Creates a new verified, **encrypted** audio. `data` points to the
/// AES-ciphertext blob on Walrus; `dek` is the AES key sealed via Seal (stored
/// on-chain). The `Policy` witness type — provided by the caller — is stamped
/// immutably as the decryption policy: a Seal access PTB must present a witness
/// of this exact type. `Ingester` gates creation (typically the enclave that
/// produced the ciphertext + sealed key).
public fun new_encrypted<Ingester: drop, Policy: drop>(
    format: String,
    channels: u8,
    bit_depth: u8,
    sample_rate_hz: u32,
    samples: u64,
    pcm_digest: vector<u8>,
    data: WalrusData,
    dek: vector<u8>,
    _ingester: Ingester,
    _policy: Policy,
): Audio {
    assert!(!dek.is_empty(), EEmptyDek);
    build<Ingester>(
        format, channels, bit_depth, sample_rate_hz, samples, pcm_digest, data,
        Confidentiality::Encrypted { policy: with_defining_ids<Policy>(), dek },
    )
}

/// Shared validation + event + construction for `new` / `new_encrypted`.
fun build<Ingester: drop>(
    format: String,
    channels: u8,
    bit_depth: u8,
    sample_rate_hz: u32,
    samples: u64,
    pcm_digest: vector<u8>,
    data: WalrusData,
    confidentiality: Confidentiality,
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
    let encrypted = match (&confidentiality) {
        Confidentiality::Encrypted { .. } => true,
        Confidentiality::Unencrypted => false,
    };

    emit(AudioIngestedEvent<Ingester> {
        blob_id: data.blob_id(),
        format,
        channels,
        bit_depth,
        sample_rate_hz,
        samples,
        duration_ms,
        pcm_digest,
        encrypted,
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
        confidentiality,
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

/// Returns the blob's confidentiality (unencrypted, or encrypted + how gated).
public fun confidentiality(self: &Audio): &Confidentiality {
    &self.confidentiality
}

/// Returns whether the stored blob is encrypted.
public fun is_encrypted(self: &Audio): bool {
    match (&self.confidentiality) {
        Confidentiality::Encrypted { .. } => true,
        Confidentiality::Unencrypted => false,
    }
}

/// Returns the decryption policy (witness type). Aborts if unencrypted.
/// A Seal `seal_approve` compares this against the runtime witness's type.
public fun policy(self: &Audio): TypeName {
    match (&self.confidentiality) {
        Confidentiality::Encrypted { policy, .. } => *policy,
        Confidentiality::Unencrypted => abort ENotEncrypted,
    }
}

/// Returns the Seal-sealed data-encryption key. Aborts if unencrypted.
public fun sealed_dek(self: &Audio): &vector<u8> {
    match (&self.confidentiality) {
        Confidentiality::Encrypted { dek, .. } => dek,
        Confidentiality::Unencrypted => abort ENotEncrypted,
    }
}
