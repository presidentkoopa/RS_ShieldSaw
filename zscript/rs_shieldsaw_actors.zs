// Weapon 1's supporting actors. Nothing here is general -- when weapon 2
// arrives it gets its own file beside this one, and anything both of them
// need moves out into a shared file at that point and not before.
//
//   RS_ShieldInFlight    the thrown shield: flies the locked route, cuts
//                       through each target, returns to be caught.
//   RS_ShieldTrail       its flight trail.
//   RS_ShieldLockMark    the marker sitting on a locked enemy.
//   (the passive guard is no longer an actor -- see RS_ShieldSaw.sweepDeflect)
//   RS_ShieldSawPuff     what the grind leaves behind.

// ==========================================================================
// THE THROWN SHIELD
// ==========================================================================
//
// ROUTE, NOT HOMING. The original re-aimed at whatever you were looking at
// every tic, so the throw went wherever your head went and you could not look
// away from your own shield. Here the route is fixed at release.
//
// +RIPPER is what carries it through a body instead of exploding on the first
// one. The engine keeps a per-missile LastRipped map, so a ripper damages each
// actor once per pass rather than every tic it overlaps them -- which is why
// cutting through five enemies needs no bookkeeping here.

class RS_ShieldInFlight : Actor
{
	Array<Actor> route;
	int          leg;
	bool         homing;
	RS_ShieldSaw  launcher;
	int          hand;
	double       speedMult;
	double       dmgMult;
	private int     stalled;
	private int     age;
	private int     noclipFor;   // tics NOCLIP must stay on regardless
	private bool    legHit;      // the route target actually took a cut
	private int     outbound;    // fly straight this long when nothing is locked
	// THE THROW PLANE. Captured from the wrist at release and held for the
	// whole flight, so the disc spins in the plane you actually threw it in --
	// overhand, sidearm, or anything between -- instead of always vertical.
	double          throwRoll;

	// HOW FAST IT SPINS, degrees per tic, taken off your wrist at release.
	//
	// A saw that does not turn is the whole gesture failing to land: you flick
	// it and a disc slides through the air facing one way for its entire
	// flight. throwRoll below was sampled ONCE and held, which is a facing, not
	// a spin.
	double          spinRate;
	// WHERE IN ITS TURN THE DISC IS. Advanced by spinRate every tic and written to PITCH, which is
	// the actor angle that turns about this mesh's face normal (models.cpp:1590 rotates pitch about
	// GL Z = map Y, and the disc is 47 x 2.89 x 47 with its thin axis on Y). roll stays the throw
	// PLANE, fixed at release. Putting the spin on roll instead turned the disc end over end through
	// its own face, which is a coin spinning on a table and not a thrown shield.
	private double  spinPhase;
	// LastRipped in the engine is a local of P_XYMovement, rebuilt EVERY TIC --
	// it stops a ripper re-hitting within one move, not within one pass. At
	// Speed 22 the shield sits inside a body for about two tics, so without our
	// own set each target took the cut twice per pass.
	private Array<Actor> cutThisLeg;
	private Vector3 prevPos;

	Default
	{
		Speed 22;
		Radius 12;
		Height 12;
		Scale 0.55;
		Projectile;
		// ONE, NOT ZERO. P_DoMissileDamage only calls P_DamageMobj when damage
		// is > 0, so DamageFunction(0) made DoSpecialDamage below dead code and
		// the thrown shield flew the whole route hurting nothing. The 1 is a
		// placeholder the override replaces; it just has to be positive.
		DamageFunction (1);
		DamageType "Saw";
		BounceType "Doom";
		BounceFactor 1.0;
		BounceCount 4;
		+RIPPER
		+INTERPOLATEANGLES
		+USEBOUNCESTATE
		+NOEXTREMEDEATH
		+DONTSPLASH
		Obituary "%o was cut down by a shield saw.";
	}

	void Launch()
	{
		leg = 0;
		homing = false;
		legHit = false;
		spinPhase = throwRoll;
		cutThisLeg.Clear();

		if (route.Size() > 0)
		{
			aimAt(route[0]);
			return;
		}

		// NOTHING PAINTED: fly straight out for a second before turning round.
		// Without this the very first Tick fell to `else GoHome()` and the
		// shield reversed before travelling a single tic, so an un-aimed throw
		// was a weapon-swap flicker and a lost guard for nothing.
		A_ChangeVelocity(vel.x * speedMult, vel.y * speedMult, vel.z * speedMult, CVF_REPLACE);
		outbound = 35;
	}

