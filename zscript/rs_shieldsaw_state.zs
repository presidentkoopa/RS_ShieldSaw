// THE SHIELD'S THREE STATES, AND THE LOADOUT SWAP BETWEEN THEM.
//
//   STOWED   on the mount over your off shoulder. The resting state.
//   DRAWN    in the off hand. Whatever off-hand weapon you were holding has
//            been set aside and comes back the moment you throw.
//   FLYING   thrown. Your previous weapon is ALREADY back -- you are never
//            weaponless during the flight -- and the shield returns to the
//            MOUNT, not to your hand, which is what removes the catch.
//
// THE SHIELD IS AN INTERRUPT, NOT A WEAPON SLOT. You break out of your loadout
// for one grind-and-throw and then you are back where you were. Nothing here
// should ever leave you holding nothing.
//
// INPUT CROSSES THE NETWORK, ALWAYS.
//
// GripHeldOff is written by the VR runtime for the CONSOLE PAWN ONLY -- it is
// not in ticcmd and does not travel. WorldTick runs on every peer, so reading
// it there and acting directly desyncs the playsim the moment anyone gestures:
// machine A sees player A's grip and machine B does not. So the console player
// detects its own edges locally and SENDS them; every peer then acts on the
// netevent, which is the one thing they all agree about. The bound key already
// went this way and was always correct.

class RS_ShieldState : EventHandler
{
	enum EShieldState
	{
		SS_STOWED = 0,
		SS_DRAWN,
		SS_FLYING,
	}

	private int   mState[MAXPLAYERS];
	private Actor mStowProp[MAXPLAYERS];    // the shield on your back (shoulder mode)
	private Actor mForearmProp[MAXPLAYERS]; // the shield on your off forearm (forearm mode)
	private Actor mMarker[MAXPLAYERS];      // the wireframe diamond at the mount
	private bool  mAtShoulder;              // console player is reaching (or, in
	                                         // forearm mode, holding a free grip), now
	// The off-hand weapon the draw displaced, and the MAIN-hand weapon if
	// BringUpWeapon had to drop it because one of the two was two-handed.
	private Class<Weapon> mPrevOff[MAXPLAYERS];
	private Class<Weapon> mPrevMain[MAXPLAYERS];

	// Console-local input state. Not playsim; never read for a remote peer.
	private bool mGripWas;
	private transient Service mArb;   // cached; re-resolved when null

	private static double cvNum(string n, PlayerInfo p, double fb)
	{ let c = CVar.GetCVar(n, p); return c ? c.GetFloat() : fb; }
	private static bool cvOn(string n, PlayerInfo p, bool fb)
	{ let c = CVar.GetCVar(n, p); return c ? c.GetBool() : fb; }

	static RS_ShieldState Get() { return RS_ShieldState(EventHandler.Find("RS_ShieldState")); }

	// Haptics are a LOCAL effect. VR_ScriptHaptic has no player filter, so
	// firing it for a remote player's draw would buzz THIS player's controller.
	private static void buzz(int pnum, double power, double ms)
	{
		if (pnum != consoleplayer) return;
		level.VRHaptic(1, power, ms);      // 1 = off hand; this weapon lives there
	}

	// ======================================================================
	// THE GRIP ARBITER
	// ======================================================================
	//
	// The off-hand grip is not ours. RS_Hands closes it on world objects,
	// RS_Reload on a magazine, RS_Holsters on the chest pouch.
	//
	// Requiring the hand to be AT THE MOUNT is what really settles this -- a
	// squeeze anywhere else is somebody else's business -- but the arbiter is
	// still asked, because two mods can want the same place.
	//
	// Found by STRING through ServiceIterator: no compile-time link in either
	// direction, so this mod still loads and runs completely alone. A hit is
	// not proof of identity either -- ServiceIterator matching is a
	// case-insensitive SUBSTRING test -- so grip.hello settles it.
	const ARB_NAME = "RS_ShieldSaw";

