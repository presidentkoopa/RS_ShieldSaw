// WEAPON 1 -- THE SHIELD SAW.
//
// Rebuilt, not ported. Rusted Legacy's original was `extend class
// RLOffhandFist`: not a weapon at all, but a mode bolted onto the off-hand
// fist, and it needed DoomWeaponZ, rlvr_Settings, the weapon HUD and the aim
// laser before it would compile. None of that is here. This is a plain
// Weapon on stock GZDoom, it works in either hand, and it is the only thing
// in this mod so far.
//
// HOW IT PLAYS. The shield hangs on a mount over your off shoulder. Reach
// your off hand back, squeeze, and it comes into that hand -- whatever was in
// it is set aside. Attack and the disc grinds what it touches while the same
// sweep paints anything further off. Let go and it flies the painted route,
// cutting each in turn, and returns to the mount; your own weapon is back in
// your hand the instant it leaves. Release at the mount instead and it just
// goes back.
//
// ONE ATTACK INPUT, TWO JOBS. Holding the grip is what keeps the shield in
// your hand, and a grip-held main fire arrives as alt-fire -- so there is
// effectively one attack available. Rather than choose, it grinds and paints
// at once.
//
// THE STATE MACHINE OWNS WHERE THE SHIELD IS, not this file. Nothing in a
// weapon's own state table can tell the difference between "in your hand" and
// "on your back", which is why every attack here asks A_ShieldDrawn first.
//
// WHAT CHANGED FROM THE ORIGINAL, and why:
//
//   * It is a weapon now, not a mode on the fist. The fist should be a fist.
//
//   * The throw locks a LIST. The original auto-aimed at one nearest target
//     inside 30 degrees and then you flew it by looking at things --
//     A_GuideShieldMotion re-aimed it at your view every single tic, so you
//     could not look away from your own shield. Fixing the route at the
//     moment of release frees your head and makes the throw a decision about
//     who dies in what order.
//
//   * Its deflector cleared bReflective when your own shot struck it and
//     NEVER PUT IT BACK, so the first time you fired through your own shield
//     it stopped deflecting for the rest of the level. Tick restores it, and
//     CanCollideWith now stops the collision outright.
//
//   * The seven fixed throw planes (RollOffset 0, +/-30, +/-60, +/-90, chosen
//     by jumping to one of seven spawn states) are one continuous angle now:
//     the wrist's roll at release, held for the whole flight.
//
//   * Motion throw was gated behind the oVRdrive mod being loaded
//     (`shieldMotionThrow = !ovrdrive_loaded ? false : ...`). Dropped rather
//     than carried as a dead dependency on a mod we do not ship.
//
// MODEL FRAMES, read off the meshes rather than guessed:
//   shield.md3     0 closed .. 3 fully open
//   shieldsaw.md3  0 stowed, 1-4 deploying, 5-7 spinning
//   hand.md3       frame 1
// SSAW is the with-hand key, SSNH without. The sprite frames behind them are
// blank 1x1 images and they are LOAD-BEARING: Weapon::TryPickup refuses any
// weapon whose Ready state has no valid sprite frame, so without them the
// weapon compiles, loads, and can never be picked up.

class RS_ShieldSaw : Weapon
{
	// ---- lock-on ----------------------------------------------------------
	Array<Actor> locks;
	private int  lastLockTic;

	// ---- flight -----------------------------------------------------------
	Actor flying;                   // the thrown shield; null when in hand

	// ---- THE PUBLISHED HAND POSE ------------------------------------------
	//
	// Playsim state, identical on every machine, written only by rs-ss-pose (RS_ShieldState). Every
	// gameplay decision this weapon makes reads it through NetPos / NetAngle / NetPitch below rather
	// than touching AttackPos / OffhandPos directly, because those are the LOCAL device's and are
	// stand-ins everywhere else -- which had the guard reflecting different missiles and the lock cone
	// catching different enemies on every peer.
	//
	// Untouched in single-player: the accessors hand back the live pose there, at no latency.
	Vector3 netHandPos;
	double  netHandAngle, netHandPitch;
	bool    netPoseValid;

	void PublishPose(Vector3 p, double ang, double pit)
	{
		netHandPos = p; netHandAngle = ang; netHandPitch = pit; netPoseValid = true;
	}

	// WHAT GAMEPLAY IS ALLOWED TO READ. In a netgame this is the published pose on every machine, the
	// holder's included -- a holder acting on a fresher pose than its peers is the same divergence with
	// one fewer machine in it.
	Vector3 NetPos()   { return (multiplayer && netPoseValid) ? netHandPos   : HandPos(); }
	double  NetAngle() { return (multiplayer && netPoseValid) ? netHandAngle : HandAngle(); }
	double  NetPitch() { return (multiplayer && netPoseValid) ? netHandPitch : HandPitch(); }

	// ---- settings, refreshed once a second --------------------------------
	private int    maxLocks;
	private double lockCone;
	private double lockRange;
	private double throwSpeed;
	private double cutDamage;
	private bool   deflectOn;
	private bool   handModel;
	private double guardRadius;
	private double guardStandoff;
	// [VECTOROUT] guardPlane's answer. Fields, not `out Vector3` parameters: a vector passed by
	// reference hands the ZScript JIT a register type it has no case for, and the class dies at load
	// (RS_WorldHands/zscript/hands/rs_grab.zs:19 documents the same trap). Do not collapse these back.
	private Vector3 guardCentre;
	private Vector3 guardNormal;
	private bool   deflectAim;

