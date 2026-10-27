# Water-leak impact map: plumbing topology

During a water-leak incident, the Dispatch and Manager views list the units the leak may reach.
The list comes only from a plan you write. Nothing is inferred from floor numbers or positions.
No volume or spread is estimated, and no valve is closed.

Set `CANARY_WATER_TOPOLOGY_FILE` to a JSON file (example: `docs/water_topology.example.json`):

```json
{
  "buildings": {
    "bld_007": {
      "below":  { "unit_0312": ["unit_0212"], "unit_0212": ["unit_0112"] },
      "risers": { "riser_kitchen_A": ["unit_0112", "unit_0212", "unit_0312", "unit_0412"] }
    }
  }
}
```

- `below`: for each unit, the units directly under it. It is followed down the building for up
  to 6 floors, so you only write one floor at a time.
- `risers`: units that share a vertical pipe. A leak in one of them flags the others: the leak may
  be in the shared pipe.
- Ids are `units.id` values. Unknown ids are shown as they are written.

The file is read on every request, so edits apply without a restart. A missing file, or no entry
for the building, shows *Unknown: plan not configured*. A file that can't be read or parsed shows
*Unknown: plan could not be read*. Neither ever shows "no units affected".