	private Service arbiter()
	{
		if (mArb) return mArb;
		ServiceIterator it = ServiceIterator.Find("RS_GripArbiterService");
		Service sv;
		while (sv = it.Next())
		{
			if (sv.GetInt("grip.hello", "", 0, 0, null, 'None') == 1) { mArb = sv; return sv; }
		}
		return null;
	}

	// WHAT BLOCKS A DRAW IS SOMETHING ACTUALLY IN THE HAND, not merely a grip
	// that is down.
	//
	// RS_Hands claims the off hand the moment the squeeze registers -- possibly
	// on the same tic as our own press edge, and its handler may well run
	// first. Refusing on grip.held alone therefore refused EVERY draw as soon
	// as RS_VR_Unified was in the load order: the hand was always "held",
	// because the thing holding it was the very press we were reacting to.
	//
	// So ask what it is holding. A real subject -- a magazine, a shell, a
	// pouch, a foregrip, a gun's grip -- is a genuine conflict and stands the
	// shield down. GRIPSUBJ_None is a hand that is merely closed, which is
	// exactly the gesture.
	private bool offHandFree(PlayerPawn pmo)
	{
		let sv = arbiter();
		if (!sv) return true;                                    // alone: free
		if (sv.GetInt("grip.mine", "", 1, 0, pmo, ARB_NAME) == 1) return true;
		if (sv.GetInt("grip.held", "", 1, 0, pmo, ARB_NAME) == 0) return true;

		int subj = sv.GetInt("grip.subject", "", 1, 0, pmo, ARB_NAME);
		return subj == GRIPSUBJ_None;
	}

	private bool offHandMine(PlayerPawn pmo)
	{
		let sv = arbiter();
		if (!sv) return true;
		return sv.GetInt("grip.mine", "", 1, 0, pmo, ARB_NAME) == 1;
	}

	// A CLAIM IS A LEASE AND HAS TO BE RENEWED. The arbiter treats a claim
	// older than its lease as absent, and every sibling consumer re-asserts
	// every tic. Claiming once meant the hand read as free after two seconds
	// and another lane could take it while the shield was still in it.
	private void claimOffHand(PlayerPawn pmo, bool want)
	{
		let sv = arbiter();
		if (want)
		{
			if (sv) sv.GetInt("grip.claim", "", 1, GRIPSUBJ_Grip, pmo, ARB_NAME);
			pmo.GripClaimOff = GRIPSUBJ_Grip;
		}
		else
		{
			if (sv) sv.GetInt("grip.release", "", 1, 0, pmo, ARB_NAME);
			if (pmo.GripClaimOff == GRIPSUBJ_Grip) pmo.GripClaimOff = GRIPSUBJ_None;
		}
	}

	// IS THE OFF HAND AT THE SHOULDER MOUNT?
	//
	// This is what replaced "any grip press draws it". The old test fought
	// RS_Hands for every squeeze in the game; this one asks about a PLACE that
	// nothing else wants, so there is nothing to arbitrate over and the draw
	// cannot be triggered by picking up a health pack.
	static bool AtShoulder(PlayerPawn pmo, PlayerInfo p)
	{
		if (!RS_ShieldMount.Tracking(pmo)) return false;
		Vector3 a = RS_ShieldMount.AnchorPos(pmo,
			cvNum("rs_ss_mount_fwd",  p, -7.0),
			cvNum("rs_ss_mount_side", p, -8.0),
			cvNum("rs_ss_mount_frac", p,  0.86));
		double r = max(2.0, cvNum("rs_ss_mount_reach", p, 9.0));
		return Level.Vec3Diff(pmo.OffhandPos, a).Length() <= r;
	}

	// 0 = shoulder (default), 1 = forearm.
	static int MountMode(PlayerInfo p) { return cvInt("rs_ss_mount_mode", p, 0); }