	Default
	{
		// THE WEAPON DECLARES ITS OWN SLOT. KEYCONF's addslotdefault did not
		// take -- the weapon ended up in inventory and in no slot, so it could
		// not be selected at all. SlotNumber is merged into the default slot
		// set by the engine and does not clear the slot the way setslot does.
		Weapon.SlotNumber 1;
		Weapon.SlotPriority 0.9;
		Weapon.SelectionOrder 3700;
		Weapon.Kickback 100;
		Weapon.AmmoUse 0;
		Weapon.AmmoGive 0;
		Inventory.PickupMessage "You got the Shield Saw!";
		// AN OFF-HAND WEAPON. It lives on the off arm: held in that hand, and
		// strapped to that forearm when it is not. PlayerPawn.BringUpWeapon
		// reads bOffhandWeapon and routes the weapon to player.OffhandWeapon,
		// so this flag is what puts it in the right hand rather than any code
		// on our side.
		//
		// NOHANDSWITCH keeps it there: without it the weapon can be moved to
		// the main hand, and everything about this design -- the forearm stow,
		// the deflector's placement -- assumes one arm.
		+WEAPON.OFFHANDWEAPON
		+WEAPON.NOHANDSWITCH
		+WEAPON.MELEEWEAPON
		+WEAPON.NOALERT
		+WEAPON.NOAUTOAIM
		+WEAPON.AMMO_OPTIONAL
		// TWO DIFFERENT FLAGS, AND ONLY ONE OF THEM DOES THIS.
		// NOAUTOSWITCHTO (WIF_NOAUTOSWITCHTO) keeps a weapon out of the
		// autoswitch PICKER. NO_AUTO_SWITCH (WIF_NO_AUTO_SWITCH) is what
		// Weapon::AttachToOwner actually reads before setting PendingWeapon on
		// a give. Without the second one the shield equipped itself the moment
		// it was granted -- in the hand while the state machine still said
		// stowed, so it drew twice and the first throw lost the off-hand weapon.
		+WEAPON.NOAUTOSWITCHTO
		+WEAPON.NO_AUTO_SWITCH
		Obituary "%o was cut down by a shield saw.";
		Tag "Shield Saw";
	}

	// ======================================================================
	// helpers
	// ======================================================================

	// Centre-mass pitch from one actor to another. Positive is DOWN, matching
	// the playsim. Four lines, written here, because borrowing it is what
	// dragged a base class in last time.
	static double PitchTo(Actor from, Actor to)
	{
		if (!from || !to) return 0.0;
		double dist = from.Distance2D(to);
		double dz   = (to.pos.z + to.height * 0.5) - (from.pos.z + from.height * 0.5);
		return -atan2(dz, max(1.0, dist));
	}

	private static double cvNum(string n, PlayerInfo p, double fb)
	{ let c = CVar.GetCVar(n, p); return c ? c.GetFloat() : fb; }
	private static int cvInt(string n, PlayerInfo p, int fb)
	{ let c = CVar.GetCVar(n, p); return c ? c.GetInt() : fb; }
	private static bool cvOn(string n, PlayerInfo p, bool fb)
	{ let c = CVar.GetCVar(n, p); return c ? c.GetBool() : fb; }

	// EITHER HAND, in one place. Everything below reads position and aim from
	// these three, so "works in the off hand" is one branch and not forty.
	Vector3 HandPos()
	{
		if (!owner) return (0, 0, 0);
		return bOffhandWeapon ? owner.OffhandPos : owner.AttackPos;
	}
	// THE +90 AND THE NEGATION ARE NOT FUDGE FACTORS. The engine stores
	// AttackAngle as (viewYaw - 90) and AttackPitch as (-viewPitch)
	// -- hw_vrmodes.cpp:1421 and :1445. Every consumer in the stdlib converts
	// them back the same way; see weaponmace.zs:91-92. Reading them raw points
	// the shield 90 degrees off and inverts its pitch.
	double HandAngle()
	{
		if (!owner) return 0.0;
		return (bOffhandWeapon ? owner.OffhandAngle : owner.AttackAngle) + 90.0;
	}
	double HandPitch()
	{
		if (!owner) return 0.0;
		return -(bOffhandWeapon ? owner.OffhandPitch : owner.AttackPitch);
	}

	// Which sound channel this hand owns. CHAN_WEAPON is the MAIN hand's; an
	// offhand weapon shouting on it cuts off the main weapon's fire sound.
	int HandChan() { return bOffhandWeapon ? CHAN_OFFWEAPON : CHAN_WEAPON; }
	int HandIndex() { return bOffhandWeapon ? 1 : 0; }

	private bool isHeld()
	{
		if (!owner || !owner.player) return false;
		return owner.player.ReadyWeapon == self || owner.player.OffhandWeapon == self;
	}

	// ======================================================================
	// upkeep
	// ======================================================================

	override void Tick()
	{
		Super.Tick();

		// NOTHING TO ORPHAN. The guard used to be an actor in the map, so an early
		// return here leaked an invisible +SHOOTABLE thing forever. It is a test
		// run from this Tick now -- stop ticking and it is simply gone.
		if (!owner || !owner.player || owner.health < 1) return;

		// maxLocks == 0 is the never-read state, not a legal setting -- without
		// this the first second of every map has no locks, no deflector and
		// zero grind damage.
		if (maxLocks == 0 || GetAge() % 35 == 0) readSettings();

		pruneLocks();
		sweepDeflect();
		applyModel();
	}

