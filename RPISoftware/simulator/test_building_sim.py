"""Offline tests for building_sim.py (stdlib unittest, no broker, no hub).

    cd simulator && python -m unittest test_building_sim -v
"""

from __future__ import annotations

import argparse
import copy
import os
import unittest
from pathlib import Path
from unittest import mock

import building_sim as bs
import hw_sim

HERE = Path(__file__).parent
ROOM = {"zone_id": "zone_kitchen", "label": "Bucătărie", "unit_id": "unit_0312", "kind": "kitchen",
        "pos": [2, 2], "nodes": ["air", "water"], "scenario": "normal"}


def setUpModule() -> None:
    for target in ("hw_sim.log", "building_sim.log"):  # keep the test output readable
        patcher = mock.patch(target)
        patcher.start()
        unittest.addModuleCleanup(patcher.stop)


def config(*rooms: dict, **top) -> dict:
    return {"building_id": "bld_007", "rooms": [copy.deepcopy(r) for r in rooms] or [copy.deepcopy(ROOM)], **top}


def room(**changes) -> dict:
    return {**copy.deepcopy(ROOM), **changes}


def sim_args(**changes) -> argparse.Namespace:
    return bs.parse_args(["--no-hub", *changes.get("argv", [])])


class ConfigFiles(unittest.TestCase):
    def test_demo_config(self):
        cfg = bs.load_config(str(HERE / "rooms.demo.json"))
        ids = {r.zone_id for r in cfg.rooms}
        self.assertEqual(cfg.building_id, "bld_007")
        self.assertTrue({"zone_kitchen", "zone_bedroom", "zone_hallway", "zone_boiler"} <= ids)
        self.assertTrue(12 <= len(cfg.rooms) <= 14)
        self.assertTrue(18 <= sum(len(r.nodes) for r in cfg.rooms) <= 22)
        self.assertEqual({r.unit_id for r in cfg.rooms}, {"unit_0312", "unit_0313", "unit_0314", "common"})
        self.assertEqual(len({r.pos for r in cfg.rooms}), len(cfg.rooms), "two rooms share a position")
        labels = [(r.unit_id, bs.norm(r.label)) for r in cfg.rooms]
        self.assertEqual(len(set(labels)), len(labels), "a flat has two rooms with one name")
        self.assertTrue(all(r.unit_label for r in cfg.rooms), "every unit needs its label for the console")

    def test_small_config(self):
        cfg = bs.load_config(str(HERE / "rooms.small.json"))
        self.assertEqual(len(cfg.rooms), 3)

    def test_config_found_next_to_the_script(self):
        old = os.getcwd()
        os.chdir("/")
        try:
            self.assertEqual(len(bs.load_config("rooms.small.json").rooms), 3)
        finally:
            os.chdir(old)


