# audio

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Move](https://img.shields.io/badge/Move-2024-black.svg)](https://docs.sui.io/concepts/sui-move-concepts)

> Verified audio as a composable on-chain primitive for [Sui](https://sui.io).

`audio` defines a single value type — `Audio` — that carries an audio file's technical metadata together with the identity of the **ingester** that attested it. It is intentionally minimal and domain-agnostic: any protocol can embed an `Audio` (a recording's master, a podcast episode, a video's audio track), and any number of ingester implementations can mint one.

## Design

- **Attested, not trusted.** `Audio` can only be created by a package that can produce an `Ingester` witness. Each `Audio` records *which* ingester attested it (`ingester: TypeName`), so consumers can decide which attestors to trust and multiple ingesters can coexist.
- **Always wrapped.** `Audio` has `store` but **not** `key` — it cannot exist as a standalone object. It is always a field of some larger object (e.g. a recording), never an asset in its own right.
- **A primitive, not a platform.** No lifecycle, no ownership, no extension surface — just verified bytes plus metadata that other protocols compose with.

```move
public struct Audio has drop, store {
    ingester: TypeName,   // who attested this audio
    channels: u8,
    bit_depth: u8,
    sample_rate_hz: u32,
    samples: u64,
    data: WalrusData,     // Walrus blob reference
}
```

## Install

Add to your `Move.toml`:

```toml
[dependencies]
audio = { git = "https://github.com/misonetwork/audio.git", rev = "main" }
```

## Usage

An ingester mints `Audio` by passing a witness it alone can construct:

```move
use audio::audio;

// `Ingester` is a `drop` witness type your package defines and gates.
public fun ingest(/* … */ , witness: MyIngester): audio::Audio {
    audio::new(
        channels,
        bit_depth,
        sample_rate_hz,
        samples,
        walrus_blob,
        witness,
    )
}
```

Consumers read the metadata and the attesting ingester:

```move
let rate = master.sample_rate_hz();
let attestor = master.ingester_type(); // &TypeName — verify against trusted ingesters
```

Creation emits `AudioIngestedEvent<Ingester>` for indexers.

## Build & test

```sh
sui move build
sui move test
```

## Dependencies

| Dependency | Purpose |
|------------|---------|
| [`ori`](https://github.com/unconfirmedlabs/ori) | Walrus data references |

## Contributing

Issues and pull requests are welcome. By contributing you agree that your contributions are licensed under the project's Apache 2.0 license.

## License

[Apache 2.0](LICENSE) © Miso Labs, Inc.
