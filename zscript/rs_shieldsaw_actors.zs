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

	// [TIERS] CODER_PLAN step 55 -- what a hit does depends on what was hit.
	// The disc used to do one thing to everything: roll 24-44 and rip onward, so a
	// zombie and a baron felt identical and the throw had no read to it.
	//
	// Classified on SpawnHealth, not on class names: a modded imp is still fodder and a
	// mod's own boss is still a boss, and a name list would be wrong the first time
	// someone loads a monster pack. Thresholds are cvars because 70 and 600 are the
	// plan's guesses at where Doom's roster divides, and only play can say.
	private Actor embedIn;      // the mid-tier victim the disc is buried in
	private int   embedTics;    // how much longer it grinds there

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
		// THE RETURN LEG HAS TO SURVIVE GEOMETRY. ClearBounce() wiped the bounce type
		// outright, so the first wall or floor on the way home ran P_ExplodeMissile --
		// which zeroes Vel and then clears MF_MISSILE *after* it has already run our
		// Death state, so nothing that state does can put the flag back. The disc then
		// drifted home cutting nothing and stopped against the next thing it touched.
		// Bounce instead: steerHome re-aims every tic, so a bounce costs one tic of
		// heading and nothing else. Count 0 is unlimited -- BounceCount 4 is a budget
		// for the throw, not for getting back. Set, not merely kept, because the
		// outbound leg may already have spent it.
		bBOUNCEONWALLS  = true;
		bBOUNCEONFLOORS = true;
		bouncecount     = 0;
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

		// A LIVE DISC IS ALWAYS A MISSILE. P_ExplodeMissile clears MF_MISSILE *after*
		// it has run our Death state, so `SFLY A 0 { GoHome(); }` cannot put the flag
		// back however it is written -- and without it P_DoMissileDamage is never
		// reached, so DoSpecialDamage never runs, the return leg cuts nothing, and the
		// first wall stops the disc dead. The flag being off here means something
		// exploded us inside Super.Tick() above, so restore it before anything moves
		// again, and noclip just long enough to clear whatever we exploded against --
		// the noclipFor timer further down turns it off once we have actually moved.
		if (!bMissile) { bMissile = true; bNOCLIP = true; noclipFor = 4; }

		// [TIERS] PUT +NOEXTREMEDEATH BACK (step 55). DoSpecialDamage drops it for a
		// fodder hit so the body comes apart, and the engine reads it during that same
		// P_DamageMobj call -- so restoring it here, on the next tic, is after the gib
		// decision and before any other victim can be hit. A mid or heavy later in the
		// same throw therefore keeps its body intact.
		if (!bNOEXTREMEDEATH) bNOEXTREMEDEATH = true;

		// [TIERS] EMBEDDED: grinding in a mid-tier body, so it does not steer, advance
		// or spin-travel this tic. It still spins in place -- the phase below is the
		// face turning, not movement.
		if (embedTick()) return;

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

		// ---- THE GLIDE ----------------------------------------------------
		//
		// A thrown disc does not fly a straight line and it does not drop like
		// a brick either. It falls, slowly, and the spin holds it up -- which
		// is the entire reason throwing a frisbee feels different from throwing
		// a rock, and why a flat throw carries and a wobbly one does not.
		//
		// FREE THROWS ONLY. steerHome and aimAt both rewrite Vel outright, so
		// anything done here would be overwritten the moment a route or the
		// return trip takes over. That is correct rather than a limitation: a
		// locked route IS the disc being steered, and a steered disc does not
		// need lift.
		//
		// LIFT COMES OFF THREE THINGS, all of them things the player did:
		// how hard it is spinning, how fast it is still going forward, and how
		// FLAT the throw was. throwRoll is the plane it left the hand in, so
		// cos of it is flatness -- a sidearm throw glides and a throw made with
		// the disc on edge does not. Nobody has to be told this; it is how a
		// frisbee already behaves in everyone's hands.
		//
		// CAPPED BELOW THE FALL, so lift can slow a descent and flatten it but
		// never turn it into a climb. A disc that gains height on its own reads
		// as a bug however good the reason.
		if (!homing && route.Size() == 0)
		{
			double fall = RS_ShieldSaw.CvarNumServer("rs_ss_fall", 0.11);
			double flat = abs(cos(throwRoll));
			double fwd  = Vel.xy.Length() / max(1.0, Speed * speedMult);
			double lift = RS_ShieldSaw.CvarNumServer("rs_ss_lift", 0.09)
			            * clamp(abs(spinRate) / 31.0, 0.0, 1.5)
			            * clamp(fwd, 0.0, 1.5)
			            * flat;
			Vel.z -= max(fall - min(lift, fall), 0.0);
		}

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

		int roll = int(random[ShieldCut](24, 44) * clamp(dmgMult, 0.1, 10.0));

		// [TIERS] WHAT THE HIT DOES, BY WHAT WAS HIT (step 55).
		//
		// Off: the disc behaves exactly as it did, so this cannot regress a throw that
		// already felt right.
		if (!RS_ShieldTier.On(self)) return roll;

		int tier = RS_ShieldTier.Of(victim, self);

		if (tier == RS_ShieldTier.FODDER)
		{
			// BISECT. +NOEXTREMEDEATH is dropped FOR THIS HIT ONLY -- it is a flag on
			// the disc, so it is cleared here and put back on the way out, and a mid
			// or heavy hit in the same pass still keeps its body intact. The owner
			// answered Q43 for exactly this: "a thrown saw blade that leaves a body
			// intact reads wrong."
			//
			// Damage is forced past the gib threshold rather than left to the roll: a
			// 24 on a 60-health former human is a kill, not a bisection, and the whole
			// point of the tier is that fodder comes apart every time.
			bNOEXTREMEDEATH = false;
			A_StartSound("rsshield/hit", CHAN_BODY);
			int gib = victim.GetGibHealth();
			return max(roll, victim.health - gib + 1);
		}

		if (tier == RS_ShieldTier.MID)
		{
			// EMBED. The disc buries itself and grinds, which is the Dark Ages beat the
			// step names. Held in Tick rather than by stopping the actor: a missile with
			// no velocity is still a missile and the engine would carry on resolving it
			// against the world.
			if (!embedIn)
			{
				embedIn   = victim;
				embedTics = RS_ShieldTier.EmbedTics(self);
				Vel = (0, 0, 0);
				A_StartSound("rsshield/hit", CHAN_BODY);
			}
			victim.TriggerPainChance('Saw', true);
			return roll;
		}

		// HEAVY / BOSS. It glances: a shield saw does not bury itself in a baron. The
		// bounce is the disc's own BounceType, so this only has to decline to embed and
		// let the engine's bounce do the work -- and the reduced damage is what makes a
		// heavy feel like a wall rather than a slower zombie.
		victim.TriggerPainChance('Saw', true);
		return max(1, int(roll * RS_ShieldTier.GlanceScale(self)));
	}

	// [TIERS] The embed: hold on the victim and grind, then leave. Called from Tick.
	private bool embedTick()
	{
		if (!embedIn) return false;

		// GONE, DEAD, OR OUT OF TIME -- all three end it, and a dead host must not hold
		// the disc in mid-air.
		if (embedIn.health <= 0 || embedTics <= 0)
		{
			embedIn = null; embedTics = 0;
			GoHome();
			return false;
		}

		embedTics--;
		// Ride the body rather than hang where it was hit: a monster that walks away
		// with a saw in it should take the saw with it.
		SetOrigin((embedIn.pos.xy, embedIn.pos.z + embedIn.height * 0.5), true);
		Vel = (0, 0, 0);

		int per = RS_ShieldTier.EmbedDamage(self);
		if (per > 0) embedIn.DamageMobj(self, master, per, 'Saw');
		return true;
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

// ===========================================================================
// [TIERS] WHAT A THROWN DISC DOES, BY WHAT IT HIT (CODER_PLAN step 55)
// ===========================================================================
//
// The disc used to do one thing to everything: roll 24-44 and rip onward. A zombie and a
// baron felt identical, so the throw had no read to it and no reason to aim.
//
// CLASSIFIED ON SpawnHealth, NEVER ON CLASS NAMES. A modded imp is still fodder and a
// mod's own boss is still a boss; a name list would be wrong the first time a monster pack
// is loaded, and wrong silently. SpawnHealth is the one number every monster declares.
//
// The thresholds are the plan's guesses at where Doom's roster divides -- 70 takes the
// former humans and imps, 600 reaches the barons -- so they are cvars, because only play
// can say where the line actually is.
//
// A STATIC HELPER, NOT FIELDS ON THE DISC. The disc is spawned per throw and these are
// settings, so reading them here keeps one copy of the policy that the bash, the grind and
// anything later can all ask.
class RS_ShieldTier
{
	enum ETier
	{
		FODDER = 0,   // bisect: comes apart
		MID    = 1,   // embed: the disc buries itself and grinds
		HEAVY  = 2,   // glance: it bounces off
	}

	private static double num(string n, double fb)
	{ let c = CVar.FindCVar(n); return c ? c.GetFloat() : fb; }
	private static int inum(string n, int fb)
	{ let c = CVar.FindCVar(n); return c ? c.GetInt() : fb; }

	// FindCVar, not GetCVar: these are `server` cvars and decide damage, so they are the
	// same for every peer and need no PlayerInfo. GetCVar with a null player would answer
	// for whoever happened to be asking.
	static bool On(Actor disc)
	{
		let c = CVar.FindCVar("rs_ss_tiers");
		return c ? c.GetBool() : true;
	}

	static int Of(Actor victim, Actor disc)
	{
		if (!victim) return HEAVY;
		// SpawnHealth is the monster's AUTHORED health, not what is left of it -- a baron
		// on its last hit point is still a baron and must not suddenly bisect.
		int sh = victim.SpawnHealth();
		if (victim.bBoss) return HEAVY;
		if (sh <= inum("rs_ss_tier_fodder", 70))  return FODDER;
		if (sh <= inum("rs_ss_tier_mid", 600))    return MID;
		return HEAVY;
	}

	static int    EmbedTics(Actor disc)   { return clamp(inum("rs_ss_embed_tics", 21), 0, 140); }
	static int    EmbedDamage(Actor disc) { return clamp(inum("rs_ss_embed_dps", 3), 0, 50); }
	static double GlanceScale(Actor disc) { return clamp(num("rs_ss_glance_scale", 0.4), 0.0, 2.0); }
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