class ParseConfig(unittest.TestCase):
    def test_defaults_and_bases(self):
        r = bs.parse_config(config(room(zone_id="zone_bath_12", nodes=["water"]))).rooms[0]
        self.assertEqual(r.bases, {"water": "water-bath-12"})
        self.assertEqual(r.short, "bath_12")
        self.assertEqual(r.pos, (2.0, 2.0))
        no_nodes = {k: v for k, v in ROOM.items() if k not in ("nodes", "scenario")}
        r = bs.parse_config(config(no_nodes)).rooms[0]
        self.assertEqual(r.nodes, ("air", "water"))
        self.assertEqual(r.scenario, "normal")
        self.assertEqual(r.bases, {"air": "air-kitchen", "water": "water-kitchen"})

    def test_explicit_base_and_alias(self):
        r = bs.parse_config(config(room(air_base="home/Air 1", scenario="Gaz"))).rooms[0]
        self.assertEqual(r.bases["air"], "home/Air 1")
        self.assertEqual(r.scenario, "gas")

    def test_comments_are_ignored(self):
        bs.parse_config(config(room(_note="x"), _comment="y"))

    def test_invalid(self):
        bad = [
            ([], "JSON object"),
            ({"rooms": [ROOM]}, "building_id"),
            (config() | {"rooms": []}, "non-empty"),
            (config() | {"extra": 1}, "unknown top-level"),
            (config(room(), room()), "used twice"),
            (config(room(kind="garage")), "kind must be"),
            (config(room(pos=[1])), "pos must be"),
            (config(room(pos=[1, True])), "pos must be"),
            (config(room(nodes=["air", "air"])), "nodes must"),
            (config(room(nodes=[])), "nodes must"),
            (config(room(nodes=["gas"])), "nodes must"),
            (config(room(scenario="fire")), "unknown scenario"),
            (config(room(nodes=["air"], scenario="leak")), "needs a water node"),
            (config(room(nodes=["water"], scenario="scurgere"), room(zone_id="zone_x", nodes=["water"], scenario="co")),
             "needs a air node"),
            (config(room(label="")), "label"),
            (config(room(zone_id="zone kitchen")), "zone_id"),
            (config(room(air_base="a/#")), "air_base"),
            (config(room(air_base=5)), "air_base"),
            (config(room(scenrio="gas")), "unknown key"),
            (config(units=[{"unit_id": "u1", "label": "Ap. 1"}]), "floor_id"),
        ]
        for data, message in bad:
            with self.subTest(message=message):
                with self.assertRaises(bs.ConfigError) as ctx:
                    bs.parse_config(data)
                self.assertIn(message, str(ctx.exception))

    def test_base_topics_unique(self):
        with self.assertRaisesRegex(bs.ConfigError, "clashes"):  # derived bases collide
            bs.parse_config(config(room(zone_id="zone_bath_12"), room(zone_id="zone_bath-12")))
        with self.assertRaisesRegex(bs.ConfigError, "clashes"):  # explicit base = another derived one
            bs.parse_config(config(room(), room(zone_id="zone_x", nodes=["air"], air_base="air-kitchen")))
        with self.assertRaisesRegex(bs.ConfigError, "clashes"):  # same hub node id (slug)
            bs.parse_config(config(room(nodes=["air"]), room(zone_id="zone_x", nodes=["air"], air_base="Air_Kitchen")))
        cfg = bs.load_config(str(HERE / "rooms.demo.json"))
        bases = [b for r in cfg.rooms for b in r.bases.values()]
        self.assertEqual(len(bases), len(set(bases)))
        self.assertTrue(all(b.startswith(("air-", "water-")) for b in bases))

    def test_units(self):
        cfg = bs.parse_config(config(units=[{"unit_id": "unit_0315", "label": "Ap. 15", "floor_id": "flr_03"}]))
        self.assertEqual(cfg.units["unit_0315"], {"label": "Ap. 15", "floor_id": "flr_03", "kind": "residential"})


class Matching(unittest.TestCase):
    def setUp(self):
        self.rooms = bs.load_config(str(HERE / "rooms.demo.json")).rooms

    def one(self, query: str) -> str:
        found = bs.match_rooms(self.rooms, query)
        self.assertEqual(len(found), 1, query)
        return found[0].zone_id

    def test_norm(self):
        self.assertEqual(bs.norm("Bucătărie_2"), "bucatarie 2")
        self.assertEqual(bs.norm("ȘȚĂÎÂ şţ"), "staia st")
        self.assertEqual(bs.norm("  Baie-12 "), "baie 12")

    def test_by_id_suffix_and_label(self):
        self.assertEqual(self.one("zone_kitchen"), "zone_kitchen")
        self.assertEqual(self.one("kitchen"), "zone_kitchen")
        self.assertEqual(self.one("bucatarie 12"), "zone_kitchen")
        self.assertEqual(self.one("BUCĂTĂRIE AP. 12"), "zone_kitchen")
        self.assertEqual(self.one("baie ap 13"), "zone_bath_13")
        self.assertEqual(self.one("Bucătărie 13"), "zone_kitchen_13")
        self.assertEqual(self.one("bath_12"), "zone_bath_12")
        self.assertEqual(self.one("bath-12"), "zone_bath_12")
        self.assertEqual(self.one("baie 12"), "zone_bath_12")
        self.assertEqual(self.one("centrala"), "zone_boiler")
        self.assertEqual(self.one("hol"), "zone_hallway")

    def test_unique_prefix(self):
        self.assertEqual(self.one("centr"), "zone_boiler")
        self.assertEqual(self.one("hall"), "zone_hallway")

    def test_ambiguous_and_unknown(self):
        with self.assertRaisesRegex(LookupError, "matches 3 rooms"):
            bs.match_rooms(self.rooms, "baie")
        with self.assertRaisesRegex(LookupError, "no room"):
            bs.match_rooms(self.rooms, "garaj")
        with self.assertRaises(LookupError):
            bs.match_rooms(self.rooms, "  ")

    def test_every_room(self):
        for word in ("all", "toate", "*", "ALL"):
            self.assertEqual(len(bs.match_rooms(self.rooms, word)), len(self.rooms))

    def test_only(self):
        picked = bs.select_rooms(self.rooms, "centrala, kitchen")
        self.assertEqual([r.zone_id for r in picked], ["zone_kitchen", "zone_boiler"])  # config order
        with self.assertRaises(bs.ConfigError):
            bs.select_rooms(self.rooms, "nowhere")
        with self.assertRaises(bs.ConfigError):
            bs.select_rooms(self.rooms, " , ")


