// THE SHIELD'S THREE STATES, AND THE LOADOUT SWAP BETWEEN THEM.
//
//   STOWED   on the off forearm, deflecting. The resting state.
//   DRAWN    in the off hand. Whatever off-hand weapon you were holding has
//            been set aside and comes back the moment you throw.
//   FLYING   thrown. Your previous weapon is ALREADY back -- you are never
//            weaponless during the flight -- and the shield returns to the
//            forearm, not to your hand.
//
// THE SHIELD IS AN INTERRUPT, NOT A WEAPON SLOT. That is the whole shape of
// it: you break out of your loadout for one grind-and-throw and then you are
// back where you were. Nothing here should ever leave you holding nothing.
//
// THE DRAW TRIGGER IS DELIBERATELY A SEAM. It wants to be an arm gesture --
// momentum, pulling the shield off your own forearm -- and that needs hand
// velocity from the engine, which is not available yet. Everything downstream
// of the trigger is built; `Draw()` is called from one place and swapping a
// bound key for a gesture predicate is a one-line change at that call site.

class RS_ShieldState : EventHandler
{
	// Above the off-hand weapon's own layer so it draws after it.
	const LAYER_STOW = 1900050;

	enum EShieldState
	{
		SS_STOWED = 0,
		SS_DRAWN,
		SS_FLYING,
	}

	private int   mState[MAXPLAYERS];
	private bool  mLayerUp[MAXPLAYERS];
	private bool  mGripWas[MAXPLAYERS];      // last tic's raw squeeze
	// The off-hand weapon that was displaced by the draw, restored on throw.
	private Class<Weapon> mPrevOff[MAXPLAYERS];

	private static double cvNum(string n, PlayerInfo p, double fb)
	{ let c = CVar.GetCVar(n, p); return c ? c.GetFloat() : fb; }
	private static bool cvOn(string n, PlayerInfo p, bool fb)
	{ let c = CVar.GetCVar(n, p); return c ? c.GetBool() : fb; }

	static RS_ShieldState Get() { return RS_ShieldState(EventHandler.Find("RS_ShieldState")); }

	// THE MOTION HALF OF THE GESTURE, AND THE ONE THING STILL STUBBED.
	//
	// The grip half is native -- GripHeldOff is the raw squeeze, engine-owned,
	// arbiter-independent, and deliberately NOT GripContextOff, which latches
	// to GRIPCTX_Object the moment anything claims the hand and then reads as
	// held forever so a release edge can never be seen.
	//
	// Whether the hand was MOVING at the moment of release is what separates a
	// throw from putting it back, and that needs hand velocity the engine does
	// not publish yet. Until it does this answers "yes" -- so a release throws.
	// One function, one call site each; when AttackVel/OffhandVel land this
	// becomes a threshold test and nothing else changes.
	static bool HandMoving(PlayerPawn pmo)
	{
		return true;   // TODO: |OffhandVel| > rs_ss_throw_min once published
	}

	int StateOf(int pnum)
	{
		if (pnum < 0 || pnum >= MAXPLAYERS) return SS_STOWED;
		return mState[pnum];
	}

	// ======================================================================
	// the draw
	// ======================================================================
	//
	// Called from NetworkProcess today. When the engine can report hand
	// velocity this is where a gesture predicate goes instead -- nothing below
	// this function cares which one called it.
	void Draw(int pnum)
	{
		if (pnum < 0 || pnum >= MAXPLAYERS) return;
		if (!playeringame[pnum]) return;
		let p = players[pnum];
		if (!p || !p.mo || p.mo.health <= 0) return;
		if (mState[pnum] != SS_STOWED) return;

		let saw = RS_ShieldSaw(p.mo.FindInventory("RS_ShieldSaw"));
		if (!saw || saw.flying) return;

		// REMEMBER WHAT WAS THERE. Stored as a class rather than a pointer:
		// the instance can be destroyed and recreated across a level change or
		// a morph, and a stale pointer would silently restore nothing.
		let cur = p.OffhandWeapon;
		mPrevOff[pnum] = (cur && cur != saw) ? cur.GetClass() : null;

		saw.bOffhandWeapon = true;
		p.PendingWeapon = saw;
		p.mo.BringUpWeapon();

		mState[pnum] = SS_DRAWN;
		p.mo.A_StartSound("rsshield/raise", CHAN_OFFWEAPON);
		level.VRHaptic(1, 0.7, 45.0);
	}