	// THE FOREARM HAS NO PLACE TO REACH TO -- the shield already rides the
	// off hand wherever it is, so there is no distance to test. What used to
	// make "any grip draws it" unusable was never the lack of a place; it was
	// that grip.held alone could not tell a genuine empty-hand squeeze from
	// RS_Hands already holding a health pack. offHandFree() below is that
	// distinction, added after the forearm was pulled, and it is the one
	// thing that makes bringing it back safe: nothing here re-triggers the
	// original conflict.
	//
	// AT MOUNT, generalized over both modes -- one call site for the press
	// and release logic in pollLocalGrip() instead of a branch at every use.
	static bool AtMount(PlayerPawn pmo, PlayerInfo p)
	{
		return (MountMode(p) == 1) ? true : AtShoulder(pmo, p);
	}

	// THE MOTION HALF OF THE GESTURE. Whether the hand was MOVING at release is
	// what separates a throw from putting it back.
	//
	// OffhandVel is real now -- XrSpaceVelocity chained onto the same
	// xrLocateSpace call that already reads pose, all the way through
	// actor.h/actor.zs to here -- so this reads it instead of assuming every
	// release is a throw. It is map units PER SECOND, not per tic: the native
	// engine code scales the runtime's metres/second by vr_vunits_per_meter
	// and stops there, unlike pmo.Vel which is per tic. Do not compare the two
	// against the same threshold.
	static bool HandMoving(PlayerPawn pmo)
	{
		if (!pmo) return true;
		let p = pmo.player;
		double minSpeed = cvNum("rs_ss_throw_min", p, 25.0);
		return pmo.OffhandVel.Length() >= minSpeed;
	}

	int StateOf(int pnum)
	{
		if (pnum < 0 || pnum >= MAXPLAYERS) return SS_STOWED;
		return mState[pnum];
	}

	// ======================================================================
	// the draw
	// ======================================================================
	void Draw(int pnum)
	{
		if (pnum < 0 || pnum >= MAXPLAYERS || !playeringame[pnum]) return;
		let p = players[pnum];
		if (!p || !p.mo || p.mo.health <= 0) return;
		if (mState[pnum] != SS_STOWED) return;

		let saw = RS_ShieldSaw(p.mo.FindInventory("RS_ShieldSaw"));
		if (!saw || saw.flying) return;
		if (!offHandFree(p.mo)) return;

		// REMEMBER WHAT WAS THERE, as a class rather than a pointer: the
		// instance can be destroyed and recreated across a level change or a
		// morph, and a stale pointer would silently restore nothing.
		let cur = p.OffhandWeapon;
		mPrevOff[pnum]  = (cur && cur != saw) ? cur.GetClass() : null;

		// AND THE MAIN HAND, because BringUpWeapon nulls ReadyWeapon when
		// either weapon is two-handed -- and mPrevOff alone would never put it
		// back, leaving the main hand permanently empty.
		let rw = p.ReadyWeapon;
		mPrevMain[pnum] = (rw && rw != saw && (rw.bTwoHanded || saw.bTwoHanded))
		                  ? rw.GetClass() : null;

		saw.bOffhandWeapon = true;
		p.PendingWeapon = saw;
		p.mo.BringUpWeapon();

		mState[pnum] = SS_DRAWN;
		claimOffHand(p.mo, true);
		p.mo.A_StartSound("rsshield/raise", CHAN_OFFWEAPON);
		buzz(pnum, 0.7, 45.0);
	}

	// Put it back without throwing.
	void Stow(int pnum)
	{
		if (pnum < 0 || pnum >= MAXPLAYERS) return;
		if (mState[pnum] != SS_DRAWN) return;
		let p = players[pnum];
		if (p && p.mo)
		{
			// The grind's looping idle belongs to a state sequence we are about
			// to abandon. CHANF_LOOPING is LOOP|NOSTOP, so nothing restarts or
			// clears it and it would play for the rest of the level.
			p.mo.A_StopSound(CHAN_OFFWEAPON);
			claimOffHand(p.mo, false);
		}
		restorePrevious(pnum);
		mState[pnum] = SS_STOWED;
	}

	// ======================================================================
	// the throw
	// ======================================================================
	void Thrown(int pnum)
	{
		if (pnum < 0 || pnum >= MAXPLAYERS) return;
		mState[pnum] = SS_FLYING;
		let p = players[pnum];
		if (p && p.mo) { p.mo.A_StopSound(CHAN_OFFWEAPON); claimOffHand(p.mo, false); }
		restorePrevious(pnum);
	}

