# `MedEx.Wav`
[🔗](https://github.com/nshkrdotcom/med_ex/blob/med_ex-v0.2.0/lib/med_ex/wav.ex#L1)

Header layout for canonical MedEx PCM WAV files.

# `header_size`

```elixir
@spec header_size() :: 44
```

Returns the canonical WAV header length in bytes.

# `parse_header`

```elixir
@spec parse_header(binary(), non_neg_integer()) ::
  {:ok,
   %{
     pcm_bytes: pos_integer(),
     sample_count: pos_integer(),
     sample_rate_hz: 48000
   }}
  | {:error, :invalid_wav}
```

Parses exactly the first `header_size/0` bytes and checks the total file size.

The canonical format is mono 48 kHz PCM16LE with a fixed `fmt ` chunk and
a nonempty `data` chunk of complete samples, up to 30 minutes. The RIFF
and data lengths must describe the entire file, including its header.

The returned layout describes the declared PCM payload. Reading and
authenticating the payload belongs to the caller.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
