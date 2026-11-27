# Architecture and composition

The base SDK has two private source boundaries: pure `core/med_core` and effectful
`core/med_capture`. Their closure becomes one `:med_ex` OTP application through
Weld `:package_projection`. Root Mix compiles the same declared membership for
development. It does not produce a second release candidate.

| Fact | Owner |
|---|---|
| Frame admissibility and source coordinates | StreamSpec, SampleFrame, StreamCursor |
| Receipt identity, durable progression and terminal comparison | Receipt |
| Technical and configured recording budgets | RecordingLimits |
| Immutable bytes, journal and verified terminal index | Storage.File |
| Speculative pending cursor and current storage handle | StreamWriter |
| Clinical and transport authority | External host |
| Native encoding | med_ex_opus concrete Provider |
| RTP transport and opaque peer | med_ex_rtc concrete Provider |

The providers are independent direct Mix packages. Neither imports base modules.
The base imports neither provider nor Fabric. No provider discovery, VM-global
selection, storage plugin surface, extra recorder or general workflow engine is
part of the supported architecture. The host owns browser assets and signaling.

`MedEx.Wire.Credit` counts exact outstanding records and encoded bytes for one
binding; it is accounting, never authentication or proof of source durability.
Clinical observations and delivery belong to Fabric, not this technical SDK.

One service-owned local filesystem and exclusive OS root owner are supported.
Node-local locks and fences are not distributed failover. Source/package/compiled
API and dependency inventories must agree before release.
