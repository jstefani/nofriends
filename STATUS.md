# status (paused 2026-10-05)

Feature-complete per the original spec plus three extras: seeded reverse steps, tempo-synced sizes and seed history. Passes `lua test/harness_nf.lua nofriends.lua 300`, which runs under the real norns core Lua with a playhead simulation. **Not yet run on hardware.**

## to check on device
- Step jumps are clean: no clicks, no double-advance. The phase callback's stale-report guard and its 30 ms ignore window after each jump are the risky parts (`on_phase`).
- Rec follows slot jumps correctly. The crossfade covers the rec head jump.
- Pset save/load restores the `.wav` and the seed history.
- Beats mode at slow tempo: a reroll waits for the current slot to end, which can take up to 11.5 s.
- Pitch glide plus a reverse step: slew is zeroed on each step jump so the rate does not sweep through 0.

## design notes
- Slot i owns buffer region `1 + (i-1)*12` s, max length 11.5 s. Lengths only move loop_end.
- PRNG is an LCG with a separate stream per aspect (count, lengths, order, reverse), so changing one setting does not reshuffle the others.
- Order: no slot plays twice in a row (including the wrap from last step to first), and every slot appears at least once. Effective order length = max(order length, slot count).
- Rerolling or changing a param sets `restart_pending`. The new order starts at the next boundary, or immediately if the current slot is now shorter than the playhead position.
- The system param `input_level` collides with ours, so ours is `cut_in_level`.

## ideas not done
- Punch-in quantized to slot boundaries (offered, not chosen).
- Seeds set manually from the menu are not added to the history.
- Grid/MIDI control.
