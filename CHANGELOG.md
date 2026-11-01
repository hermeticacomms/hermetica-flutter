## 0.1.0

- First release: `Hermetica.initialize`, `identify`, `track`, `screen`, `setProfileAttributes`, `reset`.
- Persisted anonymous id and an on-device event queue with batching, retry with backoff, and a flush when the app is paused.
- `setTrackingOptOut`, remembered across launches.
- Push: `registerPushToken`, `unregisterPushToken`, `handlePushOpened` with a deep-link callback.
- In-app messages: `fetchInAppMessages`, `reportInAppEvent`, and the `HermeticaInAppHost` widget (modal, banner, bottom sheet, fullscreen) with a builder override.
- Geofences: `getGeofences` and `reportGeofenceEvent`.