	private void readSettings()
	{
		let p = owner.player;
		maxLocks   = clamp(cvInt("rs_ss_locks", p, 5), 1, 16);
		lockCone   = clamp(cvNum("rs_ss_lock_cone", p, 14.0), 1.0, 90.0);
		lockRange  = clamp(cvNum("rs_ss_lock_range", p, 1200.0), 64.0, 8192.0);
		throwSpeed = clamp(cvNum("rs_ss_throw_speed", p, 1.0), 0.1, 5.0);
		cutDamage  = clamp(cvNum("rs_ss_cut_damage", p, 1.0), 0.1, 10.0);
		deflectOn  = cvOn("rs_ss_deflect", p, true);
		handModel  = cvOn("rs_ss_handmodel", p, true);
		// THE DISC YOU ACTUALLY BLOCK WITH. The shield is 19.7 map units across in the hand, so its
		// own rim is a radius of about 10; 14 is that plus the slack a moving hand needs for the
		// thing to be worth raising at all. Its own slider, because only a headset can say whether
		// it reads as a shield or as a cheat.
		guardRadius   = clamp(cvNum("rs_ss_guard_radius", p, 14.0), 2.0, 64.0);
		guardStandoff = clamp(cvNum("rs_ss_guard_standoff", p, 6.0), 0.0, 32.0);
		deflectAim    = cvOn("rs_ss_deflect_aim", p, true);
	}

	// A locked target that died is not a waypoint any more.
	private void pruneLocks()
	{
		for (int i = locks.Size() - 1; i >= 0; i--)
		{
			Actor a = locks[i];
			if (!a || a.health <= 0 || !a.bShootable)
			{
				if (a) RS_ShieldLockMark.ClearFor(a);
				locks.Delete(i);
			}
		}
	}

	void ClearLocks()
	{
		for (int i = 0; i < locks.Size(); i++)
			if (locks[i]) RS_ShieldLockMark.ClearFor(locks[i]);
		locks.Clear();
	}

	// ======================================================================
	// PASSIVE -- the guard
	// ======================================================================
	//
	// NO ACTOR, AND THAT IS THE FIX RATHER THAN A TIDY-UP.
	//
	// The guard used to be RS_ShieldDeflector: +SHOOTABLE, +REFLECTIVE, leaning on a CanCollideWith
	// override to let your own fire through. PIT_CheckThing only asks P_CanCollideWith when the
	// VICTIM is MF_SOLID, TOUCHY or BUMPSPECIAL (p_map.cpp:1550), and the guard was none of the
	// three -- so that override was never called once. Your own rocket ran P_DoMissileDamage on it,
	// DamageMobj cleared bReflective so it would not come home, P_ReflectOffActor then declined, and
	// P_ExplodeMissile went off eighteen units from your hand. Hitscans have no victim-side veto in
	// the engine at all and simply died on it.
	//
	// Nothing shootable exists here now, so there is nothing left for your own fire to run into,
	// from any weapon, at any range. The shield asks the question itself instead.
	//
	// AND IT ASKS IT ABOUT THE SHIELD YOU CAN SEE. The old box was placed with AngleToVector on the
	// hand's YAW ALONE -- raise the shield to meet a fireball coming down at you and the guard did
	// not move -- and it was smaller than the disc. This is a swept disc with the face normal the
	// hand is actually pointing, in both axes.
	//
	// LOCAL POSES, AS EVERYWHERE ELSE IN THIS FILE. OffhandPos/OffhandAngle are real only on the
	// machine whose headset writes them, exactly as they were for the old guard's placement -- no
	// worse than what it replaces and no better. Networking the hand pose is the real answer and is
	// an engine question, not this file's.

	// The shield's face: where its centre is, and which way it looks.
	private bool guardPlane()
	{
		guardCentre = (0, 0, 0);
		guardNormal = (1, 0, 0);
		if (!owner || !owner.player || flying || !deflectOn) return false;
		let p = owner.player;

		if (isHeld())
		{
			// BOTH AXES. HandPitch is already playsim convention (positive down), so this is the
			// ordinary Doom direction vector and nothing here needs a second opinion about signs.
			double ang = NetAngle(), pit = NetPitch();
			guardNormal = (cos(pit) * cos(ang), cos(pit) * sin(ang), -sin(pit));
			guardCentre = NetPos() + guardNormal * guardStandoff;
			return true;
		}

		// STOWED. rs_ss_deflect_stowed splits the two: on, the mount keeps guarding, which is the
		// point of wearing it; off, only a shield in your hand blocks anything.
		if (!cvOn("rs_ss_deflect_stowed", p, true)) return false;

		if (mountMode() == 1)
		{
			// The forearm. The face looks across the arm, not down its muzzle.
			double ang = NetAngle() + 90.0;
			guardNormal = (cos(ang), sin(ang), 0);
			guardCentre = NetPos();
			return true;
		}

		// The shoulder. It is on your BACK, so the face it presents is behind you -- which is the
		// one thing a shield you are not holding is actually good for.
		// THE MOUNT SLIDERS ARE `user` CVARS AND THIS IS A COLLISION TEST, so in a netgame they are
		// ignored and the shipped defaults are used instead. Two players with different seating
		// preferences must not guard different volumes; in single-player the sliders still do what
		// they always did. (AnchorPos itself reads HmdPos, which is local too -- so the stowed guard
		// in a netgame hangs off the pawn's own body yaw and nothing else.)
		Vector3 a = RS_ShieldMount.AnchorPos(PlayerPawn(owner),
			mountNum("rs_ss_mount_fwd",  -7.0),
			mountNum("rs_ss_mount_side", -8.0),
			mountNum("rs_ss_mount_frac",  0.86));
		a.z -= mountNum("rs_ss_mount_drop", 11.0);
		double bang = owner.angle + mountNum("rs_ss_mount_yaw", 0.0) + 180.0;
		guardNormal = (cos(bang), sin(bang), 0);
		guardCentre = a;
		return true;
	}