class Overrides(unittest.TestCase):
    def setUp(self):
        self.rooms = bs.load_config(str(HERE / "rooms.demo.json")).rooms

    def test_room_and_alias(self):
        got = bs.parse_overrides(["zone_kitchen=gas", "baie 12=scurgere", "Bucătărie 13=GAZ"], self.rooms)
        self.assertEqual(got, {"zone_kitchen": "gas", "zone_bath_12": "leak", "zone_kitchen_13": "gas"})

    def test_all_skips_rooms_without_the_node(self):
        got = bs.parse_overrides(["all=leak"], self.rooms)
        self.assertEqual(set(got), {r.zone_id for r in self.rooms if "water" in r.nodes})
        self.assertEqual(bs.parse_overrides(["co"], self.rooms),
                         {r.zone_id: "co" for r in self.rooms if "air" in r.nodes})

    def test_later_wins(self):
        self.assertEqual(bs.parse_overrides(["all=smoke", "kitchen=normal"], self.rooms)["zone_kitchen"], "normal")

    def test_errors(self):
        for item, message in (("kitchen=", "ROOM=SCENARIO"), ("=gas", "ROOM=SCENARIO"),
                              ("kitchen=fire", "unknown scenario"), ("garaj=gas", "no room"),
                              ("baie=leak", "matches"), ("bedroom=leak", "has no water node")):
            with self.subTest(item=item):
                with self.assertRaisesRegex(bs.ConfigError, message):
                    bs.parse_overrides([item], self.rooms)

    def test_scenario_tables_match_hw_sim(self):
        self.assertEqual(set(bs.SCENARIO_NEEDS), set(hw_sim.SCENARIOS))
        self.assertTrue(set(bs.SCENARIO_ALIASES.values()) <= set(hw_sim.SCENARIOS))


