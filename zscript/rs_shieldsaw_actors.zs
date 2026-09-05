// Weapon 1's supporting actors. Nothing here is general -- when weapon 2
// arrives it gets its own file beside this one, and anything both of them
// need moves out into a shared file at that point and not before.
//
//   RS_ShieldInFlight    the thrown shield: flies the locked route, cuts
//                       through each target, returns to be caught.
//   RS_ShieldTrail       its flight trail.
//   RS_ShieldLockMark    the marker sitting on a locked enemy.
//   RS_ShieldDeflector   the invisible guard that turns projectiles away while
//                       the shield is in hand.
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
		if (route.Size() > 0) aimAt(route[0]);
		else A_ChangeVelocity(vel.x * speedMult, vel.y * speedMult, vel.z * speedMult, CVF_REPLACE);
	}

	// Vel3DFromAngle writes VELOCITY ONLY -- it does not touch Angles.Yaw. Set
	// it too, or the disc renders facing wherever it was thrown for the whole
	// flight, and the trail inherits the same stale angle.
	private void aimAt(Actor t)
	{
		if (!t) { GoHome(); return; }
		cutThisLeg.Clear();
		double a = AngleTo(t);
		Vel3DFromAngle(Speed * speedMult, a, RS_ShieldSaw.PitchTo(self, t));
		A_SetAngle(a, SPF_INTERPOLATE);
	}

	// Next living target on the route, or home if there are none left.
	private void advance()
	{
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
		homing = true;
		ClearBounce();
		steerHome();
	}

	// HOME IS THE FOREARM. The shield returns to where it was stowed, not to
	// the hand -- by the time it lands you are holding your own weapon again.
	private void steerHome()
	{
		if (!master) { Destroy(); return; }
		if (!homing) cutThisLeg.Clear();
		Vector3 hp = master.OffhandPos;
		double ang = atan2(hp.y - pos.y, hp.x - pos.x);
		double pit = -atan2(hp.z - pos.z, max(1.0, (hp.xy - pos.xy).Length()));
		Vel3DFromAngle(Speed * speedMult * 1.6, ang, pit);
		A_SetAngle(ang, SPF_INTERPOLATE);
	}

	override void Tick()
	{
		Super.Tick();
		if (bDestroyed) return;

		if (level.time % 2 == 0)
		{
			let t = Actor.Spawn("RS_ShieldTrail", pos);
			if (t) t.A_SetAngle(angle);
		}

		if (!master) { Destroy(); return; }

		if (homing)
		{
			steerHome();
			Vector3 hp = (hand != 0) ? master.OffhandPos : master.AttackPos;
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
			if (!t || t.health <= 0 || Distance3D(t) < max(32.0, vel.Length() * 1.2)) advance();
			else if (level.time % 4 == 0) aimAt(t);
		}
		else GoHome();

		// WEDGED IN GEOMETRY. The clear-condition used to run in the same tic as
		// the set, so anything that stuck within 200 units of the player -- the
		// common case, since it is homing at you -- had NOCLIP set and cleared
		// before it moved once, and never escaped. `flying` then stayed non-null
		// for the rest of the level: no deflector, no stow, locks never cleared.
		if (Level.Vec3Diff(pos, prevPos).Length() < 2.0) stalled++;
		else stalled = 0;
		if (stalled > 6) { stalled = 0; bNOCLIP = true; GoHome(); }
		if (bNOCLIP && homing && stalled == 0 && Distance3D(master) < 200) bNOCLIP = false;

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

		return int(random[ShieldCut](24, 44) * clamp(dmgMult, 0.1, 10.0));
	}

	// Hitting something is not a reason to stop.
	override void Die(Actor source, Actor inflictor, int dmgflags, Name meansofdeath)
	{
		GoHome();
	}

	States
	{
	Spawn:
		SFLY ABCDEFGH 1 Bright;
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

// ==========================================================================
// THE PASSIVE DEFLECTOR
// ==========================================================================
//
// Stock +REFLECTIVE does the work: a missile striking a reflective actor is
// turned around and sent back at whoever fired it.
//
// NOT +SOLID -- a solid actor riding your forearm would shove monsters and
// trap you inside it. NOT +THRUACTORS either: PIT_CheckThing skips the
// collision outright if EITHER party has that flag, so a THRUACTORS shield is
// one that missiles fly straight through. It would look installed and block
// nothing.

class RS_ShieldDeflector : Actor
{
	Default
	{
		Radius 16;
		Height 40;
		Health 1000;
		Mass 1;
		+SHOOTABLE
		+REFLECTIVE
		+AIMREFLECT
		+NOGRAVITY
		+NOBLOOD
		+NOPAIN
		+DONTTHRUST
		+DONTRIP
		Species "RS_ShieldSaw";
		+NOTARGET
		// Without this a +SHOOTABLE actor riding your hand is a legal autoaim
		// target -- P_AimLineAttack only skips actors flagged NOTAUTOAIMED
		// (p_map.cpp:4430) -- so the OTHER hand's weapon aims at your shield.
		+NOTAUTOAIMED
		// No +NODAMAGE: MF5_NODAMAGE is only consulted inside P_DamageMobj's
		// native body, and DamageMobj below returns without calling Super, so
		// the flag never ran. Returning 0 is what actually makes it immune.
		+INVISIBLE
		+NOTONAUTOMAP
	}

	private bool suppressed;

	// Our owner's own shots must not come home. DamageMobj runs BEFORE the
	// engine reads bReflective -- PIT_CheckThing damages, then P_XYMovement
	// reflects -- so clearing the flag there stops that one missile being
	// turned around. This puts it back. The original never did, which is why
	// firing through your own shield disabled it permanently.
	override void Tick()
	{
		if (suppressed) { bReflective = true; suppressed = false; }
		Super.Tick();
	}

	override int DamageMobj(Actor inflictor, Actor source, int damage, Name mod, int flags, double angle)
	{
		// MISSILES ONLY. `source == master` also matches the player's own splash
		// damage and melee, and each of those was clearing bReflective until the
		// deflector's next tick -- a one-tic hole an enemy missile could arrive
		// in and detonate instead of bouncing.
		bool own = master && inflictor && inflictor.bMissile &&
		           (source == master || inflictor.target == master);
		if (own)
		{
			bReflective = false;
			suppressed = true;
			return 0;
		}

		if (inflictor && inflictor.bMissile)
		{
			A_StartSound("rsshield/hit", CHAN_BODY);
			level.VRHaptic(0, 0.7, 50.0);
		}
		return 0;
	}

	States
	{
	Spawn:
		TNT1 A -1;
		Stop;
	}
}

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