	// A SEATING SLIDER THAT DECIDES A COLLISION TEST IS A SERVER VALUE IN ALL BUT NAME. These are
	// declared `user` because they are where a player likes the shield to sit, so in a netgame they
	// are ignored and everyone uses the shipped default.
	private double mountNum(string n, double fb)
	{
		if (multiplayer) return fb;
		return cvNum(n, owner ? owner.player : null, fb);
	}

	private int mountMode()
	{
		if (multiplayer) return 0;
		return cvInt("rs_ss_mount_mode", owner ? owner.player : null, 0);
	}

	// ONE TIC OF FLIGHT AGAINST ONE DISC.
	//
	// A missile is caught when the segment it will travel THIS TIC crosses the shield's plane from
	// the front, inside the disc. Testing the swept segment rather than where the missile happens to
	// be sitting is what stops a fast one stepping straight through: a revenant missile covers ten
	// units in a tic and a plane has no thickness.
	private void sweepDeflect()
	{
		if (!guardPlane()) return;
		Vector3 c = guardCentre, n = guardNormal;

		double reach = guardRadius + 48.0;
		BlockThingsIterator it = BlockThingsIterator.CreateFromPos(
			c.x, c.y, c.z - reach, reach * 2.0, reach, false);

		while (it.Next())
		{
			Actor mo = it.thing;
			if (!mo || !mo.bMissile || mo.bNoInteraction || mo.bNoClip) continue;
			// YOURS PASSES. Once turned, a missile's target IS you -- which is also what stops it
			// being caught a second time on its way back out.
			if (mo == owner || mo.target == owner || mo.master == owner) continue;
			if (mo is "RS_ShieldInFlight") continue;

			Vector3 v = mo.Vel;
			Vector3 rel = Level.Vec3Diff(c, mo.Pos);      // the missile, relative to the face
			double d0 = rel dot n;                        // in front of it is positive
			double d1 = (rel + v) dot n;                  // and where it will be next tic

			// FROM THE FRONT, AND IT HAS TO REACH THE PLANE THIS TIC. The missile's own radius is
			// slack on the far side, so a round stopping just short still counts as arriving.
			if (d0 <= 0 || d1 > mo.radius * 0.5) continue;
			double span = d0 - d1;
			if (span <= 0.0001) continue;

			double t = clamp(d0 / span, 0.0, 1.0);
			Vector3 hit = rel + v * t;
			Vector3 radial = hit - n * (hit dot n);
			if (radial.Length() > guardRadius + mo.radius) continue;

			deflect(mo, n);
		}
	}

	// TURNED, NOT EATEN. Back at whoever fired it while they are still standing, and mirrored off
	// the face otherwise -- a shot that came from a corpse still has to go somewhere, and somewhere
	// should be where the shield was pointing.
	private void deflect(Actor mo, Vector3 n)
	{
		Actor shooter = mo.target;

		// THE DIRECTION IT CAME IN ON, TAKEN NOW. `mo.Vel` is rewritten further down to send the
		// missile back out, and after that line the travel vector points the wrong way entirely --
		// the spray would lean away from the shooter instead of back off the shield.
		Vector3 came = (mo.Vel.Length() > 0.0001) ? mo.Vel.Unit() : -n;

		// THE KILL IS YOURS from here. It is also what makes the missile pass back through you on
		// the way out: the engine's own "do not missile your own shooter" rule doing the work.
		mo.target = owner;
		if (mo.bSeekerMissile) mo.tracer = shooter;

		double sp = max(mo.Speed, mo.Vel.Length());
		if (sp <= 0) sp = 10.0;

		Vector3 dir;
		if (deflectAim && shooter && shooter.health > 0 && shooter != owner)
		{
			dir = Level.Vec3Diff(mo.Pos, (shooter.pos.xy, shooter.pos.z + shooter.height * 0.5));
		}
		else
		{
			Vector3 v = mo.Vel;
			dir = v - n * (2.0 * (v dot n));
		}
		if (dir.Length() < 0.0001) dir = n;
		dir = dir.Unit();

		mo.Vel = dir * sp;
		mo.A_SetAngle(VectorAngle(dir.x, dir.y), SPF_INTERPOLATE);
		mo.pitch = -asin(clamp(dir.z, -1.0, 1.0));

		owner.A_StartSound("rsshield/hit", CHAN_BODY);

		// WHAT THE DEFLECTION LOOKS LIKE (RS_Ballistics, RSB_Impact.Land).
		//
		// WHAT IS DEFLECTED DECIDES THE LOOK, NOT WHAT THE SHIELD IS MADE OF. A material variant
		// asks about a SURFACE, and a shield turning a shot in mid-air has none -- so the profile
		// is chosen from the incoming missile instead.
		//
		// Classified on ENGINE-GENERAL PROPERTIES rather than class names so a modded monster's
		// fireball still reads as fire. RSB_Bullet is the exception worth naming: with
		// sv_rsb_enemy_rounds on, a monster's hitscan is a travelling projectile, so a shield can
		// genuinely bat a bullet out of the air -- and it should look like one rather than like a
		// plasma ball. The last two are a TUNING call: if a particular monster reads wrong in play,
		// move it, the shape is right.
		String what = "deflect";
		if (mo is "RSB_Bullet")            what = "deflect_bullet";
		else if (mo.DamageType == 'Fire')  what = "deflect_fire";
		else if (mo.bBRIGHT)               what = "deflect_energy";
		else if (mo.bNOBLOOD)              what = "deflect_goo";

		// THE `true` IS inAirToo AND NOTHING DRAWS WITHOUT IT. A deflection happens in open air and
		// the impact system correctly refuses to invent a surface that was never hit -- FromBlocking
		// returns null there. It used to hand one back regardless, which is how melee effects played
		// full stone impacts in mid-air; that is fixed, so an open-air effect must now be ASKED for
		// rather than arriving by accident. Do not copy a Land() call that omits this and assume it
		// works: the behaviour that made omission look fine is gone.
		RSB_Impact.Land(mo, what, came, true);

		if (owner.PlayerNumber() == consoleplayer)
			level.VRHaptic(HandIndex(), 0.7, 50.0);
	}

