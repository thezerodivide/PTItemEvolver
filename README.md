# PTItemEvolver

PTItemEvolver is a MacroQuest Lua script built specifically for Project Triune.

It helps safely queue eligible items for evolution from Base to Enchanted or Legendary while handling item movement, restoration, queue order, and Triune AutoCombat coordination.

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
- Compact Mode for normal operation
- Full Mode for queue management and diagnostics
- Detailed diagnostic logging available on demand
- Triune AutoCombat integration
- Live-state recovery and reconciliation

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

PTItemEvolver monitors the transaction and handles the transition to the requested queue target.

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
7. Click **Start Queue**.
8. Play normally while the active item evolves.

When the current item reaches its queued target, PTItemEvolver handles the restore/handoff and continues to the next queue entry.

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

If a transaction enters an error state, **Recover / Re-evaluate** can reconcile the exact item against live powersource, cursor, and inventory state before deciding whether to resume monitoring or return the queue entry to a safe paused state.

## Compact Mode

Compact Mode provides a smaller operational view while the queue is running.

It displays:

- Queue state
- Active item
- Target tier
- Current movement state
- Queue preview
- Restore control
- Recover / Re-evaluate when applicable
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

PTItemEvolver tracks whether TAC was originally running and only restores TAC when appropriate.

PTItemEvolver does not treat every item transaction error as a reason to stop TAC. TAC is held only while PTItemEvolver has a verified exclusive claim on the transaction item on cursor. If no PTItemEvolver-owned cursor item exists, an ItemEvolver error leaves TAC running or restores it when appropriate.

## Safety

PTItemEvolver is intentionally conservative.

It does not:

- Destroy items
- Drop items on the ground
- Use blind inventory coordinates
- Guess when item identity cannot be verified
- Continue through inconsistent transaction states
- Automatically purchase Alternate Advancement abilities

Before moving an item, PTItemEvolver verifies:

- Cursor state
- Powersource state
- Item identity
- Source location
- Destination availability
- TAC state when applicable

If PTItemEvolver cannot verify a safe operation, it stops instead of guessing.

## Item Identity

MacroQuest does not expose a stable per-instance item GUID suitable for this workflow.

Because of that, PTItemEvolver treats item location as a hint rather than permanent identity.

If an item has moved since it was queued, PTItemEvolver attempts to resolve it using:

- Base item ID
- Normalized item name
- Expected tier
- Current item ID
- Remembered location

When multiple truly equivalent copies exist, PTItemEvolver selects one deterministically.

For v1.2 reconciliation and recovery, PTItemEvolver requires exact agreement on tier-derived item ID, BaseID, normalized name, and expected tier before adopting a live item.

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

## Recovery and Reconciliation

v1.2 adds live-state reconciliation for interrupted or uncertain queue states.

PTItemEvolver can safely:

- Resume a queued item that is already in the powersource slot
- Reconcile an exact active transaction item that remains in powersource
- Recover an exact queued item that has been returned to normal inventory
- Reset a recovered queue entry to a safe paused state
- Continue only when the expected item identity can be verified
- Handle cases where TAC or another actor may have moved the expected Legendary before PTItemEvolver observed it on cursor

Use **Recover / Re-evaluate** when ItemEvolver is in an error state and the physical item state has been made safe or restored manually.

Recovery work is deferred outside the ImGui render callback so TAC status checks, event processing, and bounded waits do not execute inside the UI callback.

## Logging

Detailed diagnostic logging is available, but verbose debug logging is disabled by default in the release build.

When enabled, logs include information such as:

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
- Retry attempts
- Restore behavior
- Validation failures
- Errors

The logging is intentionally detailed so most problems can be diagnosed from a single run.

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
v1.2
```

## Compatibility

PTItemEvolver was written and tested specifically for Project Triune.

Behavior on other EverQuest servers, emulators, or progression environments is not supported or guaranteed.

## Disclaimer

Use at your own risk.

PTItemEvolver is designed to be conservative with item movement, but EverQuest inventory automation always carries some risk. The script stops when it cannot safely verify the expected state rather than attempting to continue blindly.
