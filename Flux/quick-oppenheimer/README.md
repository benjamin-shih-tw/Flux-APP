# Flux Water Volume Backend

This folder is the MVP FastAPI service for Flux v2.

It keeps the existing app/backend architecture, but changes the measurement path to:

1. iOS checks IMU alignment before capture.
2. The phone captures a top-down bottle image.
3. The backend estimates remaining volume from a calibrated bottle profile and a single frame.
4. Acoustic sensing is kept as a stub interface for the next version.

## Setup

```bash
cd quick-oppenheimer
python3 -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

## Run

```bash
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

Then set the backend URL in the iOS app to your machine's LAN address, for example:

```text
http://10.0.0.9:8000
```

## API

Preferred endpoint:

`POST /api/v2/estimate_water_volume`

Legacy compatibility endpoint:

`POST /api/v1/calculate_water_volume`

Multipart form fields:

| Field | Description |
|-------|-------------|
| `image` | JPEG top-down photo |
| `bottle_height_cm` | Bottle height in cm |
| `bottle_volume_ml` | Bottle capacity in ml |
| `opening_diameter_cm` | Bottle opening diameter in cm |
| `profile_json` | `{"heights_cm": [...], "radii_cm": [...]}` |
| `last_remaining_ml` | Previous remaining amount, used for consumed delta |
| `calibration_outer_radius_px` | One-time rim calibration baseline in pixels |
| `imu_alignment_score` | 0-1 alignment score from the iOS IMU check |

Response fields:

| Field | Description |
|-------|-------------|
| `remaining_volume_ml` | Estimated remaining water in ml |
| `water_depth_cm` | Estimated depth from the opening down to the water surface |
| `water_height_cm` | Legacy compatibility field for the surface height reference |
| `confidence` | 0-1 confidence score |
| `method_used` | Which estimator path produced the result |
| `debug_image_base64` | JPEG overlay with rim, surface, confidence, and method |

## Test

Run the synthetic demo test:

```bash
pytest -q
```

The test posts a generated bottle image to the API and checks that the response contains the MVP fields.
