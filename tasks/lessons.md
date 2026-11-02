# Engineering lessons

- Finish all source and test edits before starting a validation build. Parallel workers must report a stable snapshot; otherwise a new test can compile before its required API exists.
- When porting a bounded packet source, budget allocated capacity and transient copies, not only serialized payload size. Existing replay digest bookkeeping has its own independent bound.
- Detached setup must copy Demuxer stream metadata through `withStream`; raw stream pointers can outlive a concurrent stop.

- When a mode transition bypasses an inner wait, recheck its outer read gate too. Background audio must clear a full parked-video queue before gating reads and retain audio-specific backpressure. Cover the transition after the queue reaches its cap.