	// Vel3DFromAngle writes VELOCITY ONLY -- it does not touch Angles.Yaw. Set
	// it too, or the disc renders facing wherever it was thrown for the whole
	// flight, and the trail inherits the same stale angle.
	// NO cutThisLeg.Clear() HERE. aimAt is also the mid-leg course correction
	// (every 4 tics) and the advance re-aim, so clearing here wiped the hit set
	// while the shield was still inside the body it had just cut -- measured at
	// three cuts on one target in a single pass. A new leg is a new pass, and
	// advance()/GoHome() are the only two things that start one.
	private void aimAt(Actor t)
	{
		if (!t) { GoHome(); return; }
		double a = AngleTo(t);
		Vel3DFromAngle(Speed * speedMult, a, RS_ShieldSaw.PitchTo(self, t));
		A_SetAngle(a, SPF_INTERPOLATE);
	}

	// Next living target on the route, or home if there are none left.
	private void advance()
	{
		cutThisLeg.Clear();
		leg++;
		while (leg < route.Size())
		{
			Actor t = route[leg];
			if (t && t.health > 0 && t.bShootable) { aimAt(t); return; }
			leg++;
		}
		GoHome();
	}

	void GoHome()
	{
		if (homing) return;
		// A new leg is a new pass. This used to live in steerHome behind
		// `if (!homing)`, which is never true there -- steerHome is only ever
		// called with homing already set -- so the return trip could not re-cut
		// anything it had passed through on the way out.
		cutThisLeg.Clear();
		homing = true;
		ClearBounce();
		steerHome();
	}

	// HOME IS THE FOREARM. The shield returns to where it was stowed, not to
	// the hand -- by the time it lands you are holding your own weapon again.
	// WHERE HOME IS, AGREED BY EVERY MACHINE. This steered at master.OffhandPos every tic -- the local
	// device's -- so a live missile took a different path on every peer and was destroyed on a
	// different tic. It reads the launcher's published pose now, and falls back to the pawn's own
	// shoulder height when there is none, which is playsim data everywhere.
	Vector3 homePoint()
	{
		if (launcher) return launcher.NetPos();
		return (master.pos.xy, master.pos.z + master.height * 0.75);
	}

	private void steerHome()
	{
		if (!master) { Destroy(); return; }
		Vector3 hp = homePoint();
		double ang = atan2(hp.y - pos.y, hp.x - pos.x);
		double pit = -atan2(hp.z - pos.z, max(1.0, (hp.xy - pos.xy).Length()));
		Vel3DFromAngle(Speed * speedMult * 1.6, ang, pit);
		A_SetAngle(ang, SPF_INTERPOLATE);
	}