	// Put it back without throwing -- the draw key pressed again.
	void Stow(int pnum)
	{
		if (pnum < 0 || pnum >= MAXPLAYERS) return;
		if (mState[pnum] != SS_DRAWN) return;
		restorePrevious(pnum);
		mState[pnum] = SS_STOWED;
	}

	// ======================================================================
	// the throw
	// ======================================================================
	//
	// Called by the weapon the instant the shield leaves the hand. Your
	// previous weapon comes back NOW, not when the shield lands -- being
	// weaponless for the length of a flight is the thing this avoids.
	void Thrown(int pnum)
	{
		if (pnum < 0 || pnum >= MAXPLAYERS) return;
		mState[pnum] = SS_FLYING;
		restorePrevious(pnum);
	}

	// The shield finished its route and came home to the forearm.
	void Landed(int pnum)
	{
		if (pnum < 0 || pnum >= MAXPLAYERS) return;
		mState[pnum] = SS_STOWED;
		let p = players[pnum];
		if (p && p.mo)
		{
			p.mo.A_StartSound("rsshield/hit", CHAN_BODY);
			level.VRHaptic(1, 0.6, 40.0);
		}
	}

	private void restorePrevious(int pnum)
	{
		let p = players[pnum];
		if (!p || !p.mo) return;

		Class<Weapon> want = mPrevOff[pnum];
		mPrevOff[pnum] = null;

		if (!want)
		{
			// Nothing was there. Clear the off hand rather than leaving the
			// shield raised in it.
			if (p.OffhandWeapon is "RS_ShieldSaw")
			{
				p.SetPsprite(PSP_OFFHANDWEAPON, null);
				p.OffhandWeapon = null;
			}
			return;
		}

		let w = Weapon(p.mo.FindInventory(want));
		if (!w) return;
		w.bOffhandWeapon = true;
		p.PendingWeapon = w;
		p.mo.BringUpWeapon();
	}

	// ======================================================================
	// the forearm model
	// ======================================================================

