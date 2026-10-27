"""Evacuation what-if on the simulated graph: paths, rerouting, stranded rooms, bottlenecks, and
isolation from the operational evacuation routes and the alarm path."""

from __future__ import annotations

from app.scenario.evacuation import LABEL, demo_graph, run
from tests.conftest import auth_token, telemetry


def _rooms(result):
    return {r.room_id: r for r in result.rooms}


def test_baseline_paths_use_stair_a_and_main_exit():
    result = run(demo_graph(), [])
    rooms = _rooms(result)
    assert rooms["ap12"].path == ["ap12", "corridor_3", "stair_a", "lobby", "exit_main"]
    assert rooms["ap12"].length_m == 35.0
    assert result.stranded_people == 0 and result.label == LABEL
    worst = result.loads[0]
    assert worst.edge_id == "stair_a_lobby" and worst.people == 9 and worst.minutes_to_clear == 0.3


def test_blocking_stair_a_reroutes_and_moves_the_bottleneck():
    result = run(demo_graph(), ["stair_a"])
    rooms = _rooms(result)
    assert rooms["ap14"].path == ["ap14", "corridor_3", "stair_b", "exit_back"]
    assert result.loads[0].edge_id == "stair_b_back" and result.loads[0].minutes_to_clear == 0.45
    assert result.unavailable == ["stair_a"]


def test_blocking_an_edge_only():
    rooms = _rooms(run(demo_graph(), ["lobby_main"]))
    assert rooms["ap13"].exit_id == "exit_back"
    # stair B to the back door (41 m) beats stair A, lobby, back door (44 m)
    assert rooms["ap13"].path == ["ap13", "corridor_3", "stair_b", "exit_back"] and rooms["ap13"].length_m == 41.0


def test_no_exit_left_strands_every_room():
    result = run(demo_graph(), ["corridor_3"])
    assert all(r.exit_id is None and r.path == [] for r in result.rooms)
    assert result.stranded_people == 9 and result.loads == []


def test_unknown_and_duplicate_ids():
    result = run(demo_graph(), ["stair_a", "stair_a", "nope"])
    assert result.unavailable == ["stair_a"] and result.unknown_ids == ["nope"]
    assert [r.path for r in result.rooms] == [r.path for r in run(demo_graph(), ["stair_a"]).rooms]


async def _post(client, user="mihai", unavailable=()):
    token = await auth_token(client, user)
    return await client.post("/api/v1/scenarios/evacuation", json={"unavailable": list(unavailable)},
                             headers={"Authorization": f"Bearer {token}"})


async def test_endpoint_labels_and_roles(client):
    body = (await _post(client, unavailable=["stair_a"])).json()
    assert body["label"] == "scenario — not a safety prediction" and body["simulated"] is True
    assert {n["id"] for n in body["nodes"]} >= {"ap12", "stair_a", "exit_main"}
    assert body["unavailable"] == ["stair_a"]
    for user in ("ana", "dispecer"):
        assert (await _post(client, user)).status_code == 403
    for user in ("tehnician", "admin"):
        assert (await _post(client, user)).status_code == 200
    assert (await _post(client, unavailable=["x" * 65])).status_code == 422


async def test_isolated_from_operational_routes(client):
    token = await auth_token(client, "mihai")
    headers = {"Authorization": f"Bearer {token}"}
    before = (await client.get("/api/v1/buildings/bld_007/evacuation", headers=headers)).json()
    await _post(client, unavailable=["stair_a", "corridor_3", "zone_hallway"])
    assert (await client.get("/api/v1/buildings/bld_007/evacuation", headers=headers)).json() == before


async def test_alarm_regression_gas_still_evacuates_during_a_scenario(client):
    await _post(client, unavailable=["corridor_3"])
    resp = await client.post("/api/v1/telemetry", json=telemetry(
        "dev_gas_kitchen", "combustible_gas", 6000, zone_id="zone_kitchen", unit_id="unit_0312"))
    assert resp.json()["incident_state"] == "evacuation"