	// The launch failed -- the spawn point was inside geometry, or something
	// replaced the flight actor. Do not leave the sequence half-finished: the
	// release edge is already spent, so without this the shield sits in the
	// hand with no gesture able to reach it.
	void LaunchFailed(int pnum)
	{
		if (pnum < 0 || pnum >= MAXPLAYERS) return;
		mState[pnum] = SS_DRAWN;      // Stow() insists on DRAWN
		Stow(pnum);
	}

	void Landed(int pnum)
	{
		if (pnum < 0 || pnum >= MAXPLAYERS) return;
		mState[pnum] = SS_STOWED;
		let p = players[pnum];
		if (p && p.mo) p.mo.A_StartSound("rsshield/hit", CHAN_BODY);
		buzz(pnum, 0.6, 40.0);
	}

	private void restorePrevious(int pnum)
	{
		let p = players[pnum];
		if (!p || !p.mo) return;

		Class<Weapon> wantOff  = mPrevOff[pnum];
		Class<Weapon> wantMain = mPrevMain[pnum];
		mPrevOff[pnum]  = null;
		mPrevMain[pnum] = null;

		Weapon w = null;
		if (wantOff) w = Weapon(p.mo.FindInventory(wantOff));

		if (!w)
		{
			// NOTHING TO GO BACK TO -- either nothing was there, or the
			// remembered weapon was dropped, taken or morphed away while the
			// shield was out. Either way the shield must not stay in the hand:
			// this used to `return` and left it stuck there with the state
			// machine already moved on.
			if (p.OffhandWeapon is "RS_ShieldSaw")
			{
				p.SetPsprite(PSP_OFFHANDWEAPON, null);
				p.OffhandWeapon = null;
				p.mo.PickNewWeapon(null, 1);   // do not leave the hand empty
			}
		}
		else
		{
			w.bOffhandWeapon = true;
			p.PendingWeapon = w;
			p.mo.BringUpWeapon();
		}

		// The main hand, if the draw's BringUpWeapon dropped it.
		if (wantMain)
		{
			let m = Weapon(p.mo.FindInventory(wantMain));
			if (m && !p.ReadyWeapon)
			{
				m.bOffhandWeapon = false;
				p.PendingWeapon = m;
				p.mo.BringUpWeapon();
			}
		}
	}

	// ======================================================================
	// per-tic: reconcile, renew, draw the forearm model
	// ======================================================================

