// THE SHIELD ON YOUR BACK, AND REACHING OVER YOUR SHOULDER FOR IT.
//
// This originally replaced the forearm psprite outright. The forearm was the
// wrong mount for two reasons that only showed up in a headset: a shield big
// enough to read as a shield covers the arm you need to see, and -- worse --
// ANY grip squeeze was the draw, so the shield fought RS_Hands for every
// health pack you picked up.
//
// A dedicated anchor fixed both. The draw became a PLACE, not a button: put
// your off hand over your own shoulder and squeeze. Nothing else in the game
// wants that spot, so there is nothing to arbitrate with.
//
// A WORLD ACTOR, NOT A PSPRITE, and that is forced rather than chosen. A
// psprite is drawn in a HAND's frame; there is no hand at your shoulder blade.
// Body-anchored things are world actors here -- it is what RS_Holsters does for
// all nine of its anchors -- and 35Hz placement is fine for something sitting
// on your back that you never look straight at.
//
// rs_ss_mount_mode BRINGS THE FOREARM BACK AS AN OPTION, not a replacement.
// The RS_GripArbiterService's grip.subject check -- added after the forearm
// was scrapped, and what offHandFree() in rs_shieldsaw_state.zs now leans on
// for the shoulder gesture too -- was the piece that was actually missing the
// first time: a grip that closes on nothing (GRIPSUBJ_None) is the gesture, a
// grip that closes on a health pack or a magazine is somebody else's, and the
// arbiter can already tell them apart. With that in place the forearm no
// longer fights RS_Hands for anything. The one cost that survives is the one
// that was never a logic bug: a shield strapped to your own forearm still
// covers the arm you're looking at. RS_ShieldForearmActor below is a
// FollowOffHand world prop -- draw-rate placement, like every other prop that
// rides a moving hand -- rather than the old psprite, and rs_shieldsaw.zs's
// holdDeflector() now places the passive guard at whichever of the two spots
// the shield actually is.

class RS_ShieldMount
{
	// WHERE ON YOUR BACK. Read the same way RS_Holsters reads its anchors:
	//   fwd   + is in FRONT of the eye plane, so this is negative -- behind you
	//   side  + is your right, so negative is over the LEFT shoulder
	//   frac  height as a fraction of eye height; 0.86 is about shoulder
	//
	// Anchors hang off HmdPos and the BODY yaw, never head pitch or roll --
	// otherwise looking down would drag the shield down your back with you.
	// [LEFTHAND] WHICH SHOULDER. The mount was hard-wired to the LEFT: `side = -8` at every
	// call site, with no handedness term anywhere in the file. A left-handed player therefore
	// reached across his own chest for a shield that was drawn in his right hand.
	//
	// Folded in here, at the one place that turns a side offset into a world position, rather
	// than at the five call sites that pass -8 -- which is how it would come back wrong the
	// first time someone added a sixth.
	//
	// A `user` cvar because vr_control_scheme is CVAR_GLOBALCONFIG and the playsim cannot read
	// it for anybody, including the local player.
	static double MirrorSide(PlayerPawn pmo, double side)
	{
		if (!pmo || !pmo.player) return side;
		let c = CVar.GetCVar("rs_ss_lefthanded", pmo.player);
		return (c && c.GetBool()) ? -side : side;
	}

	static Vector3 AnchorPos(PlayerPawn pmo, double fwd, double side, double frac)
	{
		if (!pmo) return (0, 0, 0);
		side = MirrorSide(pmo, side);

		double yaw = pmo.angle;
		double fx = cos(yaw), fy = sin(yaw);
		double rx = cos(yaw - 90), ry = sin(yaw - 90);

		// Live eye height rather than a calibration pass: the head's height
		// above the pawn's own feet. Crouching lowers the anchor with you,
		// which is what you want when you reach for it.
		double eye = max(24.0, pmo.HmdPos.Z - pmo.pos.z);
		double floorZ = pmo.HmdPos.Z - eye;

		return (pmo.HmdPos.X + (fwd * fx) + (side * rx),
		        pmo.HmdPos.Y + (fwd * fy) + (side * ry),
		        floorZ + (eye * frac));
	}

	// NO HEAD POSE, NO ANCHOR. HmdPos reads as a zero vector until the VR
	// backend has written one; placing anything off it before then puts the
	// shield at the map origin.
	static bool Tracking(PlayerPawn pmo)
	{
		return pmo && pmo.HmdPos.Length() != 0;
	}

