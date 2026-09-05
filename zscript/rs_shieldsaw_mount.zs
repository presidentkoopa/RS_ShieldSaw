// THE SHIELD ON YOUR BACK, AND REACHING OVER YOUR SHOULDER FOR IT.
//
// This replaces the forearm psprite. The forearm was the wrong mount for two
// reasons that only showed up in a headset: a shield big enough to read as a
// shield covers the arm you need to see, and -- worse -- ANY grip squeeze was
// the draw, so the shield fought RS_Hands for every health pack you picked up.
//
// A dedicated anchor fixes both. The draw is now a PLACE, not a button: put
// your off hand over your own shoulder and squeeze. Nothing else in the game
// wants that spot, so there is nothing to arbitrate with.
//
// A WORLD ACTOR, NOT A PSPRITE, and that is forced rather than chosen. A
// psprite is drawn in a HAND's frame; there is no hand at your shoulder blade.
// Body-anchored things are world actors here -- it is what RS_Holsters does for
// all nine of its anchors -- and 35Hz placement is fine for something sitting
// on your back that you never look straight at.
//
// WHAT THIS COSTS: the shield no longer deflects while stowed. It is behind
// you. That was the forearm's one real advantage and it goes with the mount.

class RS_ShieldMount
{
	// WHERE ON YOUR BACK. Read the same way RS_Holsters reads its anchors:
	//   fwd   + is in FRONT of the eye plane, so this is negative -- behind you
	//   side  + is your right, so negative is over the LEFT shoulder
	//   frac  height as a fraction of eye height; 0.86 is about shoulder
	//
	// Anchors hang off HmdPos and the BODY yaw, never head pitch or roll --
	// otherwise looking down would drag the shield down your back with you.
	static Vector3 AnchorPos(PlayerPawn pmo, double fwd, double side, double frac)
	{
		if (!pmo) return (0, 0, 0);

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
