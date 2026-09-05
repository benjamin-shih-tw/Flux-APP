# Flux v2 MVP

Flux is an iOS water-tracking app with a Python FastAPI backend.

This MVP focuses on opaque bottles:

- the iOS app checks IMU alignment before capture
- the camera takes a top-down bottle photo
- the backend estimates remaining water from a bottle profile and a single frame
- acoustic and fusion hooks are present as stubs for the next iteration

## Repo layout

- `Flux/Flux/` - Swift app source
- `Flux/quick-oppenheimer/` - FastAPI backend and demo test

## Run the backend

```bash
cd Flux/quick-oppenheimer
python3 -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

## Run the iOS app

Open `Flux/Flux.xcodeproj` in Xcode, then set the backend URL in Settings to your machine's LAN address, for example:

```text
http://10.0.0.9:8000
```

## Test the backend

```bash
cd Flux/quick-oppenheimer
pytest -q
```

The demo test creates a synthetic bottle image, posts it to the API, and checks the MVP response fields.
