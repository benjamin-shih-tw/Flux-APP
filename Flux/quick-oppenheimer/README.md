# Flux Water Volume Backend

This folder is the MVP FastAPI service for Flux v2.

It keeps the existing app/backend architecture, and measures the water level with:

1. iOS checks IMU alignment before capture.
2. The phone captures a top-down bottle image and a mono PCM16 recording from its built-in speaker and bottom microphone.
3. The backend uses the recorded direct chirp as the time reference, detects at least three repeatable water echoes, and converts the median depth with the calibrated bottle profile.
4. A low-frequency sweep checks the bottle resonance when the profile contains a narrow neck and neck length.
5. Clear image evidence is preferred, opaque or reflective bottles can use acoustic evidence, and a large image/audio disagreement asks for a retake.

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
| `camera_focal_length_px` | Camera focal length in the uploaded image coordinate system |
| `phone_to_rim_cm` | Optional measured phone-to-bottle-rim distance; focal length plus rim detection can derive it |
| `audio` | Optional 1.8–3 second mono PCM16 WAV containing the five chirps and low sweep |
| `acoustic_metadata_json` | Probe version, built-in route, speaker/microphone offsets, direct path and optional neck length |
| `seconds_since_last_scan` | Age of the previous result for sudden-change rejection |

Response fields:

| Field | Description |
|-------|-------------|
| `remaining_volume_ml` | Estimated remaining water in ml |
| `water_depth_cm` | Estimated depth from the opening down to the water surface |
| `water_height_cm` | Legacy compatibility field for the surface height reference |
| `confidence` | 0-1 confidence score |
| `method_used` | Which estimator path produced the result |
| `debug_image_base64` | JPEG overlay with rim, surface, confidence, and method |

When audio is supplied, `acoustic_estimate` also reports echo SNR, accepted repeat count, delays, resonance frequency and resonance cross-check volume. A response with `status: "retake"` contains the reason in `message` and does not return a numeric result.

## Test

Run the synthetic demo test:

```bash
pytest -q
```

The test posts a generated bottle image to the API and checks that the response contains the MVP fields.

The iOS capture currently sends the iPhone 15 wide-camera focal-length and built-in bottom-port geometry constants. These values should be recalibrated when supporting another phone model; they are not measurements from an external accessory.
