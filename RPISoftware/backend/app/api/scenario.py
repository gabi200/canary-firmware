"""Evacuation what-if (app.scenario.evacuation), staff only: system_admin, hoa_manager, technician.
Stateless: it reads the simulated graph file and writes nothing."""

from __future__ import annotations

from fastapi import APIRouter, Depends

from app.api.admin import Scope, staff_scope
from app.scenario import evacuation
from app.schemas import ScenarioEdgeOut, ScenarioIn, ScenarioLoadOut, ScenarioNodeOut, ScenarioOut, ScenarioRoomOut

router = APIRouter(prefix="/api/v1/scenarios", tags=["scenarios"])


@router.post("/evacuation", response_model=ScenarioOut)
async def evacuation_what_if(body: ScenarioIn, _: Scope = Depends(staff_scope)) -> ScenarioOut:
    graph = evacuation.demo_graph()
    result = evacuation.run(graph, body.unavailable)
    return ScenarioOut(
        graph_id=graph.id, graph_label=graph.label, label=result.label,
        nodes=[ScenarioNodeOut.model_validate(n) for n in graph.nodes.values()],
        edges=[ScenarioEdgeOut.model_validate(e) for e in graph.edges.values()],
        unavailable=result.unavailable, unknown_ids=result.unknown_ids,
        rooms=[ScenarioRoomOut.model_validate(r) for r in result.rooms],
        loads=[ScenarioLoadOut.model_validate(x) for x in result.loads],
        stranded_people=result.stranded_people,
    )
