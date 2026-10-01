"""WebSocket liveness contract for resident and dashboard clients."""

from datetime import datetime

from fastapi.testclient import TestClient

from app.main import app
from app.security import create_access_token


def test_incident_socket_sends_hello_as_its_first_frame() -> None:
    """A client must receive proof of a live server before claiming it is live."""
    token = create_access_token("resident-1", "ana", "resident")

    with TestClient(app) as client:
        with client.websocket_connect(
            f"/api/v1/ws/incidents?building_id=bld_007&token={token}"
        ) as socket:
            frame = socket.receive_json()

    assert frame["type"] == "hello"
    assert datetime.fromisoformat(frame["ts"].replace("Z", "+00:00")).utcoffset() is not None
