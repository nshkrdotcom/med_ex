# MedEx transport and capture

`MedRTC.Preview` answers one browser audio offer and sends Opus RTP. Its caller owns the peer's lifetime. `MedRTC.WavCapture` paces the verified WAV and its prepared preview frames, then writes the original PCM to a playable WAV with a digest. Preview delays are independent of capture.

From the root, run `./onboard.sh --fixture` to prepare the CirCor inputs. Run `cd core/med_rtc && mix test` for negotiation, RTP, malformed input, and blocked-preview coverage. See the root README for the browser integration boundary.