	override void Tick()
	{
		Super.Tick();
		if (bDestroyed) return;

		// THE PLANE IS HELD, NOT DERIVED. Vel3DFromAngle rewrites pitch every
		// time the shield steers, and PitchFromMomentum used to overwrite it
		// again at draw time -- either would drag the disc back to whatever
		// plane its velocity implied and undo the throw.
		// THE PLANE IS STILL HELD -- see above -- but the disc TURNS WITHIN IT.
		//
		// throwRoll fixes which way the saw's face points, so steering cannot
		// drag it back to whatever plane its velocity implies. spinRate then
		// rotates it about that face, which is a different axis and does not
		// fight the plane at all.
		//
		// Advanced every tic rather than set once: a single angle change at
		// release is an object facing a different way for its whole flight,
		// which looks worse than not trying.
		spinPhase += spinRate;
		roll  = throwRoll;    // the plane you threw it in
		pitch = spinPhase;    // the disc turning within that plane

		if (level.time % 2 == 0)
		{
			let t = Actor.Spawn("RS_ShieldTrail", pos);
			if (t)
			{
				t.A_SetAngle(angle);
				t.roll  = roll;
				t.pitch = pitch;
			}
		}

		if (!master) { Destroy(); return; }

		if (homing)
		{
			steerHome();
			Vector3 hp = homePoint();
			// The window has to be at least one tic of travel wide, or a fast
			// shield steps straight past the hand and orbits.
			if (Level.Vec3Diff(pos, hp).Length() < max(40.0, vel.Length() * 1.2))
			{
				if (launcher) launcher.Landed();
				master.A_StartSound("rsshield/hit", CHAN_BODY);
				Destroy();
				return;
			}
		}
		else if (leg < route.Size())
		{
			Actor t = route[leg];
			// Proximity stays as the fallback for a target that cannot be cut --
			// already dead, or we passed just wide -- but its radius no longer
			// scales with speed.
			double reach = t ? (t.radius + radius + 8.0) : 32.0;
			if (!t || t.health <= 0 || legHit || Distance3D(t) < reach)
			{
				legHit = false;
				advance();
			}
			else if (level.time % 4 == 0) aimAt(t);
		}
		else if (outbound > 0) outbound--;
		else GoHome();

		// WEDGED IN GEOMETRY. The clear-condition used to run in the same tic as
		// the set, so anything that stuck within 200 units of the player -- the
		// common case, since it is homing at you -- had NOCLIP set and cleared
		// before it moved once, and never escaped. `flying` then stayed non-null
		// for the rest of the level: no deflector, no stow, locks never cleared.
		// ARMING NOCLIP USED TO DISARM IT IN THE SAME TIC: the clear tested
		// `stalled == 0`, and the line that armed it had just zeroed `stalled`.
		// Within 200 units of the player -- the common case, since it is homing
		// at you -- it was set and cleared before Super.Tick() ever moved the
		// actor with it on, so a wedged shield never escaped and sat in the wall
		// for the full twelve seconds.
		//
		// Give it its own timer, and clear on evidence of actual movement
		// rather than on the counter that armed it.
		bool moved = Level.Vec3Diff(pos, prevPos).Length() >= 2.0;
		if (!moved) stalled++; else stalled = 0;
		if (stalled > 6) { stalled = 0; bNOCLIP = true; noclipFor = 20; GoHome(); }
		if (bNOCLIP)
		{
			if (noclipFor > 0) noclipFor--;
			else if (moved) bNOCLIP = false;
		}

		// Last resort. Whatever went wrong, the shield comes back.
		if (++age > 35 * 12)
		{
			if (launcher) launcher.Landed();
			Destroy();
			return;
		}

		prevPos = pos;
	}

	// However this flight ends -- caught, destroyed on a sky ceiling, master
	// gone, timed out -- the locks and their markers go with it. Relying on
	// Caught() alone left stale targets that the NEXT throw would route through.
	override void OnDestroy()
	{
		if (launcher) launcher.ClearLocks();
		Super.OnDestroy();
	}

	override int DoSpecialDamage(Actor victim, int damage, Name damagetype)
	{
		// -1, not 0: P_DamageMobj treats any negative return as "cancel
		// everything", where 0 carries on through the pain and thrust pipeline.
		if (!victim || victim == master) return -1;

		for (int i = 0; i < cutThisLeg.Size(); i++)
			if (cutThisLeg[i] == victim) return -1;
		cutThisLeg.Push(victim);

		// ADVANCE ON A HIT, not on proximity. The proximity threshold scaled
		// with throw speed, so at 3.0 the shield veered off toward the next
		// waypoint about 47 units before touching the current one, and that
		// target took nothing at all.
		if (leg < route.Size() && victim == route[leg]) legHit = true;

		return int(random[ShieldCut](24, 44) * clamp(dmgMult, 0.1, 10.0));
	}

	// Hitting something is not a reason to stop.
	override void Die(Actor source, Actor inflictor, int dmgflags, Name meansofdeath)
	{
		GoHome();
	}

	States
	{
	// SIXTEEN FRAMES OF REAL SPIN, one tic each -- the mesh carries the whole
	// rotation and the old eight-letter run drew frame 0 sixteen times over.
	Spawn:
		SFLY ABCDEFGHIJKLMNOP 1 Bright;
		Loop;
	Bounce:
		SFLY A 0 A_StartSound("rsshield/bounce", CHAN_BODY);
		Goto Spawn;
	Death:
	Crash:
		SFLY A 0 { GoHome(); }
		Goto Spawn;
	}
}