	// ======================================================================
	// FIRE -- the grind
	// ======================================================================
	//
	// A vertical fan of short traces out of the hand. Thirteen at 30-degree
	// steps covers the arc a spinning disc actually sweeps; a single forward
	// trace does not, and a saw held sideways should still cut.
	const GRIND_RANGE = 48.0;

	// STOWED MEANS STOWED. Nothing in the weapon's own state table can tell
	// whether the shield is on your arm or in your hand -- the state machine
	// owns that -- so every attack asks it first.
	//
	// Without this, any path that left the shield as OffhandWeapon while the
	// state machine still said STOWED had it grinding continuously off the
	// forearm: the psprite runs its Fire states as soon as it is the off-hand
	// weapon, and the player never asked for it.
	action bool A_ShieldDrawn()
	{
		if (!player) return false;
		let st = RS_ShieldState.Get();
		if (!st) return true;                       // no handler: do not block
		return st.StateOf(invoker.owner.PlayerNumber()) == RS_ShieldState.SS_DRAWN;
	}

	action void A_ShieldGrind()
	{
		if (!player) return;
		if (!A_ShieldDrawn()) return;
		let pmo = player.mo;

		// THRUSPECIES ON THE PUFF IS LOad-BEARING, not decoration. The trace
		// starts at the hand, which is INSIDE the deflector's bounding box, and
		// AddThingIntercepts pushes an actor whose box contains the origin at
		// frac 0 -- so without this every grind trace terminated on our own
		// guard and the saw cut nothing. RS_ShieldSawPuff and RS_ShieldDeflector
		// share a Species for exactly this.
		int laflags = LAF_NORANDOMPUFFZ;
		if (invoker.bOffhandWeapon) laflags |= LAF_ISOFFHAND;

		// LineAttack in VR already takes its direction from the controller
		// transform, and MapWeaponDir treats the angle argument as a DELTA on
		// top of it -- so passing the hand angle applies the controller yaw
		// twice. Stock A_Saw passes the pawn's own yaw for exactly this reason.
		double ang = pmo.angle;
		int alf = ALF_PORTALRESTRICT | (invoker.bOffhandWeapon ? ALF_ISOFFHAND : 0);
		double pitch = pmo.BulletSlope(null, alf);
		// LineAttack's damage parameter is an INT, and ZScript truncates. With
		// a base of 1 the slider did nothing at all below 1.0 -- 0.2 through
		// 0.9 all floored to zero damage, silently, and berserk multiplied zero
		// by four. Scale from a base above 1 and round.
		double dmg = 6 * invoker.cutDamage;
		if (pmo.CountInv("PowerStrength")) dmg *= 4;
		int idmg = max(1, int(round(dmg)));

		// A FORWARD ARC, NOT A SPHERE. `i <= 12` at 30 degrees swept a full
		// vertical circle -- straight up, straight down and straight backwards --
		// and traced the forward direction twice into the bargain. Five steps of
		// 22 degrees is the arc a disc held in front of you actually sweeps.
		for (int i = -2; i <= 2; i++)
			pmo.LineAttack(ang, GRIND_RANGE, pitch + i * 22, idmg,
			               'Melee', "RS_ShieldSawPuff", laflags);

		level.VRHaptic(invoker.HandIndex(), 0.35, 30.0);
	}

	// ======================================================================
	// ALT-FIRE -- sweep to lock
	// ======================================================================
	//
	// The cone is measured from the HAND, not the eye. Pointing the shield is
	// the gesture, and in VR those are two different directions.
	// ONE INPUT, BOTH JOBS.
	//
	// Holding the grip is what keeps the shield in your hand, and in this
	// control scheme a grip-held main fire arrives as alt-fire -- so there is
	// effectively ONE attack input available while the shield is out. Rather
	// than pick between grinding and aiming, it does both: the disc cuts what
	// it physically passes through, and the same sweep paints anything further
	// off that you point at. Release the grip and the throw visits what you
	// painted.
	action void A_ShieldSweep()
	{
		if (!A_ShieldDrawn()) return;
		invoker.acquire();
	}