class BuildingConsole(unittest.TestCase):
    """The console without a broker: nothing is started, so nothing connects."""

    def setUp(self):
        cfg = bs.load_config(str(HERE / "rooms.demo.json"))
        self.building = bs.Building(cfg.rooms, sim_args())

    def sim(self, zone_id: str) -> bs.RoomSim:
        return next(s for s in self.building.sims if s.room.zone_id == zone_id)

    def test_nodes_per_room(self):
        hall = self.sim("zone_hallway")
        self.assertEqual(hall.nodes, [hall.air])
        self.assertEqual(self.sim("zone_bath_13").water.base, "water-bath-13")
        kitchen = self.sim("zone_kitchen")
        self.assertEqual([n.base for n in kitchen.nodes], ["air-kitchen", "water-kitchen"])
        self.assertIs(kitchen.clock, self.building.clock)
        self.assertFalse(kitchen.air.log_heartbeats)

    def test_switch_scenario(self):
        out = self.building.execute("bucatarie 12 gaz")
        self.assertEqual(out, "kitchen: gas")
        self.assertEqual(self.sim("zone_kitchen").scenario, "gas")
        out = self.building.execute("toate scurgere")
        self.assertIn("skipped (no water node)", out)
        self.assertEqual(self.sim("zone_bath_13").scenario, "leak")
        self.assertEqual(self.sim("zone_bedroom").scenario, "normal")
        self.assertIn("needs a water node", self.building.execute("hol scurgere"))
        self.assertIn("matches 3 rooms", self.building.execute("baie test"))
        self.assertIn("unknown scenario", self.building.execute("kitchen dance"))

    def test_commands_need_connected_nodes(self):
        self.assertIn("air node offline", self.building.execute("kitchen test"))
        self.assertIn("needs a water node", self.building.execute("dormitor 12 deschide"))

    def test_words(self):
        self.assertIn("<room> <scenario>", self.building.execute("help"))
        self.assertIn("? type", self.building.execute("dance"))
        self.assertFalse(self.building.stop_event.is_set())
        self.building.execute("quit")
        self.assertTrue(self.building.stop_event.is_set())

    def test_scripts_run_offline(self):
        """Every scenario steps on a room's (unconnected) nodes without errors."""
        for zone_id in ("zone_kitchen", "zone_bath_13", "zone_bedroom"):
            sim = self.sim(zone_id)
            for node in (sim.air, sim.water):
                node.boot(sim.clock.now())
            for name in bs.SCENARIO_NEEDS:
                if bs.missing_nodes(name, sim.room.nodes):
                    continue
                with mock.patch.object(hw_sim.Node, "connect"), mock.patch.object(hw_sim.Node, "drop"):
                    sim.play(name)
                    for _ in range(50):
                        sim.tick()


class FakeHub:
    def __init__(self, zones, units=None, admin=True):
        self.zones, self.units, self.admin, self.calls = zones, units or [], admin, []

    def call(self, method, path, body=None):
        self.calls.append((method, path, body))
        if path.endswith("/zones") and method == "GET":
            return 200, self.zones
        if not self.admin:
            return 404, {"detail": "Not Found"}
        if path.endswith("/units") and method == "GET":
            return 200, self.units
        if path.endswith("/units") and method == "POST":
            unit = {"unit_id": f"unit_new{len(self.units)}", **body}
            self.units.append(unit)
            return 201, unit
        if path.endswith("/zones") and method == "POST":
            zone = {"zone_id": f"zone_{len(self.zones)}x", "id": None, **body}
            self.zones.append({"id": zone["zone_id"], **body})
            return 201, zone
        return 500, {"detail": "unexpected"}


