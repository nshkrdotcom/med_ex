# Source ownership

The root application compiles exactly `core/med_core/lib` and
`core/med_capture/lib`. Core contains stream descriptors, samples, sparse
measurement and status facts, gap/index validation, MEX1 framing, MEJ1 encoding,
frame fingerprints, rational clock alignment and command interlocks. Capture
owns per-attempt writer and filesystem effects. The existing Evidence and WAV
format remain available independently of new indexed, gapped recording.

Independent component Mix projects exercise this source dependency direction.
A consumer installs only the aggregate application. Installing either proof
component or the retired `:med_rtc` alongside the root creates duplicate module
ownership. `build_support/check_architecture.sh` independently compiles each
project, inspects BEAM compile-info source paths, compares ownership and traces
static compiler calls/struct expansion. AST checks restrict explicit dynamic
module dispatch. These checks cover this source tree; they do not establish purity
for arbitrary metaprogramming.

Opus and RTC have distinct dependencies and OTP identities. Capture's media
messages carry the actual peer/session PID. The legacy RTC facade snapshots
the first successfully configured RTC provider for the VM lifetime. Set
configuration before opening the first peer. Host-owned ingress is independent
of optional preview. A strict deployment can run both native packages in a
separate OS process and drop disposable preview packets under load.

An immutable stream contains native waveform bytes and technical facts.
Sealing a stream and authenticating a clinical review are independent host
operations. SDK recording assumes a single acquisition node with a trusted
local POSIX filesystem and explicit writer fencing. Hardware qualifications,
physiological interpretation, patient context, web routes and clinical
workflow belong to the consuming system.