	override void WorldTick()
	{
		// INPUT FIRST, AND ONLY FOR THIS MACHINE'S OWN PLAYER. See the header.
		pollLocalGrip();

		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (!playeringame[i]) continue;
			let p = players[i];
			if (!p) continue;
			let pmo = p.mo;
			if (!pmo || pmo.health <= 0) { hide(i); continue; }

			let saw = RS_ShieldSaw(pmo.FindInventory("RS_ShieldSaw"));
			if (!saw) { hide(i); continue; }

			// KEEP THE STATE HONEST -- AND PUT IT BACK, don't just relabel.
			//
			// Draw() is the ONLY thing that legitimately puts the shield in
			// your hand, and it sets SS_DRAWN when it does. So a shield sitting
			// in the off hand while the state says STOWED was put there by
			// something else: the engine picking it for an empty off hand
			// (+WEAPON.OFFHANDWEAPON makes it a candidate), a level change
			// re-raising a serialized OffhandWeapon, or a pickup switch.
			//
			// Accepting that as "drawn" was wrong twice over: the forearm model
			// stayed up so there were two shields, and the psprite ran its Fire
			// states, so the thing ground away continuously off your arm
			// without you ever asking for it.
			//
			// STOWED is the resting state. Anything that arrives in the hand
			// unasked goes back to the forearm.
			if (mState[i] == SS_FLYING && !saw.flying) Landed(i);

			if (mState[i] != SS_DRAWN && !saw.flying && p.OffhandWeapon == saw)
				unstow(i, p, pmo, saw);

			if (mState[i] == SS_DRAWN && p.OffhandWeapon != saw && !saw.flying)
			{
				mState[i] = SS_STOWED;
				claimOffHand(pmo, false);
			}

			// RENEW THE LEASE while it is genuinely in the hand.
			if (mState[i] == SS_DRAWN) claimOffHand(pmo, true);

			bool wantModel = cvOn("rs_ss_stow", p, true)
			              && mState[i] == SS_STOWED
			              && !saw.flying;
			if (cvOn("rs_ss_stow_place", p, false)) wantModel = true;

			showMarker(i, p, pmo, saw);

			if (!wantModel) { hide(i); continue; }
			show(i, p, pmo);
		}
	}

	// TAKE IT OUT OF THE HAND IT WAS NEVER DRAWN INTO.
	//
	// Clearing OffhandWeapon alone would leave the hand empty, and the engine
	// would simply pick the shield again next tic -- it is off-hand capable and
	// may be the only thing that is. So hand the slot to something else if
	// there is anything else, and only then fall back to empty.
	private void unstow(int pnum, PlayerInfo p, PlayerPawn pmo, Weapon saw)
	{
		p.SetPsprite(PSP_OFFHANDWEAPON, null);
		p.OffhandWeapon = null;
		if (p.PendingWeapon == saw) p.PendingWeapon = WP_NOCHANGE;
		pmo.A_StopSound(CHAN_OFFWEAPON);
		claimOffHand(pmo, false);
		mState[pnum] = SS_STOWED;
	}

	// EDGES ARE DETECTED LOCALLY AND SENT. mGripWas is updated on every tic
	// whatever else happens -- gating the update behind the same conditions
	// that gate the action left it stale, so toggling the gesture cvar mid-grip
	// fired a phantom release and threw the shield with no input.
	private void pollLocalGrip()
	{
		let p = players[consoleplayer];
		if (!p || !p.mo) { mGripWas = false; return; }
		let pmo = p.mo;

		// A grip that never registers at all looks identical to a gate that
		// always refuses, so print the raw button too.
		if (cvOn("rs_ss_debug", p, false) && (level.time % 35) == 0)
		{
			int mode = MountMode(p);
			if (mode == 1)
			{
				Console.Printf("[SS] grip=%d state=%d mode=forearm free=%d atMount=%d",
					pmo.GripHeldOff, mState[consoleplayer],
					offHandFree(pmo), AtMount(pmo, p));
			}
			else
			{
				Vector3 a = RS_ShieldMount.AnchorPos(pmo,
					cvNum("rs_ss_mount_fwd",  p, -7.0),
					cvNum("rs_ss_mount_side", p, -8.0),
					cvNum("rs_ss_mount_frac", p,  0.86));
				Console.Printf("[SS] grip=%d state=%d mode=shoulder tracking=%d reach=%.1f atMount=%d",
					pmo.GripHeldOff, mState[consoleplayer],
					RS_ShieldMount.Tracking(pmo),
					Level.Vec3Diff(pmo.OffhandPos, a).Length(),
					AtMount(pmo, p));
			}
		}

		bool grip = pmo.GripHeldOff;
		bool was  = mGripWas;
		mGripWas  = grip;

		if (!cvOn("rs_ss_gesture", p, true)) return;
		if (pmo.health <= 0) return;
		if (!pmo.FindInventory("RS_ShieldSaw")) return;

		int st = mState[consoleplayer];

		bool dbg = cvOn("rs_ss_debug", p, false);
		if (dbg && (grip != was))
		{
			let sv = arbiter();
			int held = sv ? sv.GetInt("grip.held", "", 1, 0, pmo, ARB_NAME) : -1;
			int subj = sv ? sv.GetInt("grip.subject", "", 1, 0, pmo, ARB_NAME) : -1;
			int mine = sv ? sv.GetInt("grip.mine", "", 1, 0, pmo, ARB_NAME) : -1;
			Console.Printf("[SS] grip %s | state %d | arbiter %s held=%d subj=%d mine=%d | free=%d",
				grip ? "DOWN" : "UP", st, sv ? "yes" : "none",
				held, subj, mine, offHandFree(pmo));
		}

		mAtShoulder = AtMount(pmo, p);

		if (grip && !was)                       // pressed
		{
			// REACHING FOR IT is the draw. A squeeze anywhere else is somebody
			// else's business and we do not touch it.
			if (st == SS_STOWED && mAtShoulder && offHandFree(pmo))
				SendNetworkEvent("rs-ss-draw");
			else if (st == SS_FLYING && mAtShoulder)
				SendNetworkEvent("rs-ss-recall");
			else if (dbg)
				Console.Printf("[SS] press ignored: state %d shoulder %d free %d",
					st, mAtShoulder, offHandFree(pmo));
		}
		else if (!grip && was)                  // released
		{
			// ONLY IF WE OWN THE HAND. Without this, drawing with the bound key
			// and then gripping anything at all -- a barrel, the pouch, a
			// foregrip -- launched the shield the moment you let go.
			if (st == SS_DRAWN && offHandMine(pmo))
			{
				// PUT IT BACK where you got it: releasing at the shoulder
				// re-holsters instead of throwing. Everywhere else, a release
				// is a throw.
				//
				// FOREARM HAS NO "WHERE YOU GOT IT" DISTINCT FROM EVERYWHERE
				// ELSE -- mAtShoulder (AtMount) is unconditionally true there,
				// on purpose, for the press side of this gesture. Using it
				// here too would mean every release re-holsters and the
				// forearm option could never throw at all. Wrist speed alone
				// decides it in that mode.
				bool atRestSpot = (MountMode(p) == 1) ? false : mAtShoulder;
				if (atRestSpot)           SendNetworkEvent("rs-ss-stow");
				else if (HandMoving(pmo)) SendNetworkEvent("rs-ss-throw");
				else                      SendNetworkEvent("rs-ss-stow");
			}
		}
	}

	private void ThrowNow(int pnum)
	{
		let p = players[pnum];
		if (!p || !p.mo) return;
		let saw = RS_ShieldSaw(p.mo.FindInventory("RS_ShieldSaw"));
		if (!saw || saw.flying) { Stow(pnum); return; }
		saw.LaunchNow();
	}

	private void RecallNow(int pnum)
	{
		let p = players[pnum];
		if (!p || !p.mo) return;
		let saw = RS_ShieldSaw(p.mo.FindInventory("RS_ShieldSaw"));
		if (!saw) return;
		let f = RS_ShieldInFlight(saw.flying);
		if (f) f.GoHome();
	}

	override void NetworkProcess(ConsoleEvent e)
	{
		if (e.Name ~== "rs-ss-draw")        Draw(e.Player);
		else if (e.Name ~== "rs-ss-throw")  ThrowNow(e.Player);
		else if (e.Name ~== "rs-ss-stow")   Stow(e.Player);
		else if (e.Name ~== "rs-ss-recall") RecallNow(e.Player);
		else if (e.Name ~== "rs-ss-toggle")
		{
			// The bound key. Same transitions as the gesture, so the two paths
			// can never leave different state behind.
			int st = StateOf(e.Player);
			if (st == SS_DRAWN)       Stow(e.Player);
			else if (st == SS_FLYING) RecallNow(e.Player);
			else                      Draw(e.Player);
		}
	}

	// ======================================================================
	// the forearm model
	// ======================================================================

	// THE SHIELD ON YOUR BACK OR YOUR FOREARM, depending on rs_ss_mount_mode.
	// Only one of the two props ever exists at a time -- switching the cvar
	// mid-game tears down whichever one was up.
	private void show(int pnum, PlayerInfo p, PlayerPawn pmo)
	{
		if (!RS_ShieldMount.Tracking(pmo)) { hide(pnum); return; }

		if (MountMode(p) == 1) { showForearm(pnum, p, pmo); return; }
		showShoulder(pnum, p, pmo);
	}

	// A world actor, because a psprite is drawn in a HAND's frame and there is
	// no hand at your shoulder blade -- the same reason every RS_Holsters
	// anchor is a world actor. Placed by script every tic; fine at 35Hz for
	// something on your back that you never look straight at.
	private void showShoulder(int pnum, PlayerInfo p, PlayerPawn pmo)
	{
		if (mForearmProp[pnum]) { mForearmProp[pnum].Destroy(); mForearmProp[pnum] = null; }

		if (!mStowProp[pnum])
		{
			mStowProp[pnum] = Actor.Spawn("RS_ShieldStowActor", pmo.pos);
			if (!mStowProp[pnum]) return;
			mStowProp[pnum].master = pmo;
		}

		Vector3 a = RS_ShieldMount.AnchorPos(pmo,
			cvNum("rs_ss_mount_fwd",  p, -7.0),
			cvNum("rs_ss_mount_side", p, -8.0),
			cvNum("rs_ss_mount_frac", p,  0.86));

		// THE ANCHOR IS THE SHIELD'S TOP EDGE. What you reach for is the rim;
		// the disc hangs below it. Anchoring by the centre instead parked a
		// full-size shield squarely behind your head.
		a.z -= cvNum("rs_ss_mount_drop", p, 11.0);

		mStowProp[pnum].SetOrigin(a, true);
		mStowProp[pnum].A_SetAngle(pmo.angle + cvNum("rs_ss_mount_yaw", p, 0.0), SPF_INTERPOLATE);
		mStowProp[pnum].pitch = cvNum("rs_ss_mount_pitch", p, 0.0);
		mStowProp[pnum].roll  = cvNum("rs_ss_mount_roll",  p, 0.0);
		mStowProp[pnum].A_SetScale(cvNum("rs_ss_mount_scale", p, 1.0));
	}

	// FollowOffHand does the actual placement at draw rate; this only has to
	// keep the ACTOR somewhere sensible (culling, sound origin, Distance
	// checks) between the renderer's own reads of the hand transform. Local
	// offset and rotation within that frame are rs_ss_stow_ofs_* /
	// rs_ss_stow_yaw/pitch/roll/scale, read live by MODELDEF's PlacementCVars
	// -- nothing here writes them.
	private void showForearm(int pnum, PlayerInfo p, PlayerPawn pmo)
	{
		if (mStowProp[pnum]) { mStowProp[pnum].Destroy(); mStowProp[pnum] = null; }

		if (!mForearmProp[pnum])
		{
			mForearmProp[pnum] = Actor.Spawn("RS_ShieldForearmActor", pmo.OffhandPos, NO_REPLACE);
			if (!mForearmProp[pnum]) return;
			mForearmProp[pnum].master = pmo;
		}
		mForearmProp[pnum].SetOrigin(pmo.OffhandPos, true);
	}

	private void hide(int pnum)
	{
		if (mStowProp[pnum])    { mStowProp[pnum].Destroy();    mStowProp[pnum]    = null; }
		if (mForearmProp[pnum]) { mForearmProp[pnum].Destroy(); mForearmProp[pnum] = null; }
	}

	// THE DIAMOND. Shown whenever the mount is reachable, which deliberately
	// includes the times the shield is NOT on your back -- if the marker
	// vanished the moment you drew, you would have nothing to aim at to put it
	// away again, which is the exact moment you most need to see it.
	//
	// Three states, and the brightening is the whole point: it is the only
	// feedback that tells you the reach radius is right without reading a debug
	// print. Dim = there. Bright = your hand is close enough to take it.
	private void showMarker(int pnum, PlayerInfo p, PlayerPawn pmo, Actor saw)
	{
		int mode = cvInt("rs_ss_marker", p, 1);   // 0 never, 1 auto, 2 always
		bool want = RS_ShieldMount.Tracking(pmo) && mode > 0 && saw != null;

		// AUTO means "while it matters": on your back waiting to be taken, or
		// in your hand waiting to be put back. Not while it is in flight --
		// there is nothing to reach for.
		if (mode == 1 && mState[pnum] == SS_FLYING) want = false;

		// NOTHING TO AIM AT IN FOREARM MODE. The shield already rides the off
		// hand wherever it is; a diamond pinned to a computed shoulder point
		// would just be wrong, not merely unnecessary.
		if (MountMode(p) == 1) want = false;

		if (!want)
		{
			if (mMarker[pnum]) { mMarker[pnum].Destroy(); mMarker[pnum] = null; }
			return;
		}

		if (!mMarker[pnum])
		{
			mMarker[pnum] = Actor.Spawn("RS_ShieldMountMarker", pmo.pos);
			if (!mMarker[pnum]) return;
			mMarker[pnum].master = pmo;
		}

		Vector3 a = RS_ShieldMount.AnchorPos(pmo,
			cvNum("rs_ss_mount_fwd",  p, -7.0),
			cvNum("rs_ss_mount_side", p, -8.0),
			cvNum("rs_ss_mount_frac", p,  0.86));
		mMarker[pnum].SetOrigin(a, true);

		// Sized to the reach radius, so the diamond IS the catch volume rather
		// than a decoration sitting near it. Move the reach slider and the
		// thing you are aiming at changes with it.
		double reach = max(2.0, cvNum("rs_ss_mount_reach", p, 9.0));
		mMarker[pnum].A_SetScale(reach * 0.25);

		bool near = (pnum == consoleplayer) && mAtShoulder;
		mMarker[pnum].A_SetRenderStyle(near ? 0.85 : 0.30, STYLE_Add);
	}

	private static int cvInt(string n, PlayerInfo p, int fb)
	{ let c = CVar.GetCVar(n, p); return c ? c.GetInt() : fb; }

	// ======================================================================
	// lifecycle
	// ======================================================================

	private void grant(int pnum)
	{
		let p = players[pnum];
		if (!p || !p.mo) return;
		let pmo = p.mo;

		mState[pnum]    = SS_STOWED;
		mPrevOff[pnum]  = null;
		mPrevMain[pnum] = null;

		if (!cvOn("rs_ss_start", p, true)) return;
		if (pmo.FindInventory("RS_ShieldSaw")) return;

		pmo.GiveInventory("RS_ShieldSaw", 1);

		// REBUILD THE SLOT TABLE. It is assembled during player setup, which
		// runs before this grant -- so without it the weapon lands in inventory
		// and in no slot at all, and no key can reach it.
		WeaponSlots.SetupWeaponSlots(pmo);

		// AttachToOwner sets PendingWeapon on a give unless the weapon carries
		// +WEAPON.NO_AUTO_SWITCH, which it now does. Belt and braces anyway:
		// an auto-equip here would put the shield in the hand while mState
		// still said STOWED, drawing it twice and losing the off-hand weapon.
		if (!cvOn("rs_ss_equip", p, false))
		{
			let saw = Weapon(pmo.FindInventory("RS_ShieldSaw"));
			if (saw && p.PendingWeapon == saw) p.PendingWeapon = WP_NOCHANGE;
		}
		else
		{
			Draw(pnum);
		}
	}

	override void PlayerSpawned(PlayerEvent e)   { grant(e.PlayerNumber); }

	// PST_REBORN fires PlayerRespawned, NOT PlayerSpawned, and G_PlayerReborn
	// has already run DestroyAllInventory -- so without this a coop respawn
	// leaves the player with no shield and no way to get one.
	override void PlayerRespawned(PlayerEvent e) { grant(e.PlayerNumber); }

	override void PlayerDied(PlayerEvent e)
	{
		int n = e.PlayerNumber;
		let p = players[n];
		if (p && p.mo) claimOffHand(p.mo, false);   // do not leak the lease
		mState[n]    = SS_STOWED;
		mPrevOff[n]  = null;
		mPrevMain[n] = null;
		hide(n);
		if (mMarker[n]) { mMarker[n].Destroy(); mMarker[n] = null; }
	}

	override void WorldUnloaded(WorldEvent e)
	{
		mArb = null;
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			hide(i);
			if (mMarker[i]) { mMarker[i].Destroy(); mMarker[i] = null; }
		}
	}
}