	override void WorldTick()
	{
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (!playeringame[i]) continue;
			let p = players[i];
			if (!p) continue;
			let pmo = p.mo;
			if (!pmo || pmo.health <= 0) { hide(i); continue; }

			let saw = RS_ShieldSaw(pmo.FindInventory("RS_ShieldSaw"));
			if (!saw) { hide(i); continue; }

			// Keep the state honest against reality: if the shield is not in
			// flight and not in the hand, it is on the arm, whatever we think.
			if (mState[i] == SS_FLYING && !saw.flying) { Landed(i); }
			if (mState[i] == SS_DRAWN && p.OffhandWeapon != saw && !saw.flying)
				mState[i] = SS_STOWED;

			bool wantModel = cvOn("rs_ss_stow", p, true)
			              && mState[i] == SS_STOWED
			              && !saw.flying;

			// Placement override: keep it drawn whatever the state, so the
			// sliders can be set without cycling through the sequence.
			if (cvOn("rs_ss_stow_place", p, false)) wantModel = true;

			if (cvOn("rs_ss_gesture", p, true)) pollGrip(i, p, pmo);

			if (!wantModel) { hide(i); continue; }
			show(i, p, pmo);
		}
	}

	private void show(int pnum, PlayerInfo p, PlayerPawn pmo)
	{
		let it = pmo.FindInventory("RS_ShieldStowProp");
		if (!it)
		{
			pmo.GiveInventory("RS_ShieldStowProp", 1);
			it = pmo.FindInventory("RS_ShieldStowProp");
			if (!it) return;
		}

		let psp = p.FindPSprite(LAYER_STOW);
		if (!psp || psp.Caller != it)
		{
			State st = it.FindState("Spawn");
			if (!st) return;
			p.SetPsprite(LAYER_STOW, st, false, it);
			psp = p.FindPSprite(LAYER_STOW);
			if (!psp) return;
		}
		psp.alpha = 1.0;

		// Placement is MODELDEF's PlacementCVars (rs_ss_stow_*), read live by
		// the renderer. Nothing to write here.
		mLayerUp[pnum] = true;
	}

	private void hide(int pnum)
	{
		if (!mLayerUp[pnum]) return;
		let p = players[pnum];
		if (p)
		{
			let psp = p.FindPSprite(LAYER_STOW);
			if (psp) psp.SetState(null);
		}
		mLayerUp[pnum] = false;
	}

	// ======================================================================
	// lifecycle
	// ======================================================================

	override void PlayerSpawned(PlayerEvent e)
	{
		let p = players[e.PlayerNumber];
		if (!p || !p.mo) return;
		let pmo = p.mo;

		mState[e.PlayerNumber] = SS_STOWED;
		mPrevOff[e.PlayerNumber] = null;

		if (!cvOn("rs_ss_start", p, true)) return;
		if (pmo.FindInventory("RS_ShieldSaw")) return;

		pmo.GiveInventory("RS_ShieldSaw", 1);

		// REBUILD THE SLOT TABLE. It is assembled during player setup, which
		// runs before this grant -- so without it the weapon lands in inventory
		// and in no slot at all, and no key can reach it.
		WeaponSlots.SetupWeaponSlots(pmo);

		// Drawn on spawn, if asked. Otherwise it starts on the forearm, which
		// is the resting state and the one the sequence begins from.
		if (cvOn("rs_ss_equip", p, false)) Draw(e.PlayerNumber);
	}

	override void PlayerDied(PlayerEvent e)
	{
		mState[e.PlayerNumber] = SS_STOWED;
		mPrevOff[e.PlayerNumber] = null;
		hide(e.PlayerNumber);
	}

	override void WorldUnloaded(WorldEvent e)
	{
		for (int i = 0; i < MAXPLAYERS; i++) hide(i);
	}

	// THE GRIP DRIVES THE WHOLE SEQUENCE.
	//
	//   grip pressed  while stowed  -> draw it into the hand
	//   grip HELD                   -> it stays in the hand
	//   grip released while drawn   -> throw it if the hand was moving,
	//                                  otherwise put it back on the forearm
	//
	// Holding the grip is what keeps it in your hand, so letting go is always
	// the end of the sequence one way or the other. There is no way to be left
	// holding it by accident.
	private void pollGrip(int pnum, PlayerInfo p, PlayerPawn pmo)
	{
		bool grip = pmo.GripHeldOff;
		bool was  = mGripWas[pnum];
		mGripWas[pnum] = grip;

		if (grip && !was)                       // pressed
		{
			if (mState[pnum] == SS_STOWED) Draw(pnum);
		}
		else if (!grip && was)                  // released
		{
			if (mState[pnum] == SS_DRAWN)
			{
				if (HandMoving(pmo)) ThrowNow(pnum);
				else Stow(pnum);
			}
		}
	}

	// Release with motion. The weapon owns the actual launch, because it holds
	// the locks; this is the state machine asking it to go.
	private void ThrowNow(int pnum)
	{
		let p = players[pnum];
		if (!p || !p.mo) return;
		let saw = RS_ShieldSaw(p.mo.FindInventory("RS_ShieldSaw"));
		if (!saw || saw.flying) { Stow(pnum); return; }
		saw.LaunchNow();
	}

	// The key binding stays as well as the gesture. A gesture should not be
	// the only way to reach a weapon.
	override void NetworkProcess(ConsoleEvent e)
	{
		if (e.Name ~== "rs-ss-draw")
		{
			if (StateOf(e.Player) == SS_DRAWN) Stow(e.Player);
			else Draw(e.Player);
		}
	}
}

// The layer's caller. Inert -- it exists so the psprite has something to hang
// a model off.
//
// +DECOUPLEDANIMATIONS IS REQUIRED: with a TNT1 Spawn state there is no
// FrameIndex for the model lookup to hit, so the psprite resolves its model
// through BaseSpriteModelFrames (MODELDEF BaseFrame), a path the engine only
// consults for a decoupled actor. Without it the layer silently draws nothing.
class RS_ShieldStowProp : Inventory
{
	Default
	{
		Inventory.MaxAmount 1;
		Inventory.InterHubAmount 1;
		+INVENTORY.UNDROPPABLE
		+INVENTORY.UNTOSSABLE
		+INVENTORY.QUIET
		+DECOUPLEDANIMATIONS
	}
	States
	{
	Spawn:
		TNT1 A -1;
		Stop;
	}
}
