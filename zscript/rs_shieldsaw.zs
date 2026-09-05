// WEAPON 1 -- THE SHIELD SAW.
//
// Rebuilt, not ported. Rusted Legacy's original was `extend class
// RLOffhandFist`: not a weapon at all, but a mode bolted onto the off-hand
// fist, and it needed DoomWeaponZ, rlvr_Settings, the weapon HUD and the aim
// laser before it would compile. None of that is here. This is a plain
// Weapon on stock GZDoom, it works in either hand, and it is the only thing
// in this mod so far.
//
// THREE VERBS.
//   PASSIVE   while it is IN YOUR HAND, a deflector rides it and turns
//             incoming projectiles back at whoever fired them.
//   FIRE      hold: the saw deploys and grinds whatever it touches.
//   ALT-FIRE  hold: sweep the hand across enemies to lock them, one marker
//             each; release throws the shield, which cuts through every
//             locked target in order, then returns to be caught.
//             Tap alt while it is out to recall it early.
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
//     it stopped deflecting for the rest of the level. Tick restores it.
//
//   * Motion throw was gated behind the oVRdrive mod being loaded
//     (`shieldMotionThrow = !ovrdrive_loaded ? false : ...`). Dropped rather
//     than carried as a dead dependency on a mod we do not ship.
//
// MODEL FRAMES, read off the meshes rather than guessed:
//   shield.md3     0 closed .. 3 fully open
//   shieldsaw.md3  0 stowed, 1-4 deploying, 5-7 spinning
//   hand.md3       frame 1
// SSAW is the with-hand key, SSNH without. Both are MODELDEF lookups only --
// there are no graphics behind either name.

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
		+WEAPON.NOAUTOSWITCHTO
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
		// STOWED COUNTS. The whole point of the forearm mount is that the
		// shield keeps working when it is not in your hand; gating this on
		// isHeld() silently dropped the passive the instant you switched
		// weapons, which contradicted the menu text and the cvar comment.
		bool want = deflectOn && !flying;

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

		// Held: on the hand holding it. Stowed: on the off forearm, where the
		// model is drawn.
		bool held = isHeld();
		Vector3 hp = held ? HandPos() : owner.OffhandPos;
		double ang = held ? HandAngle() : (owner.OffhandAngle + 90.0);
		Vector3 at = hp + (Actor.AngleToVector(ang, owner.radius * 0.5), 0);
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

	action void A_ShieldGrind()
	{
		if (!player) return;
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
		double dmg   = 1 * invoker.cutDamage;
		if (pmo.CountInv("PowerStrength")) dmg *= 4;

		// A FORWARD ARC, NOT A SPHERE. `i <= 12` at 30 degrees swept a full
		// vertical circle -- straight up, straight down and straight backwards --
		// and traced the forward direction twice into the bargain. Five steps of
		// 22 degrees is the arc a disc held in front of you actually sweeps.
		for (int i = -2; i <= 2; i++)
			pmo.LineAttack(ang, GRIND_RANGE, pitch + i * 22, dmg,
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
		invoker.acquire();
	}

	private void acquire()
	{
		if (!owner || !owner.player) return;
		if (locks.Size() >= maxLocks) return;
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

			double dAng   = absangle(ha, pmo.AngleTo(mo));
			double tPitch = -atan2((mo.pos.z + mo.height * 0.5) - hp.z,
			                       max(1.0, pmo.Distance2D(mo)));
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
	void LaunchNow()
	{
		if (!owner || !owner.player || flying) return;
		let p = owner.player;

		// THE GUARD HAS TO GO FIRST. It sits 8 units off the hand with radius
		// 16; the missile spawns ~11 units out with radius 12, so they overlap,
		// the spawn-time P_TryMove fails against a SHOOTABLE DONTRIP actor, and
		// P_SpawnPlayerMissile explodes it and hands back NULL.
		if (deflector) { deflector.Destroy(); deflector = null; }

		int alflags = bOffhandWeapon ? ALF_ISOFFHAND : 0;
		Actor sh = owner.SpawnPlayerMissile("RS_ShieldInFlight", aimflags: alflags);
		if (!sh) { ClearLocks(); return; }

		// Cast BEFORE claiming `flying`: SpawnPlayerMissile allows replacement,
		// so a `replaces` in the load order makes this null, and assigning
		// flying first would strand the weapon.
		let f = RS_ShieldInFlight(sh);
		if (!f) { sh.Destroy(); ClearLocks(); return; }

		flying = sh;
		sh.master = owner;
		sh.target = owner;

		f.launcher  = self;
		f.hand      = HandIndex();
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

	action void A_ShieldRecall()
	{
		let f = RS_ShieldInFlight(invoker.flying);
		if (f) f.GoHome();
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
	action State A_ShieldWaitCheck()
	{
		if (!invoker.flying) return ResolveState("Ready");
		return ResolveState(null);
	}

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
		if (!handModel) {} // read once, below
		let p = owner.player;
		if (!p) return;
		if (p.ReadyWeapon != self && p.OffhandWeapon != self) return;

		int spr = GetSpriteIndex(handModel ? "SSAW" : "SSNH");
		if (spr < 0) return;
		let psp = p.FindPSprite(bOffhandWeapon ? PSP_OFFHANDWEAPON : PSP_WEAPON);
		if (psp) psp.sprite = spr;
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
		SSAW A 0 A_StartSound("rsshield/raise", invoker.HandChan());
		SSAW BCDE 2;                                    // saw deploys
	GrindLoop:
		SSAW A 0 A_StartSound("rsshield/idle", invoker.HandChan(), CHANF_LOOPING);
		SSAW FGH 1 { A_ShieldGrind(); A_ShieldSweep(); }
		SSAW A 0 A_ReFire("GrindLoop");
		SSAW A 0 A_StopSound(invoker.HandChan());
		SSAW EDCB 2;                                    // saw stows
		Goto Ready;

	WaitReturn:
		SSAW A 1
		{
			A_WeaponReady(WRF_ALLOWRELOAD | WRF_ALLOWZOOM);
			return A_ShieldWaitCheck();
		}
		Loop;

	Recall:
		SSAW A 2 A_ShieldRecall();
		Goto WaitReturn;

	// The engine warns about MODELDEF sprites no state references.
	Placeholder:
		SSNH A 1;
		Stop;

	Spawn:
		SSAW A -1;
		Stop;
	}
}
