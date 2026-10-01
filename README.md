# no friends

Seeded cut-up looper for monome norns. You play along with yourself.

2–5 slots ("buffers") play back in an order chosen by a seed. Slot count, slot lengths and order stay fixed until you reroll. Recording overwrites whichever slot is playing. The keep (mix) control sets how much of the old take survives.

## controls

| control | action |
|---|---|
| E1 | keep (mix): 0% = overwrite, 100% = pure overdub |
| E2 | pitch, locked to intervals (octaves / 5ths / 4ths) |
| E3 | size: 0 = seeded lengths, otherwise one fixed length for all slots |
| K2 | record on/off |
| K3 tap | reroll: new seed, new count/lengths/order (audio kept) |
| hold K3 + E3 | browse last 16 seeds |
| hold K3 + K2 | clear the current slot |

A new order starts at the next slot boundary.

## params

- **seed / slots / order length / reverse prob**: what the seed generates. `slots = seed` lets the seed pick 2–5. Reverse prob makes the seed mark some steps to play backwards.
- **size mode**: seconds or beats. In beats mode, lengths are whole beats of the norns clock (1/2–8) and follow tempo changes.
- **seed len min/max**: range for seeded lengths in seconds (default 1–10 s).
- **intervals / pitch / glide**: the interval set E2 steps through, plus optional rate glide.
- **rec level / input to rec / play level / crossfade**
- **play**, **clear all slots**, **all notes off** (stops playback and recording)

## notes

- Recording while pitched is tape-style. A take recorded at +12 sounds right at +12 and plays an octave lower at 0. It stays in key because pitch steps are locked intervals.
- Each slot owns a fixed 12 s region of the buffer (max length 11.5 s), so changing size or rerolling never moves recorded audio.
- Saving a pset also saves the audio next to it as `<pset>.wav`. Loading the pset restores the audio.

## test

    lua test/harness_nf.lua nofriends.lua 300
