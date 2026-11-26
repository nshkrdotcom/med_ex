# Pinned libopus source

`SHA256SUMS` pins the unmodified Xiph.Org `opus-1.5.2.tar.gz` release tarball.
The tarball itself is not committed to Git or included in the Hex package.

- Primary URL: <https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz>
- Mirror URL: <https://github.com/xiph/opus/releases/download/v1.5.2/opus-1.5.2.tar.gz>
- SHA-256: `65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1`

On build, `Makefile` checks the absolute path in `MED_EX_OPUS_TARBALL`
(for offline/airgapped builds; relative overrides are rejected)
or `${XDG_CACHE_HOME:-$HOME/.cache}/med_ex_opus/opus-1.5.2.tar.gz`, fetches a
missing cache entry only when no explicit tarball was supplied, verifies its
SHA-256 against `SHA256SUMS` before caching a download or extracting an archive,
builds a static `libopus.a`, and links it into `priv/opus_encoder`. The encoder links the pinned library. The provider test links its decoder against the same static archive.

To upgrade: update `OPUS` and `URL_GH` in `Makefile`, and update `SHA256SUMS`
with Xiph's published checksum.