	//=======================================================================
	//
	// THE SAME SEAT, OFF THE PAWN INSTEAD OF THE HEAD -- for anything that
	// DECIDES something rather than draws something.
	//
	// AnchorPos above is right for drawing: it rides the real head, so the
	// stowed shield stays on the shoulder it looks like it is on. It is wrong
	// for a collision test, twice over.
	//
	//   IT IS NOT REPLICATED. HmdPos is written by the renderer, on one
	//   machine. A guard volume placed from it is a volume every other
	//   machine disagrees with, and a damage test two machines disagree about
	//   is a desync.
	//
	//   IT IS ZERO WHEN NOTHING IS TRACKING. Flat play, a boot test, the
	//   first tics before the backend writes a pose -- the anchor collapses
	//   toward the map origin and the guard is registered thousands of units
	//   away from the player. MEASURED, 2026-10-17: a blow logged
	//   `discaxis 3762.6` with the disc at (-8, -7, -14) while the player
	//   stood at (1056, -3616). The comment above predicted exactly this; the
	//   guard path called AnchorPos anyway, without asking Tracking().
	//
	// So the deciding seat uses the pawn's own position, its own body yaw and
	// its view height -- all replicated, all live on every machine, none of
	// them zero before the headset wakes up.
	//
	static Vector3 AnchorPosPlaysim(PlayerPawn pmo, double fwd, double side, double frac)
	{
		if (!pmo) return (0, 0, 0);
		side = MirrorSide(pmo, side);

		double yaw = pmo.angle;
		double fx = cos(yaw), fy = sin(yaw);
		double rx = cos(yaw - 90), ry = sin(yaw - 90);

		// The pawn's eye, not the headset's: ViewHeight is where the engine
		// itself thinks this player's eyes are, and it is the same number on
		// every machine. Crouching moves it, which is the behaviour the drawn
		// anchor gets from the live head.
		double eye = max(24.0, pmo.ViewHeight);

		return (pmo.pos.x + (fwd * fx) + (side * rx),
		        pmo.pos.y + (fwd * fy) + (side * ry),
		        pmo.pos.z + (eye * frac));
	}
}

// The shield sitting on your back. Inert -- it is scenery until you reach for
// it, and the reach test is a distance to the anchor, not to this actor.
class RS_ShieldStowActor : Actor
{
	Default
	{
		Radius 1;
		Height 1;
		+NOINTERACTION
		+NOBLOCKMAP
		+NOGRAVITY
		+NOTONAUTOMAP
		+DONTSPLASH
		// The mount decides the angle every tic; without these the model would
		// ignore the pitch and roll that lie it flat against your back.
		+FORCEXYBILLBOARD
	}
	States
	{
	Spawn:
		SSTW A -1;
		Stop;
	}
}

// THE SHIELD RIDING YOUR OWN OFF FOREARM, when rs_ss_mount_mode picks that
// over the shoulder. Unlike RS_ShieldStowActor this is never SetOrigin'd into
// a computed world point -- FollowOffHand puts it in the off controller's
// render frame and resolves it at draw rate, the same trick RS_ShieldSawProp
// uses while the shield is actually held. rs_shieldsaw_state.zs still calls
// SetOrigin once a tic to keep the ACTOR (not the drawn model) somewhere
// sensible for culling, sound origin, and Distance-based checks -- that call
// never fights the renderer because the renderer never reads this actor's
// position for a FollowOffHand model.
//
// Local placement -- the offset and rotation within the hand's own frame --
// is rs_ss_stow_ofs_x/y/z/yaw/pitch/roll/scale, read live by MODELDEF's
// PlacementCVars. Those cvars used to be wired to nothing (the "(legacy)"
// menu label was accurate); this is what makes them live again.
class RS_ShieldForearmActor : Actor
{
	Default
	{
		Radius 1;
		Height 1;
		+NOINTERACTION
		+NOBLOCKMAP
		+NOGRAVITY
		+NOTONAUTOMAP
		+DONTSPLASH
	}
	States
	{
	Spawn:
		SSTW A -1;
		Stop;
	}
}

// THE MARKER: a wireframe diamond where the shield lives, so the mount is
// something you can SEE and aim a hand at rather than a number in a menu.
//
// The mesh is HardPoints' rs_hp_diamond.obj, copied rather than referenced --
// this package does not depend on that one, and a shared asset across two mods
// that ship separately is a broken model the first time one of them moves.
//
// It brightens when your hand is close enough to take the shield, which is the
// only feedback that tells you the reach radius is right without turning the
// debug print on.
class RS_ShieldMountMarker : Actor
{
	Default
	{
		Radius 1;
		Height 1;
		Scale 1.0;
		RenderStyle "Add";
		Alpha 0.35;
		+NOBLOCKMAP
		+NOGRAVITY
		+NOINTERACTION
		+DONTSPLASH
		+NOTONAUTOMAP
		+BRIGHT
	}
	States
	{
	Spawn:
		SSMK A -1;
		Stop;
	}
}
