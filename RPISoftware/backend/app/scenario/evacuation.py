"""Evacuation what-if on a simulated zone graph (staff "scenario" tool, never operational).

The graph is a JSON file next to this module (demo_graph.json): rooms, corridors, stairs and exits,
with a simulated head count per room, and edges with a walking length (m) and a nominal flow
capacity (persons per minute). It has no link to `EvacuationRoute` rows, the incident or any
reading. Marking nodes or edges unavailable recomputes, per room, the shortest path to any exit
(Dijkstra on length), the rooms that can no longer reach one, and the load on each edge. An edge's
"minutes to clear" is its load divided by its capacity: a bottleneck indicator, not a timing.

Labelled "scenario — not a safety prediction": no smoke spread, no walking speeds, no behaviour.
"""

from __future__ import annotations

import heapq
import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

LABEL = "scenario — not a safety prediction"
GRAPH_PATH = Path(__file__).with_name("demo_graph.json")


@dataclass(frozen=True)
class Node:
    id: str
    label: str
    kind: str  # room | corridor | stair | exit
    people: int


@dataclass(frozen=True)
class Edge:
    id: str
    a: str
    b: str
    length_m: float
    capacity_ppm: float


@dataclass(frozen=True)
class Graph:
    id: str
    label: str
    nodes: dict[str, Node]
    edges: dict[str, Edge]


@dataclass
class RoomPath:
    room_id: str
    people: int
    exit_id: str | None  # None: no exit reachable
    path: list[str]  # node ids, room first
    edges: list[str]
    length_m: float | None


@dataclass
class EdgeLoad:
    edge_id: str
    people: int
    capacity_ppm: float
    minutes_to_clear: float


@dataclass
class Scenario:
    graph_id: str
    label: str
    unavailable: list[str]
    unknown_ids: list[str]  # asked to block, but not in the graph
    rooms: list[RoomPath]
    loads: list[EdgeLoad]  # busiest first
    stranded_people: int


def parse_graph(doc: dict) -> Graph:
    nodes = {n["id"]: Node(n["id"], n.get("label", n["id"]), n["kind"], int(n.get("people", 0))) for n in doc["nodes"]}
    edges = {e["id"]: Edge(e["id"], e["a"], e["b"], float(e["length_m"]), float(e["capacity_ppm"])) for e in doc["edges"]}
    for e in edges.values():
        if e.a not in nodes or e.b not in nodes or e.length_m <= 0 or e.capacity_ppm <= 0:
            raise ValueError(f"bad edge {e.id}")
    return Graph(id=doc["id"], label=doc.get("label", doc["id"]), nodes=nodes, edges=edges)


@lru_cache(maxsize=1)
def demo_graph() -> Graph:
    return parse_graph(json.loads(GRAPH_PATH.read_text(encoding="utf-8")))


def _shortest_to_exit(graph: Graph, start: str, blocked: set[str]) -> tuple[list[str], list[str], float] | None:
    adj: dict[str, list[tuple[str, Edge]]] = {}
    for e in graph.edges.values():
        if e.id in blocked or e.a in blocked or e.b in blocked:
            continue
        adj.setdefault(e.a, []).append((e.b, e))
        adj.setdefault(e.b, []).append((e.a, e))
    dist, prev = {start: 0.0}, {}
    heap = [(0.0, start)]
    while heap:
        d, node = heapq.heappop(heap)
        if d > dist[node]:
            continue
        if graph.nodes[node].kind == "exit":
            path, edges = [node], []
            while node in prev:
                node, edge = prev[node]
                path.append(node)
                edges.append(edge)
            return path[::-1], edges[::-1], d
        for nxt, e in sorted(adj.get(node, []), key=lambda x: x[1].id):  # deterministic ties
            nd = d + e.length_m
            if nd < dist.get(nxt, float("inf")):
                dist[nxt], prev[nxt] = nd, (node, e.id)
                heapq.heappush(heap, (nd, nxt))
    return None


def run(graph: Graph, unavailable: list[str]) -> Scenario:
    known = set(graph.nodes) | set(graph.edges)
    blocked = {u for u in unavailable if u in known}
    rooms, load = [], {e: 0 for e in graph.edges}
    for node in sorted(graph.nodes.values(), key=lambda n: n.id):
        if node.kind != "room":
            continue
        found = None if node.id in blocked else _shortest_to_exit(graph, node.id, blocked)
        if found is None:
            rooms.append(RoomPath(node.id, node.people, None, [], [], None))
            continue
        path, edges, length = found
        for e in edges:
            load[e] += node.people
        rooms.append(RoomPath(node.id, node.people, path[-1], path, edges, round(length, 1)))
    loads = sorted((EdgeLoad(e, n, graph.edges[e].capacity_ppm, round(n / graph.edges[e].capacity_ppm, 2))
                    for e, n in load.items() if n), key=lambda x: (-x.minutes_to_clear, x.edge_id))
    return Scenario(graph_id=graph.id, label=LABEL, unavailable=sorted(blocked),
                    unknown_ids=sorted(set(unavailable) - known), rooms=rooms, loads=loads,
                    stranded_people=sum(r.people for r in rooms if r.exit_id is None))
