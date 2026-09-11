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
	Actor deflector;                // the passive guard; null while thrown

	// ---- settings, refreshed once a second --------------------------------
	private int    maxLocks;
	private double lockCone;
	private double lockRange;
	private double throwSpeed;
	private double cutDamage;
	private bool   deflectOn;
	private bool   handModel;

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

	// The owner guard in Tick only covers "no owner". If the weapon itself is
	// destroyed -- morph, ClearInventory -- Tick stops running entirely and the
	// deflector is orphaned as an invisible +SHOOTABLE +REFLECTIVE actor.
	override void OnDestroy()
	{
		if (deflector) { deflector.Destroy(); deflector = null; }
		Super.OnDestroy();
	}

	override void Tick()
	{
		Super.Tick();

		// BEFORE the early return, not after: holdDeflector is the only thing
		// that destroys the guard, so bailing out first orphans an invisible
		// +SHOOTABLE +REFLECTIVE actor in the map forever.
		if (!owner || !owner.player || owner.health < 1)
		{
			if (deflector) { deflector.Destroy(); deflector = null; }
			return;
		}

		// maxLocks == 0 is the never-read state, not a legal setting -- without
		// this the first second of every map has no locks, no deflector and
		// zero grind damage.
		if (maxLocks == 0 || GetAge() % 35 == 0) readSettings();

		pruneLocks();
		holdDeflector();
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
	// PASSIVE -- the deflector
	// ======================================================================
	//
	// It exists only while the shield is actually in the hand. Throwing it is
	// meant to COST you the guard -- that is the whole balance of the weapon,
	// and it is what makes the throw a decision instead of a rotation.
	private void holdDeflector()
	{
		// HELD OR STOWED, BUT NOT THROWN -- and only while the state machine
		// agrees the shield exists somewhere on you. Throwing it is what costs
		// you the guard, and that is the weapon's balance.
		//
		// rs_ss_deflect_stowed splits the two: on, the forearm keeps deflecting
		// (the point of the mount); off, only a shield actually in your hand
		// blocks anything, which is the stricter reading and the one to use if
		// a permanent guard feels like too much.
		bool want = deflectOn && !flying && isHeld();
		if (!want && deflectOn && !flying && !isHeld())
		{
			let p = owner.player;
			want = p && cvOn("rs_ss_deflect_stowed", p, true);
		}

		if (!want)
		{
			if (deflector) { deflector.Destroy(); deflector = null; }
			return;
		}

		if (!deflector)
		{
			deflector = Actor.Spawn("RS_ShieldDeflector", owner.pos);
			if (!deflector) return;
			deflector.master = owner;
		}

		// Held: on the hand holding it. Stowed: wherever the model actually is
		// -- the off hand in forearm mode, the shoulder anchor in shoulder
		// mode. This used to be OffhandPos unconditionally, which was correct
		// only for the forearm and put the guard in the player's empty hand
		// instead of on their back for the whole time the shoulder mount has
		// existed.
		bool held = isHeld();
		Vector3 hp;
		double  ang;
		// WHERE THE GUARD SITS, RELATIVE TO ITS FACING -- almost always the
		// same as ang (straight out from the anchor), except forearm-stowed
		// below, which needs to disagree with its own facing on purpose.
		double  offAng;
		if (held)
		{
			hp     = HandPos();
			ang    = HandAngle();
			offAng = ang;
		}
		else
		{
			let p = owner.player;
			if (p && cvInt("rs_ss_mount_mode", p, 0) == 1)
			{
				hp  = owner.OffhandPos;
				ang = owner.OffhandAngle + 90.0;

				// SIDEWAYS, NOT DOWNRANGE. ang here is not just a facing --
				// it IS the off hand's live aim direction, the same line its
				// own weapon fires along (see HandAngle/A_ShieldGrind's use
				// of OffhandAngle for the same hand). Offsetting the guard
				// 18 units straight out along ang, like every other case
				// here does, plants the invisible hitbox dead in that
				// muzzle's path -- every offhand shot ran into its own
				// shield at point-blank range and got eaten or reflected.
				// The guard is +INVISIBLE, so moving its collision off the
				// firing line costs nothing visually; the model on the arm
				// does not move.
				offAng = ang + 90.0;
			}
			else
			{
				hp = RS_ShieldMount.AnchorPos(PlayerPawn(owner),
					cvNum("rs_ss_mount_fwd",  p, -7.0),
					cvNum("rs_ss_mount_side", p, -8.0),
					cvNum("rs_ss_mount_frac", p,  0.86));
				hp.z -= cvNum("rs_ss_mount_drop", p, 11.0);
				// No hand angle exists at a shoulder blade; face the guard
				// outward with the body, same as the model's own yaw.
				ang    = owner.angle + cvNum("rs_ss_mount_yaw", p, 0.0) + 90.0;
				offAng = ang;
			}
		}
		// A FULL RADIUS CLEAR, PLUS SLACK. At half the pawn radius the hand sat
		// INSIDE the guard's bounding box, and an actor whose box contains a
		// trace origin is an intercept at frac 0 -- so every hitscan the player
		// fired died at zero range, from any weapon. The guard is radius 10 now,
		// so 18 units out puts the origin comfortably outside it.
		Vector3 at = hp + (Actor.AngleToVector(offAng, 18.0), 0);
		deflector.SetOrigin(at - (0, 0, deflector.height * 0.5), false);
		deflector.A_SetAngle(ang);
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
		Vector3 hp = HandPos();
		double  ha = HandAngle();
		double  hpit = HandPitch();

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

	void LaunchNow()
	{
		if (!owner || !owner.player || flying) return;
		let p = owner.player;

		// #8: the grind's looping idle belongs to a state sequence we are about
		// to abandon when the previous weapon is raised.
		owner.A_StopSound(HandChan());

		// THE GUARD HAS TO GO FIRST. It sits 8 units off the hand with radius
		// 16; the missile spawns ~11 units out with radius 12, so they overlap,
		// the spawn-time P_TryMove fails against a SHOOTABLE DONTRIP actor, and
		// P_SpawnPlayerMissile explodes it and hands back NULL.
		if (deflector) { deflector.Destroy(); deflector = null; }

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
		// The velocity is NOT asked for, deliberately. This is a homing, routed
		// projectile that locks targets and comes back -- its heading is aimed,
		// not thrown, so a hand-measured velocity would be the wrong input. The
		// spin is the half of a throw that genuinely belongs to your wrist.
		//
		// Roll specifically, because that is the axis a disc spins about: the
		// face stays in its plane and turns within it.
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
				f.spinRate = r * RS_ShieldSaw.cvNum("rs_ss_spin_scale", owner.player, 1.0);
				break;
			}
		}
		f.speedMult = throwSpeed;
		f.dmgMult   = cutDamage;

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
	GrindLoop:
		SSAW A 0 A_StartSound("rsshield/idle", invoker.HandChan(), CHANF_LOOPING);
		SSAW FGH 1 { A_ShieldGrind(); A_ShieldSweep(); }
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
