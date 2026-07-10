# Flux Water Volume Backend

Python FastAPI server for top-down bottle scanning: detects bottle rim + water surface, integrates against the calibrated bottle profile.

## Setup

```bash
cd quick-oppenheimer
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

Find your Mac IP (System Settings → Wi-Fi → Details) and set it in the Flux app Settings → Backend Server.

## API

`POST /api/v1/calculate_water_volume` (multipart/form-data)

| Field | Description |
|-------|-------------|
| `image` | JPEG top-down photo |
| `bottle_height` | cm |
| `bottle_volume` | ml |
| `opening_diameter_cm` | cm |
| `profile_json` | `{"heights_cm": [...], "radii_cm": [...]}` |
| `last_remaining_ml` | previous scan remaining (for consumed delta) |
| `calibration_outer_radius_px` | optional baseline |

Response includes `remaining_volume_ml`, `consumed_volume_ml`, `water_height_cm`, `outer_radius_px`, `debug_image_base64`.