	private void acquire()
	{
		if (!owner || !owner.player) return;
		if (locks.Size() >= maxLocks) return;
		// level.time RESETS TO 0 on a level change and this weapon persists in
		// inventory, so a stamp from four minutes into the last map makes this
		// difference hugely negative -- and the guard then holds for four
		// minutes on the new map with no lock ever possible.
		if (lastLockTic > level.time) lastLockTic = -100;
		if (level.time - lastLockTic < 3) return;      // ~8 scans/sec
		// Stamped HERE, not only on success: the guard above is the throttle, and
		// leaving it un-stamped on a miss meant holding alt while pointing at
		// nothing ran a level-wide ThinkerIterator plus a CheckSight per monster
		// every single tic.
		lastLockTic = level.time;

		let pmo = owner.player.mo;
		// THE PUBLISHED POSE, not the local device's: this list becomes the thrown shield's route, so
		// two machines disagreeing here send the disc to different enemies.
		Vector3 hp = NetPos();
		double  ha = NetAngle();
		double  hpit = NetPitch();

		Actor best; double bestOff = lockCone;

		ThinkerIterator it = ThinkerIterator.Create("Actor");
		Actor mo;
		while (mo = Actor(it.Next()))
		{
			if (!mo || mo == pmo) continue;
			if (!mo.bIsMonster || !mo.bShootable || mo.health <= 0) continue;
			if (mo.bCorpse || mo.bFriendly) continue;
			if (alreadyLocked(mo)) continue;
			if (pmo.Distance3D(mo) > lockRange) continue;
			if (!pmo.CheckSight(mo)) continue;

			// FROM THE HAND, which is what the comment above always claimed.
			// pmo.AngleTo takes the bearing from the PAWN CENTRE, and in VR the
			// hand is 10-20 units off it -- about 8-11 degrees of error at 100
			// units, against a 14 degree cone. Close targets simply would not
			// lock, or the wrong one won.
			double dAng   = absangle(ha, VectorAngle(mo.pos.x - hp.x, mo.pos.y - hp.y));
			double tPitch = -atan2((mo.pos.z + mo.height * 0.5) - hp.z,
			                       max(1.0, (mo.pos.xy - hp.xy).Length()));
			// tPitch is ALREADY playsim convention (positive = down), same as
			// PitchTo returns, and hpit is too now that HandPitch negates. The
			// old -hpit/-tPitch pair made this a SUM, so a target 10 degrees up
			// read as 20 degrees off and only dead-level targets ever locked.
			double dPit   = abs(deltaangle(hpit, tPitch));
			double off    = max(dAng, dPit);

			if (off < bestOff) { bestOff = off; best = mo; }
		}

		if (best)
		{
			locks.Push(best);
			lastLockTic = level.time;
			RS_ShieldLockMark.MarkFor(best);
			owner.A_StartSound("rsshield/lock", CHAN_6, CHANF_OVERLAP);
			level.VRHaptic(HandIndex(), 0.5, 25.0);
		}
	}

	private bool alreadyLocked(Actor a)
	{
		for (int i = 0; i < locks.Size(); i++)
			if (locks[i] == a) return true;
		return false;
	}

	// ======================================================================
	// the throw
	// ======================================================================

	// THE LAUNCH, as a plain method: the grip release is detected by the state
	// machine, not by a weapon state, so this has to be callable from outside
	// an action context.
	// The release edge is already spent by the time we get here, so a failed
	// launch that just returned left the shield in the hand with no gesture
	// able to reach it. Reachable: SpawnPlayerMissile returns null when the
	// spawn point is inside geometry, which is what throwing with your arm
	// through a wall does.
	private void failLaunch()
	{
		let st = RS_ShieldState.Get();
		if (st && owner) st.LaunchFailed(owner.PlayerNumber());
	}

	// THE RELEASE VELOCITY, MEASURED ON THE THROWER'S OWN MACHINE ONLY.
	//
	// RS_ThrowService answers from RS_Swing, which samples the CONSOLE player's
	// controller -- a reading that exists on one machine and nowhere else. So it
	// is asked once, by RS_ShieldState's grip poll (which runs only for the local
	// player), and the answer travels in rs-ss-throw's three int args to every
	// machine alike; LaunchNow never asks the service for it. Thousandths of a
	// map unit per tic, as the service returns them. (0, 0, 0) when nothing
	// answers.
	static Vector3 MeasureRelease(PlayerPawn pmo, int hand)
	{
		ServiceIterator it = ServiceIterator.Find("RS_ThrowService");
		Service sv;
		while (sv = it.Next())
		{
			if (sv.GetInt("throw.hello", "", 0, 0, null, 'None') != 1) continue;
			double mx = sv.GetInt("throw.vel.x", "", hand, 0, pmo, 'RS_ShieldSaw');
			double my = sv.GetInt("throw.vel.y", "", hand, 0, pmo, 'RS_ShieldSaw');
			double mz = sv.GetInt("throw.vel.z", "", hand, 0, pmo, 'RS_ShieldSaw');
			return (mx, my, mz);
		}
		return (0, 0, 0);
	}

