// ============================================================================
// THE SHIELD SAW AS A THING IN THE ROOM.
//
// It was a player sprite: drawn after the world is finished, glued to your
// view. That slot cannot be occluded by a doorframe, cannot take room light,
// and cannot be seen by another player -- and the last one is why this matters.
// A shield is a thing you hold up between yourself and something else, and half
// the point of holding it up is that the other party can see it.
//
// ------------------------------------------------------------ WHAT CHANGED
//
// The weapon keeps its states, its slot, its ammo and its whole state machine.
// What moves is only where it is DRAWN: a world actor per hand riding the
// controller's frame, instead of a psprite. The weapon then drives that actor's
// frame exactly as it used to drive its own sprite letter.
//
// THE HAND MESH IS GONE, DELIBERATELY. The old MODELDEF carried hand.md3 as
// model 2 and a second sprite handle (SSNH) to turn it off, because a psprite
// had to draw its own hand or there was none. RS_WorldHands draws both hands
// now, always, for every weapon -- so a weapon shipping a hand of its own is a
// second hand in the same place.
//
// ------------------------------------------------------------- THE BLADE
//
// Sixteen teeth, saw_blade.002 through .017, each 166 verts, each animated
// through frames 0 to 7. The artist baked the orbit and it is correct.
//
// Left as frames rather than rebuilt on the new quaternion surface hook, for a
// reason worth recording: driving sixteen teeth through SetModelSurfaceOffset
// would need sixteen of the sixteen available surface slots, leaving none for
// the shield -- and it would be reproducing an orbit that is already right. The
// hook earns its place on parts nobody animated; this is not one.
// ============================================================================

// ---- THE PROP ---------------------------------------------------------------
//
// One per hand. NOINTERACTION because it is a drawing: the weapon it belongs to
// is what exists in the playsim, and a prop that could be shot or walked into
// would be a second body in the same place.
class RS_ShieldSawProp : Actor
{
	Default
	{
		+NOGRAVITY; +NOBLOCKMAP; +NOINTERACTION; +DONTSPLASH;
		+NOTONAUTOMAP;
		Radius 1; Height 1;
		RenderStyle "Normal";
	}

	States
	{
	Spawn:
		SSNH A -1;
		Stop;
	}
}

class RS_ShieldSawPropOff : RS_ShieldSawProp {}


// ---- WHAT DRAWS IT ----------------------------------------------------------
//
// Spawns a prop for whichever hand holds the shield, keeps it on that
// controller, and copies the weapon's animation frame onto it. Destroys it the
// moment the weapon is not in a hand -- a prop outliving its weapon is a shield
// floating where you last held one.
class RS_ShieldSawWorld : EventHandler
{
	private Actor prop[2];
	private bool  warned;

	static RS_ShieldSawWorld Get() { return RS_ShieldSawWorld(EventHandler.Find("RS_ShieldSawWorld")); }

	override void WorldTick()
	{
		let p = players[consoleplayer];
		if (!p || !p.mo) return;
		let pmo = PlayerPawn(p.mo);
		if (!pmo) return;

		for (int h = 0; h < 2; ++h)
		{
			let w = (h == 0) ? p.ReadyWeapon : p.OffhandWeapon;
			bool want = w && (w is 'RS_ShieldSaw') && Flag("rs_ss_world", true);

			if (!want)
			{
				if (prop[h]) { prop[h].Destroy(); prop[h] = null; }
				continue;
			}

			if (!prop[h])
			{
				String cls = (h == 0) ? "RS_ShieldSawProp" : "RS_ShieldSawPropOff";
				prop[h] = Actor.Spawn(cls, pmo.Pos, NO_REPLACE);
				if (!prop[h])
				{
					if (!warned)
					{
						warned = true;
						Console.Printf("\c[Red]RS_ShieldSaw: could not spawn the world prop");
					}
					continue;
				}
			}

			// THE PLAYSIM POSITION IS THE HAND, and the DRAWN position is the
			// controller frame -- see the MODELDEF's FollowMainHand. Both,
			// because the renderer needs the frame and everything else in the
			// game needs the actor to be somewhere sensible: culling, sound
			// origins, and anything that asks how far away it is.
			prop[h].SetOrigin((h == 0) ? pmo.AttackPos : pmo.OffhandPos, true);

			// THE WEAPON'S OWN ANIMATION, COPIED ACROSS.
			//
			// The state machine that opens the shield and spins the blade is
			// unchanged and still lives on the weapon -- it just used to drive a
			// psprite's sprite frame and now drives this. Read off the weapon's
			// current state rather than duplicated, so the deploy, the grind
			// loop and the stow stay in one place.
			let psp = p.FindPSprite(
				(h == 0) ? PSP_WEAPON : PSP_OFFHANDWEAPON);
			if (psp && psp.CurState)
			{
				// THE FRAME ONLY. An earlier version called SetStateLabel here
				// first, which resets the frame to the state's own -- so it
				// undid the assignment on the very next line, every tic, and the
				// shield never left frame A.
				prop[h].frame = psp.CurState.frame;
			}
		}
	}

	override void WorldUnloaded(WorldEvent e)
	{
		// The level is going. Props are per-level actors and would otherwise be
		// reported as leaked by anything counting thinkers at the transition.
		for (int h = 0; h < 2; ++h)
			if (prop[h]) { prop[h].Destroy(); prop[h] = null; }
	}

	private static bool Flag(String n, bool d)
	{
		let c = CVar.GetCVar(n, players[consoleplayer]);
		return c ? c.GetBool() : d;
	}
}