class RS_ShieldTrail : Actor
{
	Default
	{
		Scale 0.55;
		Alpha 0.5;
		RenderStyle "Add";
		+NOINTERACTION
		+NOBLOCKMAP
		+BRIGHT
		+NOTONAUTOMAP
	}
	States
	{
	Spawn:
		SFLY A 3 A_FadeOut(0.25);
		Loop;
	}
}

// ==========================================================================
// THE LOCK MARKER
// ==========================================================================
//
// One per locked enemy, riding above its head. It holds its target in `tracer`
// rather than the weapon holding a list of markers, so a marker can clean
// itself up if the weapon goes away underneath it.

class RS_ShieldLockMark : Actor
{
	Default
	{
		Scale 0.5;
		Alpha 0.9;
		RenderStyle "Add";
		+NOINTERACTION
		+NOBLOCKMAP
		+BRIGHT
		+NOGRAVITY
		+NOTONAUTOMAP
		+FORCEXYBILLBOARD
	}

	static void MarkFor(Actor target)
	{
		if (!target) return;
		let m = Actor.Spawn("RS_ShieldLockMark",
		                    (target.pos.xy, target.pos.z + target.height + 6));
		if (m) m.tracer = target;
	}

	static void ClearFor(Actor target)
	{
		if (!target) return;
		ThinkerIterator it = ThinkerIterator.Create("RS_ShieldLockMark");
		RS_ShieldLockMark m;
		while (m = RS_ShieldLockMark(it.Next()))
			if (m.tracer == target) m.Destroy();
	}

	override void Tick()
	{
		Super.Tick();
		if (!tracer || tracer.health <= 0) { Destroy(); return; }
		SetOrigin((tracer.pos.xy, tracer.pos.z + tracer.height + 6), true);
	}

	States
	{
	Spawn:
		SLCK ABCD 3 Bright;
		Loop;
	}
}

// THE PASSIVE GUARD IS NOT AN ACTOR ANY MORE.
//
// RS_ShieldDeflector lived here: an invisible +SHOOTABLE +REFLECTIVE box riding the hand, with a
// CanCollideWith override meant to let your own fire through. That override was never called --
// PIT_CheckThing only asks P_CanCollideWith when the VICTIM is MF_SOLID, TOUCHY or BUMPSPECIAL
// (p_map.cpp:1550) and the guard was none of them -- so your own missiles detonated on it and your
// own hitscans died on it, while what it actually blocked was a box far smaller than the shield and
// pointed by the hand's yaw alone.
//
// RS_ShieldSaw.sweepDeflect tests a swept disc instead, with the face normal the hand really points.
// Nothing shootable exists, so nothing of yours can run into it. See the note above that function.
//
// RS_ShieldSawPuff below keeps its Species/ALLOWTHRUFLAGS pair even so: it costs nothing, and it is
// the right answer again the moment anything else of ours wants to sit near a trace origin.

// ==========================================================================
// GRIND IMPACT
// ==========================================================================

class RS_ShieldSawPuff : Actor
{
	Default
	{
		// SHARES THE DEFLECTOR'S SPECIES, and that is what makes the grind work
		// at all. The trace starts at the hand, which is inside the deflector's
		// bounding box, and an actor whose box contains the trace origin is
		// pushed as an intercept at frac 0 -- so every trace used to stop dead
		// on our own guard. ALLOWTHRUFLAGS + THRUSPECIES makes CheckForActor
		// skip it instead.
		Species "RS_ShieldSaw";
		+ALLOWTHRUFLAGS
		+THRUSPECIES
		Radius 1;
		Height 1;
		Damage 0;
		Scale 0.4;
		RenderStyle "Add";
		Alpha 0.8;
		+NOBLOCKMAP
		+NOGRAVITY
		+PUFFONACTORS
		+ALWAYSPUFF
		+DONTSPLASH
		+NOTONAUTOMAP
	}

	States
	{
	Spawn:
	Melee:
		TNT1 A 0 A_StartSound("rsshield/hit", CHAN_BODY, CHANF_OVERLAP, 0.4);
		TNT1 A 2;
		Stop;
	}
}
