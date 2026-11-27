# Durability and ordering guarantees

A source record passes through distinct durability boundaries:

1. Source persistence (device spool) or bounded volatile ownership (browser).
2. SDK speculative acceptance; no durable claim or source reclamation.
3. Immutable object installation and file/parent sync.
4. Hash-chained journal commit and sync: authoritative server prefix.
5. Host durable receipt projection commit.
6. Bound ACK, local receipt persistence for devices, then covered reclamation.

Journal truth may be ahead of a failed database transaction. A database receipt
cannot legitimately be ahead of the verified journal. Reconcile verified newer
truth; quarantine conflicts instead of inventing bytes or truncating evidence.
A lost ACK replays the existing receipt without a second append.

Receipt.parse is a total external boundary; it proves shape, not origin.
Receipt.observe permits later multi-commit observation with changed digest and
monotone coordinates. committed_successor proves one exact planned commit.
Same-generation receipt equality includes digest and cursor. durable_prefix is
normalization only; persisted ACKs require durable?. Handoff compares actual
imported prefix with prior receipt, separately bound to authenticated host
assertion and quiescence. Terminal truth comes from verified journal/index.

Storage ownership transfers on recognized typed return, before receipt/index
interpretation. The adapter cleans resources not transferred; the writer retires
the current transferred handle exactly once. Malformed or uncertain outcomes
retire the writer. A timeout or PID exit alone does not prove OS quiescence.

Read-only recovery retains sync barriers but never appends, truncates or installs
logical content. Explicit terminal reconciliation installs only the exact missing
index under exclusive root ownership and quiescence. Identical retry succeeds;
conflicting bytes refuse without overwrite. Partial tails and corrupt committed
chains are different conditions. Import depth and cycles are bounded.

Single local capture service only. Preserve evidence on physical disk exhaustion,
unknown writes and ownership loss. No software test here establishes clinical
validity or sensor calibration.
