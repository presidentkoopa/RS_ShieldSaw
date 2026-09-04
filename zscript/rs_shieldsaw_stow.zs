// THE SHIELD ON YOUR FOREARM WHEN IT IS NOT IN YOUR HAND.
//
// This is not a second feature. It is the shield saw's OTHER STATE: hold it and
// it is a weapon, put it away and it straps to your off forearm and keeps
// deflecting. Switching weapons should not make a shield vanish into a pocket.
//
// HOW IT IS DRAWN. A psprite layer of its own, with the model bound through
// MODELDEF's UseHandOffsets so it is placed in the OFF HAND's frame and rides
// the controller at render rate. A world actor tracking OffhandPos would only
// update at 35Hz and would swim visibly against your own arm.
//
// PLACEMENT IS LIVE, through rs_ss_stow_* below, because where a buckler sits
// on a forearm is a headset question and nobody gets it right from a number.
// Turn rs_ss_stow_place on to keep it visible while you move it.

class RS_ShieldStowProp : Inventory
{
	Default
	{
		Inventory.MaxAmount 1;
		Inventory.InterHubAmount 1;
		+INVENTORY.UNDROPPABLE
		+INVENTORY.UNTOSSABLE
		+INVENTORY.QUIET
		// REQUIRED. With a TNT1 Spawn state there is no FrameIndex for the
		// model lookup to hit, so the psprite has to resolve its model through
		// BaseSpriteModelFrames (MODELDEF BaseFrame) -- a path the engine only
		// consults for a decoupled actor. Without this the layer silently draws
		// nothing at all.
		+DECOUPLEDANIMATIONS
	}
	States
	{
	Spawn:
		TNT1 A -1;
		Stop;
	}
}

class RS_ShieldStowHandler : EventHandler
{
	// Above the off-hand weapon's own layer so it draws after it.
	const LAYER_STOW = 1900050;

	// PER PLAYER, not one flag. WorldTick is playsim and runs identically on
	// every peer; a single shared flag desyncs the moment two players own one.
	private bool up[MAXPLAYERS];

	private static double cvNum(string n, PlayerInfo p, double fb)
	{ let c = CVar.GetCVar(n, p); return c ? c.GetFloat() : fb; }
	private static bool cvOn(string n, PlayerInfo p, bool fb)
	{ let c = CVar.GetCVar(n, p); return c ? c.GetBool() : fb; }

	// EVERY PLAYER, keyed by index. This used to read players[consoleplayer]
	// and then call GiveInventory on it -- a playsim mutation keyed on a
	// client-local index, which hands the prop to a different pawn on every
	// peer. Single player never noticed because consoleplayer is 0.
	override void WorldTick()
	{
		for (int i = 0; i < MAXPLAYERS; i++)
		{
			if (!playeringame[i]) continue;
			let p = players[i];
			if (!p) continue;
			let pmo = p.mo;
			if (!pmo || pmo.health <= 0) { hide(i); continue; }

			if (!cvOn("rs_ss_stow", p, true)) { hide(i); continue; }

			let saw = RS_ShieldSaw(pmo.FindInventory("RS_ShieldSaw"));

			// Nothing to stow if you do not own it, or it is out being thrown.
			if (!saw || saw.flying) { hide(i); continue; }

			// In your hand? Then it is not stowed. The placement override keeps
			// it up so it can be positioned without putting it away first.
			bool held = (p.ReadyWeapon == saw || p.OffhandWeapon == saw);
			if (held && !cvOn("rs_ss_stow_place", p, false)) { hide(i); continue; }

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

		// PLACEMENT IS NOT DONE HERE. MODELDEF declares `PlacementCVars
		// rs_ss_stow` and the renderer reads rs_ss_stow_ofs_* / _yaw / _pitch /
		// _roll / _scale by name every frame (models.cpp GetPlacementCVar).
		// Writing psp.x/psp.y would do nothing -- they are not consulted on the
		// model path at all, and AnchorOfs only applies to a layer anchored to
		// another layer's bone, which this is not.
		up[pnum] = true;
	}

	private void hide(int pnum)
	{
		if (!up[pnum]) return;
		let p = players[pnum];
		if (p)
		{
			let psp = p.FindPSprite(LAYER_STOW);
			if (psp) psp.SetState(null);
		}
		up[pnum] = false;
	}

	override void WorldUnloaded(WorldEvent e)
	{
		for (int i = 0; i < MAXPLAYERS; i++) hide(i);
	}

	// START WITH IT. Granted on spawn rather than through a Player.StartItem on
	// a player class, because a player class replacement is the one thing in a
	// weapon mod that is guaranteed to fight every other mod in the load order.
	// Same route RS_Grenade takes, and for the same reason.
	override void PlayerSpawned(PlayerEvent e)
	{
		let p = players[e.PlayerNumber];
		if (!p) return;
		let pmo = p.mo;
		if (!pmo) return;


		if (cvOn("rs_ss_start", p, true) && !pmo.FindInventory("RS_ShieldSaw"))
			pmo.GiveInventory("RS_ShieldSaw", 1);

	}
}
