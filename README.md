# Tropa

Offline GPS tracker for walking and cycling (Flutter, Android; iOS in progress).
Офлайн GPS-трекер ходьбы и велопрогулок.

- **Reliable recording.** A native Android foreground service writes the track, so the recording survives the app being closed or killed. Gaps are healed on display; the raw points are never altered.
- **Fully offline.** Recording, statistics and maps work without internet. Maps are downloaded by region (OpenStreetMap data in PMTiles format).
- **Private.** No account, no server. Your tracks stay on the phone.
- **Modes.** Walking, cycling, car, mixed. Auto-record (24/7) starts a walk by itself when you start moving.
- **Routes.** Import GPX, turn-by-turn voice navigation, off-route alerts, "wait at the start".
- **Posters.** Turn a walk into a shareable picture (speed or relief colouring, photo notes, weather, elevation profile).
- Russian and English interface, km or miles.

## Install (Android)

Download `Tropa-<version>.apk` from the [Releases](https://github.com/oneup1689/Tropa/releases) page and open it on the phone
(allow installing from this source when asked). Updates are signed with the same key, so a new version installs over the old one.
Release signing certificate SHA-256 is published in each release's notes.

## Build

```
flutter pub get
flutter test
flutter build apk --release
```

Needs Flutter (see `pubspec.yaml`) and the Android SDK. Without `android/key.properties` the release build is signed with the debug key.

## Privacy

See [PRIVACY.md](PRIVACY.md). Short version: coordinates stay on the device; only optional poster features
(weather, elevation, place name) and map downloads use the internet.

## License

[GPL-3.0-or-later](LICENSE). Map data © OpenStreetMap contributors (ODbL), styling by Protomaps.
Fonts Rubik and Unbounded are under the SIL Open Font License.