	// relX/Y/Z: the release velocity in map units per tic, as measured on the
	// thrower's machine and carried by rs-ss-throw (MeasureRelease above).
	void LaunchNow(double relX = 0, double relY = 0, double relZ = 0)
	{
		if (!owner || !owner.player || flying) return;
		let p = owner.player;

		// #8: the grind's looping idle belongs to a state sequence we are about
		// to abandon when the previous weapon is raised.
		owner.A_StopSound(HandChan());

		// NOTHING IN THE WAY OF THE LAUNCH ANY MORE. The old guard was a SHOOTABLE DONTRIP actor
		// overlapping the spawn point, so P_SpawnPlayerMissile's own P_TryMove failed against it and
		// handed back NULL -- one of the two ways a throw used to fail outright.
		int alflags = bOffhandWeapon ? ALF_ISOFFHAND : 0;
		Actor sh = owner.SpawnPlayerMissile("RS_ShieldInFlight", aimflags: alflags);
		if (!sh) { ClearLocks(); failLaunch(); return; }

		// Cast BEFORE claiming `flying`: SpawnPlayerMissile allows replacement,
		// so a `replaces` in the load order makes this null, and assigning
		// flying first would strand the weapon.
		let f = RS_ShieldInFlight(sh);
		if (!f) { sh.Destroy(); ClearLocks(); failLaunch(); return; }

		flying = sh;
		sh.master = owner;
		sh.target = owner;

		f.launcher  = self;
		f.hand      = HandIndex();

		// THE PLANE COMES FROM YOUR WRIST. OffhandRoll is the raw controller
		// roll, so throwing sidearm sends the disc round sidearm and overhand
		// sends it vertical -- the shield flies in the plane you threw it in.
		f.throwRoll = bOffhandWeapon ? owner.OffhandRoll : owner.MainHandRoll;
		f.roll      = f.throwRoll;

		// ---- THE SPIN YOUR WRIST PUT ON IT ---------------------------------
		//
		// Asked of RS_WorldHands by SERVICE, never by class: a ZScript class
		// reference to a pk3 that is absent, or that loads later, is fatal AND
		// global and takes down every mod after it. Nothing answers, no spin,
		// and the shield flies exactly as it always has.
		//
		// The velocity is asked for below, and only for a free throw: a painted
		// route steers the disc, so the hand's measured velocity is the right
		// input only when nothing is locked.
		//
		// Roll specifically, because that is the axis a disc spins about: the
		// face stays in its plane and turns within it.
		double wristSpin = 0;
		if (RS_ShieldSaw.cvOn("rs_ss_spin", owner.player, true))
		{
			ServiceIterator sit = ServiceIterator.Find("RS_ThrowService");
			Service sv;
			while (sv = sit.Next())
			{
				if (sv.GetInt("throw.hello", "", 0, 0, null, 'None') != 1) continue;
				// Thousandths -- a Service returns an int.
				double r = sv.GetInt("throw.spin.roll", "", HandIndex(), 0,
					owner, 'RS_ShieldSaw') / 1000.0;
				wristSpin = r * RS_ShieldSaw.cvNum("rs_ss_spin_scale", owner.player, 1.0);
				break;
			}
		}

		// A THROWN SHIELD ALWAYS SPINS, and that is not a detail -- it is what makes it read as
		// thrown rather than slid through the air. A wrist roll of zero is the common case (no
		// RS_WorldHands, or a straight overhand throw with no twist in it), and taking it
		// literally left the disc facing one way for its whole flight.
		//
		// The wrist rides ON TOP of a floor rather than replacing it, the same shape the grenade's
		// lazy tumble already uses: a hard twist spins visibly harder, a flat throw still turns.
		// Degrees per tic -- 26 is about three quarters of a turn a second.
		double baseSpin = RS_ShieldSaw.cvNum("rs_ss_spin_base", owner.player, 26.0);
		f.spinRate = (wristSpin < 0 ? -1.0 : 1.0) * max(abs(wristSpin), baseSpin);
		f.speedMult = throwSpeed;
		f.dmgMult   = cutDamage;

		// ---- THE HEADING YOUR ARM GAVE IT, when nothing is locked -----------
		//
		// The owner, 2026-09-14: "make sure they are both velocity based" / "we
		// want real vr mechanics". With targets painted the route still steers
		// the disc -- that is the lock-on. With none it leaves along the swing
		// that released it, not along the hand's aim: a throw, not a point and
		// fire. The release is already gated on the hand moving
		// (RS_ShieldState's motion half), and the velocity is RS_WorldHands'
		// measurement of that release -- the one the grenade throws on.
		//
		// NETPLAY: it is NOT asked of the service here. This runs on every machine,
		// and the service samples each machine's OWN player's controller, so asking
		// here sent the disc a different way on every machine (the desync
		// uzdxrema-63 found in the first version, 2026-09-14). The thrower's machine
		// measures it once as it sends rs-ss-throw (MeasureRelease above) and every
		// machine launches from those args. Zero -- no service on the sender, or no
		// velocity -- flies the aimed line exactly as before. Speed follows the arm
		// inside a band around the tuned Speed, so a lob and a hurl differ without
		// either breaking the route home; Launch then applies rs_ss_throw_speed on
		// top as it always has.
		if (locks.Size() == 0)
		{
			Vector3 tv = (relX, relY, relZ);
			double tlen = tv.Length();
			if (tlen > 0.5)
			{
				double tspeed = clamp(tlen, sh.Speed * 0.5, sh.Speed * 2.0);
				sh.Vel = tv / tlen * tspeed;
				sh.angle = VectorAngle(relX, relY);
			}
		}

		for (int i = 0; i < locks.Size(); i++)
			f.route.Push(locks[i]);

		f.Launch();

		owner.A_StartSound("rsshield/throw", HandChan());
		owner.A_AlertMonsters(640);
		level.VRHaptic(HandIndex(), 0.8, 60.0);

		// Your previous weapon comes back NOW, not when the shield lands.
		let st = RS_ShieldState.Get();
		if (st) st.Thrown(owner.PlayerNumber());
	}


