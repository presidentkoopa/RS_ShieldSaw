# RS_ShieldSaw

A throwable shield saw for DoomXR. Standalone — no dependencies, no player
class replacement, works alongside anything.

## How it plays

The shield hangs on a mount over your off shoulder. A wireframe diamond marks
the spot and brightens when your hand is close enough to take it.

| | |
|---|---|
| **Reach back, squeeze** | it comes into your off hand; whatever was in that hand is set aside |
| **Attack while holding** | the disc grinds what it touches, and the same sweep paints distant targets |
| **Release the grip** | throws it — your own weapon is back in your hand *instantly*, not when it lands |
| **Release at the mount** | puts it back instead |
| **Reach back while it flies** | recalls it early |

It flies the painted route, `+RIPPER` through each target in turn, and returns
to the mount. **There is no catch.** By the time it lands you are holding your
own weapon again, so putting the shield back in your hand would take that away.

The throw plane comes from your wrist at the moment of release and is held for
the whole flight — throw it sidearm and it goes round sidearm.

## Where it came from

Rusted Legacy's shield saw was `extend class RLOffhandFist` — not a weapon at
all, but a mode bolted onto the off-hand fist, needing `DoomWeaponZ`,
`rlvr_Settings`, the weapon HUD and the aim laser before it would compile. It
was stripped out of RS_ForceUnleashed with the rest of that framework, on the
reasoning that each piece was a separate feature another RS_ mod already owned.

That was true of the laser, the HUDs and the reload markers. It was not true of
this: nothing replaced it. The sounds, cvars, settings accessors and impact
actors sat inert while the weapon and its models were gone.

This is the mechanics rebuilt on stock `Weapon`, with the original's models.

**What changed:**

- The throw locks a **list**. The original auto-aimed at one nearest target and
  then you flew it by looking at things — it re-aimed at your view every tic, so
  you could not look away from your own shield.
- **Seven fixed throw planes became one continuous angle.** It used to pick from
  `RollOffset` 0, ±30, ±60, ±90 by jumping to one of seven spawn states.
- Its deflector cleared `bReflective` on your first own-shot and **never put it
  back**, so the shield stopped deflecting for the rest of the level.
- Motion throw was gated behind the **oVRdrive** mod being loaded. Dropped
  rather than carried as a dead dependency.

## Things worth knowing before you edit it

**The zip is what loads.** `RS_ShieldSaw.zip` is what a launcher points at, not
the loose folder. Editing `.zs` files does nothing until you repack:

```
powershell -File build.ps1
```

**The blank sprites are load-bearing.** `Weapon::TryPickup` refuses any weapon
whose `Ready` state has no valid sprite frame. `SSAW`/`SSNH`/`SFLY`/`SLCK`/
`SSTW`/`SSMK` have blank 1×1 images behind them for exactly that reason — the
models do all the drawing. Delete them and the weapon compiles, loads, and can
never be picked up. There are no shield sprites in the original and never were:
its weapon class was the *fist*, whose `Ready` state uses the IWAD's `FIST`.

**The slot table is built before the grant.** `PlayerSpawned` runs after player
setup, so `WeaponSlots.SetupWeaponSlots()` has to rebuild it or the weapon lands
in inventory and in no slot at all, reachable by no key.

**`NO_AUTO_SWITCH`, not `NOAUTOSWITCHTO`.** They are different flags.
`AttachToOwner` reads the first one before setting `PendingWeapon` on a give.

**`Draw()` is the only thing allowed to put the shield in your hand.** Anything
else that gets it there — the engine filling an empty off hand, a level change
re-raising a serialized `OffhandWeapon` — is undone by `unstow()`. Without that
the shield grinds continuously off your back.

**Placement is MODELDEF `PlacementCVars`,** read live by the renderer every
frame. Slider values and MODELDEF `Offset` are summed in the same translate, so
a number found on a slider can be folded into MODELDEF and the slider zeroed
with nothing moving.

## Compatibility

- **ModelSwapper** skips it — its scan bails on any `RS_` prefixed class before
  it ever reaches the `HasOwnModel` test.
- **RS_Hands / Reload / Holsters** — the draw asks the grip arbiter (by string,
  through `ServiceIterator`, so there is no compile-time link and this still
  runs alone) and claims the hand while the shield is out. Requiring the hand to
  be *at the mount* does most of the work: a squeeze anywhere else is somebody
  else's business.
- **psprite layers** — nothing of ours is left in the psprite ranges; the mount
  and marker are world actors.
- Granted on `PlayerSpawned`/`PlayerRespawned`, `addslotdefault` appends rather
  than clearing slot 1.

## Known gaps

**`HandMoving()` is stubbed true**, so any release throws — you cannot yet
release-while-still to put it back except at the mount. It needs hand velocity
the engine does not publish. One function; when `OffhandVel` lands it becomes a
threshold test and nothing else changes.

**Your own hitscans.** The deflector is `+SHOOTABLE`, and an actor whose
bounding box contains a trace origin is an intercept at frac 0. It is small and
sat clear of the hand now, which fixes the zero-range case, but a shot fired
*through* it still stops. Missiles are handled — `CanCollideWith`, which works
because the engine's gate in `PIT_CheckThing` was widened to fire for
missile-vs-shootable. Hitscans have no victim-side veto; that wants the same
idiom added engine-side.

**It does not deflect while stowed.** It is behind you. That was the forearm
mount's one advantage and it went with the mount.

## Layout

```
zscript/rs_shieldsaw.zs         RS_ShieldSaw -- the weapon
zscript/rs_shieldsaw_state.zs   the three states, the loadout swap, the gesture
zscript/rs_shieldsaw_mount.zs   the shoulder anchor and its marker
zscript/rs_shieldsaw_actors.zs  flight, trail, lock marker, deflector, puff
build.ps1                       repack the zip
```