class HubSetup(unittest.TestCase):
    SEED = [{"id": "zone_kitchen", "unit_id": "unit_0312", "label": "Bucatarie"}]

    def rooms(self, *extra):
        return bs.parse_config(config(room(), *extra)).rooms

    def test_creates_missing_zone_once(self):
        hub = FakeHub(copy.deepcopy(self.SEED), units=[{"unit_id": "unit_0313", "label": "Ap. 13"}])
        rooms = self.rooms(room(zone_id="zone_bath_13", label="Baie 13", unit_id="unit_0313", kind="bathroom"))
        ready = bs.setup_hub(hub, "bld_007", rooms, {})
        self.assertEqual([r.hub_zone_id for r in ready], ["zone_kitchen", "zone_1x"])
        posts = [c for c in hub.calls if c[0] == "POST"]
        self.assertEqual(posts[0][2], {"label": "Baie 13", "kind": "bathroom", "unit_id": "unit_0313",
                                       "pos_x": 2.0, "pos_y": 2.0})
        # second run: found by label within the unit (the hub picked the id), nothing created
        hub.calls.clear()
        rooms = self.rooms(room(zone_id="zone_bath_13", label="Baie 13", unit_id="unit_0313", kind="bathroom"))
        ready = bs.setup_hub(hub, "bld_007", rooms, {})
        self.assertEqual([r.hub_zone_id for r in ready], ["zone_kitchen", "zone_1x"])
        self.assertFalse([c for c in hub.calls if c[0] == "POST"])

    def test_unit_from_config(self):
        hub = FakeHub(copy.deepcopy(self.SEED))
        cfg = bs.parse_config(config(room(), room(zone_id="zone_k15", unit_id="unit_0315", label="Bucătărie 15"),
                                     units=[{"unit_id": "unit_0315", "label": "Ap. 15", "floor_id": "flr_03"}]))
        ready = bs.setup_hub(hub, "bld_007", cfg.rooms, cfg.units)
        self.assertEqual(len(ready), 2)
        self.assertIn(("POST", "/api/v1/admin/buildings/bld_007/units",
                       {"label": "Ap. 15", "floor_id": "flr_03", "kind": "residential"}), hub.calls)
        self.assertEqual(hub.zones[-1]["unit_id"], "unit_new0")

    def test_unknown_unit_and_old_hub_skip_rooms(self):
        hub = FakeHub(copy.deepcopy(self.SEED))
        ready = bs.setup_hub(hub, "bld_007", self.rooms(room(zone_id="zone_x", unit_id="unit_9999")), {})
        self.assertEqual([r.zone_id for r in ready], ["zone_kitchen"])
        hub = FakeHub(copy.deepcopy(self.SEED), admin=False)
        ready = bs.setup_hub(hub, "bld_007", self.rooms(room(zone_id="zone_x", unit_id="unit_0312", label="X")), {})
        self.assertEqual([r.zone_id for r in ready], ["zone_kitchen"])

    def test_hub_url(self):
        bs.Hub("http://backend:8000")
        for url in ("ftp://x", "localhost:8000", "http://"):
            with self.assertRaises(bs.HubError):
                bs.Hub(url)


class HwSimUnchanged(unittest.TestCase):
    """hw_sim.py's own CLI and single-pair behaviour stay as they were."""

    def expected(self, **changes):
        env = os.environ
        base = {"scenario": "normal", "host": env.get("MQTT_HOST", "localhost"),
                "port": int(env.get("MQTT_PORT", "1883")), "username": env.get("MQTT_USERNAME") or None,
                "password": env.get("MQTT_PASSWORD") or None, "air_base": "canary", "water_base": "water-sensor",
                "fast": False, "warmup": 20.0, "duration": 0.0, "exit": False, "verbose": False}
        return {**base, **changes}

    def test_defaults(self):
        self.assertEqual(vars(hw_sim.parse_args([])), self.expected())

    def test_flags(self):
        argv = ["--scenario", "co", "--fast", "--air-base", "air-kitchen", "--water-base", "water-kitchen",
                "--warmup", "0", "--duration", "5", "--exit", "-v", "--host", "mosquitto", "--port", "1884"]
        self.assertEqual(vars(hw_sim.parse_args(argv)),
                         self.expected(scenario="co", fast=True, air_base="air-kitchen", water_base="water-kitchen",
                                       warmup=0.0, duration=5.0, exit=True, verbose=True, host="mosquitto", port=1884))

    def test_errors(self):
        for argv in (["--air-base", "x", "--water-base", "x"], ["--warmup", "-1"], ["--scenario", "fire"],
                     ["--air-base", "a/+"]):
            with self.subTest(argv=argv), mock.patch("sys.stderr"), self.assertRaises(SystemExit):
                hw_sim.parse_args(argv)

    def test_sim_pair(self):
        sim = hw_sim.Sim(hw_sim.parse_args(["--fast"]))
        self.assertEqual(sim.clock.scale, 5.0)
        self.assertEqual([n.base for n in sim.nodes], ["canary", "water-sensor"])
        self.assertTrue(all(n.log_heartbeats for n in sim.nodes))
        self.assertEqual(sorted(hw_sim.SCENARIOS),
                         ["all", "co", "gas", "leak", "normal", "offline", "presence", "reboot", "smoke"])


if __name__ == "__main__":
    unittest.main()