	// THE SHIELD DOES NOT COME BACK TO YOUR HAND. It returns to the forearm
	// it was drawn from -- by then you are holding whatever you were holding
	// before, and putting it back in your hand would take that away again.
	//
	// This also removes the catch window entirely, which was a tuning problem
	// with no good answer: too tight and you drop it, too loose and it snaps
	// to you from across the room.
	void Landed()
	{
		flying = null;
		ClearLocks();
		let st = RS_ShieldState.Get();
		if (st && owner) st.Landed(owner.PlayerNumber());
	}

	// Returns a state rather than setting one: SetWeaponState is an RLVR
	// helper off DoomWeaponZ and this weapon does not have that base. An
	// anonymous state function returning a state is the stock way.

	// HAND MODEL ON OR OFF, EVERY TIC.
	//
	// The sprite name IS the MODELDEF key, so one write picks the variant --
	// but DPSprite::SetState reassigns Sprite from the state on every state
	// change (p_pspr.cpp:673), so writing it from a state action only survives
	// until the next frame of that state. Doing it here covers Ready, Select,
	// Deselect, the grind, the sweep and WaitReturn without duplicating the
	// whole state table.
	private void applyModel()
	{
		let p = owner.player;
		if (!p) return;
		if (p.ReadyWeapon != self && p.OffhandWeapon != self) return;

		let psp = p.FindPSprite(bOffhandWeapon ? PSP_OFFHANDWEAPON : PSP_WEAPON);
		if (!psp) return;

		// ---- THE WORLD PROP DRAWS IT NOW -----------------------------------
		//
		// When rs_ss_world is on, a world actor on the controller draws the
		// shield and this layer must draw NOTHING -- otherwise there are two
		// shields, one of them glued to your view.
		//
		// The LAYER STAYS. It still runs every state: the deploy, the grind
		// loop, the sweep, the stow and the return are all this state machine,
		// and the prop only copies the frame it lands on. Killing the layer
		// would kill the weapon; making it invisible is the whole change.
		//
		// NoDraw rather than a TNT1 sprite, because the frame LETTER is what
		// the prop reads -- park it on TNT1 and every frame reads as A and the
		// shield never opens.
		let c = CVar.GetCVar("rs_ss_world", p);
		if (c && c.GetBool()) { psp.NoDraw = true; return; }
		psp.NoDraw = false;

		int spr = GetSpriteIndex(handModel ? "SSAW" : "SSNH");
		if (spr < 0) return;
		psp.sprite = spr;
	}

	States
	{
	Ready:
		SSAW A 1 A_WeaponReady(WRF_ALLOWRELOAD | WRF_ALLOWZOOM);
		Loop;

	Deselect:
		SSAW A 1 A_Lower(160);
		Loop;

	Select:
		SSAW A 1 A_Raise(160);
		Loop;

	// ---- grind and paint, together ---------------------------------------
	Fire:
	AltFire:
		SSAW A 0 A_JumpIf(invoker.flying != null, "Ready");
		SSAW A 0 { if (!A_ShieldDrawn()) return ResolveState("Ready"); return ResolveState(null); }
		SSAW A 0 A_StartSound("rsshield/raise", invoker.HandChan());
		SSAW BCDE 2;                                    // saw deploys
	// ONE CUT PER TURN OF THE DISC, NOT THREE.
	//
	// This ran A_ShieldGrind on all three frames -- thirty-five grinds a second, each firing FIVE
	// LineAttacks across the arc, and a body big enough to stand in that arc catches several of them
	// per call. Four figures of damage a second on anything that touched it, and a hundred and
	// seventy-five traces a second to produce them. The fan is right: a disc sweeps its whole
	// diameter and a saw held sideways should still cut. The CADENCE was wrong.
	//
	// Grinding on the first frame of the three is about twelve cuts a second, which is a saw. The
	// sweep stays on all three -- it paints rather than cuts, and it throttles itself to eight scans
	// a second inside acquire() regardless.
	GrindLoop:
		SSAW A 0 A_StartSound("rsshield/idle", invoker.HandChan(), CHANF_LOOPING);
		SSAW F 1 { A_ShieldGrind(); A_ShieldSweep(); }
		SSAW GH 1 A_ShieldSweep();
		SSAW A 0 A_ReFire("GrindLoop");
		SSAW A 0 A_StopSound(invoker.HandChan());
		SSAW EDCB 2;                                    // saw stows
		Goto Ready;

	// NO Recall/WaitReturn STATES. During flight the shield is not the
	// OffhandWeapon -- Thrown() puts your own weapon back the instant it
	// leaves -- so this state table is not running at all and anything here
	// could never fire. Recall is driven from the state machine instead: a
	// grip press while FLYING sends rs-ss-recall.

	// The engine warns about MODELDEF sprites no state references.
	Placeholder:
		SSNH A 1;
		Stop;

	Spawn:
		SSAW A -1;
		Stop;
	}
}
