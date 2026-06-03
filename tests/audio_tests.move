#[test_only]
module audio::audio_tests;

use audio::audio as af;
use std::unit_test::assert_eq;
use std::type_name;
use walrus_data::walrus_data;

// Error codes from audio.move
const EInvalidChannels: u64 = 21;
const EInvalidBitDepth: u64 = 22;
const EInvalidSampleRate: u64 = 23;
const EInvalidSamples: u64 = 24;
const ESamplesOverflow: u64 = 25;
const EEmptyFormat: u64 = 26;
const EFormatTooLong: u64 = 27;
const EInvalidFormatChar: u64 = 28;
const EInvalidDigestLength: u64 = 29;

/// Test witness type for ingestion tests.
public struct TestIngesterWitness() has drop;

// Must match audio.move
const MAX_SAMPLES: u64 = 18_446_744_073_709_551;

/// A valid 32-byte test PCM digest.
fun test_digest(): vector<u8> {
    x"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
}

// === Happy Path ===

#[test]
fun test_new() {
    let audio = af::new(b"flac".to_string(),
        2, 16, 44100, 441000,
        test_digest(),
        walrus_data::new_blob(1),
        TestIngesterWitness(),
    );
    assert_eq!(audio.channels(), 2);
    assert_eq!(audio.bit_depth(), 16);
    assert_eq!(audio.sample_rate_hz(), 44100);
    assert_eq!(audio.samples(), 441000);
    assert_eq!(audio.data().blob_id(), 1);
    assert_eq!(*audio.ingester_type(), type_name::with_defining_ids<TestIngesterWitness>());
    assert_eq!(*audio.format(), b"flac".to_string());
    assert_eq!(*audio.pcm_digest(), test_digest());
}

#[test]
fun test_new_mono_audio() {
    let audio = af::new(b"flac".to_string(), 1, 16, 44100, 1000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
    assert_eq!(audio.channels(), 1);
}

#[test]
fun test_new_all_valid_bit_depths() {
    let audio_8 = af::new(b"flac".to_string(), 1, 8, 44100, 1000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
    assert_eq!(audio_8.bit_depth(), 8);

    let audio_16 = af::new(b"flac".to_string(), 1, 16, 44100, 1000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
    assert_eq!(audio_16.bit_depth(), 16);

    let audio_24 = af::new(b"flac".to_string(), 1, 24, 44100, 1000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
    assert_eq!(audio_24.bit_depth(), 24);

    let audio_32 = af::new(b"flac".to_string(), 1, 32, 44100, 1000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
    assert_eq!(audio_32.bit_depth(), 32);
}

#[test]
fun test_new_samples_at_max() {
    let audio = af::new(b"flac".to_string(), 1, 16, 44100, MAX_SAMPLES, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
    assert_eq!(audio.samples(), MAX_SAMPLES);
}

#[test]
fun test_duration_ms() {
    // 44100 samples at 44100 Hz = exactly 1000 ms
    let audio = af::new(b"flac".to_string(), 2, 16, 44100, 44100, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
    assert_eq!(audio.duration_ms(), 1000);

    // 88200 samples at 44100 Hz = exactly 2000 ms
    let audio2 = af::new(b"flac".to_string(), 2, 16, 44100, 88200, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
    assert_eq!(audio2.duration_ms(), 2000);

    // 48000 samples at 48000 Hz = exactly 1000 ms
    let audio3 = af::new(b"flac".to_string(), 1, 24, 48000, 48000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
    assert_eq!(audio3.duration_ms(), 1000);
}

// === Error Conditions ===

#[test, expected_failure(abort_code = EInvalidChannels, location = audio::audio)]
fun test_new_zero_channels() {
    af::new(b"flac".to_string(), 0, 16, 44100, 1000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
}

#[test, expected_failure(abort_code = EInvalidBitDepth, location = audio::audio)]
fun test_new_invalid_bit_depth_12() {
    af::new(b"flac".to_string(), 2, 12, 44100, 1000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
}

#[test, expected_failure(abort_code = EInvalidBitDepth, location = audio::audio)]
fun test_new_invalid_bit_depth_0() {
    af::new(b"flac".to_string(), 2, 0, 44100, 1000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
}

#[test, expected_failure(abort_code = EInvalidSampleRate, location = audio::audio)]
fun test_new_zero_sample_rate() {
    af::new(b"flac".to_string(), 2, 16, 0, 1000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
}

#[test, expected_failure(abort_code = EInvalidSamples, location = audio::audio)]
fun test_new_zero_samples() {
    af::new(b"flac".to_string(), 2, 16, 44100, 0, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
}

#[test, expected_failure(abort_code = ESamplesOverflow, location = audio::audio)]
fun test_new_samples_overflow() {
    af::new(b"flac".to_string(), 2, 16, 44100, MAX_SAMPLES + 1, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
}

#[test, expected_failure(abort_code = EEmptyFormat, location = audio::audio)]
fun test_new_empty_format() {
    af::new(b"".to_string(), 2, 16, 44100, 1000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
}

#[test, expected_failure(abort_code = EFormatTooLong, location = audio::audio)]
fun test_new_format_too_long() {
    // 17 chars > MAX_FORMAT_LENGTH (16)
    af::new(b"aaaaaaaaaaaaaaaaa".to_string(), 2, 16, 44100, 1000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
}

#[test, expected_failure(abort_code = EInvalidFormatChar, location = audio::audio)]
fun test_new_format_uppercase() {
    af::new(b"FLAC".to_string(), 2, 16, 44100, 1000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
}

#[test, expected_failure(abort_code = EInvalidFormatChar, location = audio::audio)]
fun test_new_format_with_slash() {
    af::new(b"audio/flac".to_string(), 2, 16, 44100, 1000, test_digest(), walrus_data::new_blob(1), TestIngesterWitness());
}

#[test, expected_failure(abort_code = EInvalidDigestLength, location = audio::audio)]
fun test_new_wrong_digest_length() {
    // 1-byte digest != 32
    af::new(b"flac".to_string(), 2, 16, 44100, 1000, x"00", walrus_data::new_blob(1), TestIngesterWitness());
}
