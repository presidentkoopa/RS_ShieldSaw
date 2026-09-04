Blank 1x1 transparent frames, one per sprite name and frame the states and
MODELDEF use (SSAW/SSNH/SFLY A-H, SLCK A-D).

THEY ARE NOT DECORATION AND THEY ARE NOT PLACEHOLDER ART. The models are what
draw; these exist so the frames VALIDATE.

Weapon::TryPickup (wadsrc/static/zscript/actors/inventory/weapons.zs) refuses
any weapon whose Ready state has no valid sprite frame:

    State ReadyState = FindState('Ready');
    if (ReadyState != NULL && ReadyState.ValidateSpriteFrame())
        return Super.TryPickup (toucher);
    return false;

Rusted Legacy never hit this because its shield saw was `extend class
RLOffhandFist` -- the weapon class was the FIST, whose Ready state uses the
IWAD's FIST sprite. SHLD/SHD2/SH00 only ever appeared in sub-states, never in
the state FindState('Ready') resolves at pickup time. There are no shield
sprites anywhere in the original, and there never were.

Rebuilding it as a standalone Weapon whose Ready is `SSAW A` made the sprite
name load-bearing. Without these the weapon compiles, loads, and can never be
picked up -- GiveInventory silently does nothing.
