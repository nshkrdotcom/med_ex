# MedEx Opus

`med_ex_opus` is an independent concrete encoder capability. It requires Elixir
`~> 1.20` and `elixir_make`; it has no dependency on `med_ex`, `med_ex_rtc`,
Phoenix, a host registry, or a provider behavior. Add `{:med_ex_opus, "~> 0.3.0"}`
to the owning host. Build this package directly from `extensions/med_ex_opus`.

## One encoder, one owner

```elixir
{:ok, encoder} = MedEx.Opus.Provider.start_link(owner: self())
:ok = MedEx.Opus.Provider.offer(encoder, "preview_42", source_sample, pcm)
receive do
  {:med_ex_encoded, "preview_42", ^source_sample, opus} -> send_to_viewer(opus)
  {:med_ex_encode_failed, "preview_42", reason} -> retire_preview(reason)
end
:ok = MedEx.Opus.Provider.stop(encoder)
```

The PCM contract is fixed: 48 kHz, mono, signed 16-bit little-endian, 960 samples
and exactly 1,920 bytes per offer. Source sample and operation ID are supplied
by the host; IDs are 1–96 ASCII letters, digits, underscores or hyphens and must
be unique within the peer session. Source samples are unsigned 64-bit integers.
The provider does no resampling, source-clock conversion, storage or RTP work.

One GenServer owns one native Port. The native executable owns and supervises
one libopus child. `offer/4` admits at most one operation; it returns `:ok` for
admission, `{:error, :busy}` if one is pending, and a structured rejection for
invalid input or a non-owner caller. The explicit owner receives exactly one
successful completion or failure notification for a completed admitted offer.
A timeout or unknown outcome retires the encoder; it must not be retried in the
same pipeline. Stop, owner death, caller abandonment, native exit and protocol
failure retire the Port and native codec. The startup caller may differ from
the owner; both lifetimes are tracked.

Native hello has a five-second monotonic deadline and OTP startup has a
six-second outer deadline, including scheduling delay. Each encode and public
call has a one-second bound. The provider reports
`{:error, {:outcome_unknown, reason}}` when a call cannot prove its outcome.
Native packets are 1–1,275 bytes. Nothing is queued behind a pending encode.
The owner admission handshake shares that same one-second call deadline. A
handshake timeout submits no encode and returns a known
`encoder_authorization_unavailable` refusal; it cannot retire an unrelated
owner's encoder. Uncertainty after an authorized submission retires the encoder.
Hosts drop preview data when unavailable; authoritative source storage is a
separate caller-owned operation.

## Checksum-pinned native build

The package pins libopus 1.5.2 with the real SHA-256 in
`c_src/vendor/SHA256SUMS`. `elixir_make` builds a static archive and links
`priv/opus_encoder`. An offline build can set:

```sh
MED_EX_OPUS_TARBALL=/absolute/path/opus-1.5.2.tar.gz mix compile
```

An explicit archive must be an absolute, readable regular file and cannot be a
symlink. A missing or invalid explicit file fails without fetching. Otherwise
the helper uses the download cache, verifies the primary or mirror download
before installing it, and extracts a unique verified snapshot. Every build,
including a warm build, checks the selected archive before reusing output.
Archive paths must stay under the pinned source root and cannot contain `..`,
symlinks, hard links or special entries.

The Linux build requires a C11 compiler, GNU make, GNU tar, POSIX shell, `flock`,
`ar`, `ranlib`, and `sha256sum` or `shasum`; `curl` is needed only for downloads.
A per-application `flock` serializes archive/build/install/clean operations.
The reuse key covers archive bytes and pin, Makefile and helper, compiler
identity and target, compiler/linker flags, archive tools and configure options.
Only complete successful builds install success stamps. C source has its own
binary key. Revalidating unchanged input preserves stamps. Use a build path
without whitespace. `MIX_APP_PATH` is required for direct make calls.

The native lifetime implementation has Linux-specific parent-death protection.
Linux, native codec decoding and process-lifetime checks must be qualified on
the actual deployment architecture and filesystem. Other systems are not
qualified by Linux fixture results; macOS requires an explicit supported build
and lifetime qualification before use. Windows is unsupported.

## Verification

```sh
mix test
python3 test/build_test.py
python3 test/native_protocol_test.py _build/dev/lib/med_ex_opus/priv/opus_encoder
```

The ExUnit tests exercise this concrete API and decode a real packet using a
separate executable linked to the pinned library. Startup/lifetime tests use
private per-caller fixtures through the actual public API; those fixtures do
not qualify libopus. The Python build suite uses a local configure/install
fixture to test archive validation, reuse, failure recovery and concurrency.
The native protocol suite independently decodes with a system libopus shared
library and checks Linux supervisor/codec death using procfs and pidfds.
Missing BEAM, toolchain, archive, decoder or kernel capability means the
applicable gate was **NOT RUN**, never a passing native qualification.
