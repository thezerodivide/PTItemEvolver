# PTItemEvolver

PTItemEvolver is a MacroQuest Lua script built specifically for Project Triune.

It helps safely queue eligible items for evolution from Base to Enchanted or Legendary while handling item movement, restoration, queue order, progress tracking, estimated completion time, and Triune AutoCombat coordination.

## Features

- Scans worn items and bag/inventory items
- Separate tabs for Worn Items, Bag Items, and All Items
- Add eligible items directly to an evolution queue
- Choose Enchanted or Legendary as the target tier
- Reorder queued items
- Remove future queue entries
- Change future queue targets while another item is active
- Keeps the active queue row protected from accidental editing
- Supports worn-item staging and restoration
- Supports bag and inventory item staging
- Handles equivalent duplicate items deterministically
- Safely restores items after reaching their target
- Persists queue state and settings per character/server
- Tracks Base and Enchanted item XP/hour separately
- Estimates remaining queue completion time
- Optional automatic recovery from safe, deterministic interruptions
- Combat-aware movement waiting with safe revalidation
- Compact Mode for normal operation
- Full Mode for queue management and diagnostics
- Triune AutoCombat integration
- Detailed diagnostic logging available when enabled

## How Item Evolution Works

PTItemEvolver uses the Project Triune item evolution system.

Eligible items progress through these tiers:

```text
Base
  ↓
Enchanted
  ↓
Legendary
```

Base and Enchanted items can be placed in the powersource slot and gain evolution progress through normal gameplay.

PTItemEvolver monitors the active transaction and handles the transition to the requested queue target.

A queue can also contain the same logical item more than once.

For example:

```text
Item A -> Enchanted
Item B -> Enchanted
Item C -> Enchanted
Item A -> Legendary
Item B -> Legendary
Item C -> Legendary
```

This allows an entire gear set to be upgraded to Enchanted first, followed by Legendary upgrades later.

## Installation

Copy:

```text
ItemEvolver.lua
```

to your MacroQuest Lua directory.

Example:

```text
MacroQuest\lua\ItemEvolver.lua
```

Then load the script in-game with:

```text
/lua run ItemEvolver
```

## Basic Usage

1. Run PTItemEvolver.
2. Browse items using the Worn Items, Bag Items, or All Items tab.
3. Click **Add** next to an eligible item.
4. Select the desired target tier in the queue.
5. Reorder the queue if needed.
6. Enable **Start TAC when queue starts** if desired.
7. Enable **Automatically recover safe interruptions** if desired.
8. Click **Start Queue**.
9. Play normally while the active item evolves.

When the current item reaches its queued target, PTItemEvolver safely handles restoration or handoff and continues to the next queue entry.

## Queue Controls

Queued items can be managed with:

- Target dropdown
- Up
- Down
- Remove

While a queue is running:

- The active row is locked.
- Future queued rows can still be edited.
- Future rows can be reordered among themselves.
- Future rows can be removed.
- Future targets can be changed.
- Future rows cannot be moved ahead of the active row.

Use **Pause After Current** to allow the current item to finish before pausing the queue.

A paused queue can later be resumed with **Resume Queue**.

PTItemEvolver restores persisted queue state after a Lua restart, but automation does not automatically resume. Use **Start Queue** or **Resume Queue** when you are ready for the script to continue.

## Item XP Tracking

PTItemEvolver tracks item experience directly from live Project Triune item-XP messages.

The UI displays separate rates for:

- **Base XP/Hour**
- **Enchanted XP/Hour**

The two tiers are tracked independently because Base and Enchanted items progress at different rates.

The rate tracker is designed to handle normal gameplay conditions, including:

- multiple XP messages in the same second
- long gaps between XP samples
- switching between items
- percentage resets when a new item begins
- returning to a previously tracked tier later in the session

Same-second XP messages are deferred into the next valid timed sample rather than being treated as instantaneous XP gain.

Long gaps establish a fresh timing baseline so extended downtime does not permanently dilute the accumulated XP/hour estimate.

## Queue ETA

PTItemEvolver estimates remaining queue completion time using the observed Base and Enchanted XP/hour rates.

The estimate accounts for remaining work across queued items.

Progress is treated as:

- **Observed** — PTItemEvolver has seen current-session XP progress for that exact active item/tier
- **Assumed** — no current-session progress has been observed, so the tier is treated as starting at 0%
- **Complete** — no remaining work for that tier

Queue ETA is informational only.

It does not control queue progression, item movement, recovery behavior, or evolution logic.

## Compact Mode

Compact Mode provides a smaller operational view while the queue is running.

It displays information such as:

- Queue state
- Active item
- Target tier
- Current movement state
- Base XP/hour
- Enchanted XP/hour
- Queue ETA
- Queue preview
- Restore / recovery controls when applicable
- Pause After Current
- Start / Resume controls when applicable

Use **Full Mode** to return to the complete queue and item management interface.

## Triune AutoCombat Integration

PTItemEvolver can coordinate with Triune AutoCombat when item movement requires TAC to be paused.

PTItemEvolver only uses:

```text
/ac status
/ac pause
/ac run
```

It does not use a bare:

```text
/ac
```

PTItemEvolver tracks TAC ownership and state so that it does not stop or restart TAC merely because an ItemEvolver error occurred.

TAC is paused only when ItemEvolver has a verified reason to require exclusive item control.

If TAC was already running independently, PTItemEvolver does not falsely claim ownership simply because a queue was started.

## Automatically Recover Safe Interruptions

PTItemEvolver includes an optional setting:

**Automatically recover safe interruptions**

This option is disabled by default.

