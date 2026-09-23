@echo off
echo ===================================================
echo               Starting Canary Stack
echo ===================================================

echo [1/3] Starting Backend in a new window...
start "Canary Backend" cmd /k "cd /d %~dp0backend && set CANARY_DATABASE_URL=sqlite+aiosqlite:///./canary.db && set CANARY_MQTT_ENABLED=false && set CANARY_JWT_SECRET=local-dev-secret-change-me-please-1234 && call .venv\Scripts\activate.bat && uvicorn app.main:app --reload --port 8000"

echo [2/3] Starting Web Dashboard in a new window...
start "Canary Web Dashboard" cmd /k "cd /d %~dp0web && npm run dev"

echo [3/3] Starting Mobile App in Chrome in a new window...
start "Canary Mobile App" cmd /k "cd /d %~dp0mobile && flutter run -d chrome --dart-define=CANARY_API=http://localhost:8000"

echo ===================================================
echo Canary processes have been spawned in separate windows!
echo ===================================================