When enabled, PTItemEvolver may automatically recover from specific situations that can be resolved safely and deterministically.

### Combat-Blocked Movement

If a queue operation needs to move an item while the character is in combat, PTItemEvolver can wait rather than immediately failing the queue.

The script waits until combat has remained continuously clear for 2 seconds.

Any combat reading during that window resets the timer.

After the clear period is confirmed, PTItemEvolver discards stale pre-move observations and revalidates the operation from live state before moving anything.

Combat may prevent a physical movement from starting.

If combat begins after a verified physical item movement has already started, PTItemEvolver allows that in-flight movement and its bounded verification sequence to finish rather than abandoning an item halfway through the transaction.

### TAC-Related Item Recovery

PTItemEvolver can also recover from certain TAC-related item movement interruptions.

Depending on the verified live state, recovery may include:

- recognizing the exact expected Legendary item after it has already been moved into inventory
- adopting the exact active transaction item if it is already back in powersource
- restaging the exact verified transaction item if it was safely moved back into inventory

Automatic recovery uses the same hardened item identity and movement logic as normal queue staging.

It does not use a separate looser recovery path.

### Recovery Retry Policy

Automatic recovery retries only read-only reconciliation checks while game state is still settling.

The current observation retry schedule is approximately:

```text
Immediate
2 seconds later
5 seconds later
```

Physical item movement failures are not retried by the outer recovery scheduler.

If a pickup, placement, restoration, or verification step fails inside the movement engine, PTItemEvolver stops in `ERROR` instead of repeatedly attempting the physical operation.

If PTItemEvolver cannot prove that recovery is safe, it stops and requires manual intervention.

## Recover / Re-evaluate

When the queue enters an error state, PTItemEvolver may provide **Recover / Re-evaluate**.

This tells the script to inspect the live item state again using the same authoritative reconciliation rules used by queue startup and automatic recovery.

Manual recovery can recognize situations such as:

- the exact active item already being back in powersource
- the expected Legendary item already existing in inventory
- the exact queued item being safely available again

Recovery never relaxes item identity requirements.

## Safety

PTItemEvolver is intentionally conservative.

It does not:

- Destroy items
- Drop items on the ground
- Use blind inventory coordinates
- Guess when item identity cannot be verified
- Adopt loose wrong-ID item matches
- Assume an arbitrary cursor item belongs to ItemEvolver
- Continue through ambiguous transaction states
- Repeatedly retry failed physical item movement from the recovery scheduler
- Automatically resume queue execution after a Lua restart
- Automatically purchase Alternate Advancement abilities

Before moving an item, PTItemEvolver verifies relevant state such as:

- Cursor state
- Powersource state
- Item identity
- Source location
- Destination availability
- Queue transaction state
- TAC state when applicable
- Combat state before beginning a new physical move

If PTItemEvolver cannot verify a safe operation, it stops instead of guessing.

## Shared Movement Engine

Normal queue staging and automatic recovery restaging use the same verified movement implementation.

That shared movement path handles:

- deterministic pickup
- pickup verification
- powersource placement
- temporary storage of an existing powersource item
- final location verification
- cursor verification
- TAC resume behavior

This keeps safety fixes and movement behavior consistent across normal queue operation and automatic recovery.

## Item Identity

MacroQuest does not expose a stable per-instance item GUID suitable for this workflow.

Because of that, PTItemEvolver treats item location as a hint rather than permanent identity.

Item resolution uses information including:

- Base item ID
- Exact expected tier-derived item ID
- Normalized item name
- Expected tier
- Remembered location

PTItemEvolver does not silently adopt an item solely because its name or apparent tier looks correct if the expected exact ID does not match.

When multiple truly equivalent copies exist, PTItemEvolver treats those copies as fungible and selects one deterministically where that is safe.

## Project Triune Tier Detection

PTItemEvolver uses Project Triune's tier ID pattern:

```text
Base ID
Enchanted ID = Base ID + 1,000,000
Legendary ID = Base ID + 2,000,000
```

The item name suffix is also used as a validation signal.

Example:

```text
Rusty Bastard Sword
Rusty Bastard Sword (Enchanted)
Rusty Bastard Sword (Legendary)
```

## MacroQuest Evolving Fields

PTItemEvolver does not use MacroQuest's standard:

```text
Evolving.*
```

fields for control logic.

Those values are not reliable for Project Triune item evolution.

## Consume Experience

PTItemEvolver does not purchase or automatically activate Consume Experience.

Item evolution is handled passively through normal gameplay.

## Logging

Detailed diagnostic logging is available for troubleshooting.

Release builds ship with verbose debug logging disabled by default.

When enabled, diagnostics can include information such as:

- Script version
- Queue state
- Queue actions
- Active item
- Item identity
- Expected tier
- Source location
- Destination location
- Powersource contents
- Cursor state
- TAC state
- Combat-wait state
- Combat-clear debounce behavior
- Automatic recovery scheduling
- Recovery attempts
- Reconciliation results
- XP progress attribution
- XP/hour samples
- Restore behavior
- Validation failures
- Errors

The diagnostic system is designed to capture enough state to investigate most failures from a single occurrence.

## Commands

Available commands include:

```text
/ptie scan
/ptie status
/ptie restore
```

## Version

Current release:

```text
v1.3
```

## Compatibility

PTItemEvolver was written and tested specifically for Project Triune.

Behavior on other EverQuest servers, emulators, or progression environments is not supported or guaranteed.

## Disclaimer

Use at your own risk.

PTItemEvolver is designed to be conservative with item movement, but EverQuest inventory automation always carries some risk.

When the script cannot safely verify the expected state, it stops rather than attempting to continue blindly.