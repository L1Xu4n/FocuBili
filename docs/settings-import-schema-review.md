# Settings import schema review

Base: `01250806d954fa360061e41a0580b31d8ae5dbb9`, including the existing search
maximum fix `bdc9470`. This is a 1.8-only patch. Product changes are confined to
`SettingsTransferService` and extracting the theme loader's existing color
predicate into `AppThemeModeService.isSupportedColorValue`. No image-cache
validation, account storage, native scheduler, release workflow or old test was
modified. The separate image-capacity fix must still be integrated by its owner.

## Confirmed defects and reproduced consequences

1. The generic Danmaku bool/num/List check accepted `laneCount: 1e309`.
   Dart JSON decodes it to infinity; the real model's `num.toInt()` throws and
   `DanmakuPreferencesService.load()` returns the entire default configuration.
   Enabled state, font, opacity and blocked keywords all disappear from the
   loaded result after an apparently successful import. `blockedKeywords: false`
   was also accepted and silently removed blocking. Known fields now use the
   model's actual serialized types and finite numerical domain.
2. `importSettings` validated a caller-owned Map/List, then awaited preferences
   while still retaining those mutable objects. A synthetic caller replacing a
   validated playback bool with a String during that await produced a successful
   String write and a real `PlaybackPreferencesService.load()` TypeError. Changing
   a parsed speeds list in the same window silently removed a selected rate.
   The confirmed Map and its primitive-string list payloads are now copied before
   the queue/first await. Validation still fails through the returned Future and
   completes for every value before any preferences/runtime read or write.
3. Generic nonnegative integers/0..100 decimals also accepted actual loader
   fallbacks/clamps: speed `0.25` was dropped and `1.234` rounded to `1.23`, long
   press `5.1` became `5`, scale `0.7` became `0.8`, subtitle `37` became `36`,
   qualities `1`/`121` became `64`, color `0x100000000` became the default blue,
   invalid regions became `{0.1, 0.45, 0.4}`, and media capacity `1` became 512MiB.
   The importer now checks the existing normalizers, enum, color predicate and
   media-capacity constant rather than introducing a separate UI preset list.

## Every top-level schema key

All 32 keys below retain their existing outer limits: supported primitive type,
signed-64-bit nonnegative integers, finite decimals, bounded strings/lists/JSON,
2MiB parsed file and unknown-top-level-key rejection. `B` is the parameterized
15-key bool test; `R` is `settings_transfer_model_ranges_test.dart`; `D` is
`review_settings_import_schema_test.dart`; `S` is the unchanged search-threshold
suite; `T` is the unchanged settings/runtime/native suite.

| Key | Actual loader/domain | Import validation and evidence |
| --- | --- | --- |
| `app_behavior.account_read_only` | `AppBehaviorPreferencesService.loadAccountReadOnly`; bool, missing defaults true | bool; B tests false/true and rejects num/String/List |
| `app_behavior.search_history_enabled` | `loadSearchHistoryEnabled`; bool, missing true | bool; B |
| `app_behavior.watch_history_enabled` | `loadWatchHistoryEnabled`; bool, missing true | bool; B |
| `app_behavior.wbi_signing_enabled` | `loadWbiSigningEnabled`; bool, missing false | bool; B |
| `appearance.theme_mode` | `AppThemeModeService.load`; light/dark/system | Existing enum whitelist; T and theme suite |
| `appearance.theme_color` | `loadColor`; integer 1..0xFFFFFFFF, otherwise default | Shared `isSupportedColorValue`; R both endpoints, default, zero/max+1 |
| `appearance.layout_orientation` | `AppLayoutPreferencesService.load`; adaptive/portrait/landscape | Existing enum whitelist; T invalid orientation |
| `app_update.check_on_start` | `AppUpdatePreferencesService.loadEnabled`; bool, missing true | bool; B |
| `app_update.ignored_release` | `loadIgnoredUpdate`; opaque encoded four-string update identity | Existing JSON list length 4, each String <=120; outer text <=512; T roundtrip and malformed object |
| `windows_clipboard_link_detection.enabled` | `WindowsClipboardLinkPreferencesService.loadEnabled`; bool, missing false | bool; B |
| `focus_preferences.enable_do_not_disturb` | `FocusPreferencesService.load`; bool, missing false | bool; B |
| `playback_preferences.enable_double_tap_seek` | `PlaybackPreferencesService.load`; bool, missing true | bool; B, D direct mutation TypeError regression |
| `playback_preferences.speeds` | `PlaybackPreferences.normalizeSpeeds`; finite 0.5..5, two-decimal rate precision | Every parsed rate must survive the shared normalizer; R lower/upper/off-grid/nonfinite; D list mutation |
| `playback_preferences.long_press_speed` | `normalizeLongPressPlaybackSpeed`; 1..5 in 0.25 steps | Exact numerical agreement with the existing normalizer; R endpoints, outside and off-step |
| `playback_preferences.double_tap_regions` | `DoubleTapRegions.fromMap/copyWith`; left/right 0.1..0.45, height 0.4..1 | Existing finite-num structure plus equality with normalized model values; R all boundaries and outside |
| `playback_preferences.action_animation` | Playback loader bool, missing true | bool; B and real playback load |
| `playback_preferences.control_scale` | `normalizeControlScale`; 0.8..2 in 0.05 steps | Shared normalizer; R endpoints, outside and off-step |
| `playback_preferences.show_note_time_markers` | Playback loader bool, missing true | bool; B and real playback load |
| `playback_preferences.subtitle_font_size` | `normalizeSubtitleFontSize`; 12..36 whole sizes | Shared normalizer; R endpoints, outside and fractional rounding case |
| `playback_preferences.two_finger_video_transform` | Playback loader bool, missing true | bool; B and real playback load |
| `playback_preferences.prefer_offline_cache` | Playback loader bool, missing false | bool; B and real playback load |
| `playback_preferences.wifi_default_quality` | `PreferredPlaybackQuality.fromId`; 16/32/64/80/112/116/120 | Known enum ID required; R every valid ID and invalid IDs |
| `playback_preferences.mobile_default_quality` | Same enum independently loaded | Same enum check; R every valid ID and invalid IDs |
| `focubili_danmaku_preferences_v1` | `DanmakuPreferencesService.load/fromJson`; detailed below | Model-derived known-field types, finite numbers and no range clamping; D/R |
| `dashboard.layout.home` | `DashboardLayoutService.load` then `DashboardLayout.reconcile` | Existing order/hidden String-list structure, <=100 items and <=100 chars/item; R both layouts at 100, over-limit, wrong type and semantic reconciliation |
| `dashboard.layout.profile` | Same loader with independent storage ID | Same structure; R |
| `windows_media_cache_capacity_bytes` | `WindowsMediaCacheService.loadCapacityBytes`; `supportedMediaCacheBytes` | Reuses that exact existing list: 128/256/512/1024/2048MiB. At this base 0 is NOT an off value: loader returns 512MiB. R tests every valid value and rejects 0/1/huge |
| `search.content_filter_v2` | `SearchContentFilterService.load`; learningOnly bool, minimum integer 0..`SearchContentFilter.maximumPlayCount` | Existing bdc9470 validation retained; S 0/max roundtrip, max+1, negative and wrong types |
| `subscriptions.enabled` | `DeviceSettingsRuntimeAdapter` through authoritative `SubscriptionService`; bool | bool; B synthetic adapter and T real service with synthetic storage/native channel |
| `subscriptions.notifications_enabled` | Same authoritative service; bool | bool; B/T |
| `subscriptions.background_refresh_enabled` | Same authoritative service/native generation; bool | bool; B/T Windows/iOS mock channels |
| `resource_cache.image_capacity_bytes` | `DeviceSettingsRuntimeAdapter` then `ImageResourceCache.setCapacity` | Separate owner's upper-bound P2, not changed or claimed closed by this patch. Preserve its valid zero/sub-preset range; integrate that patch before release |

## Danmaku nested fields and deliberate normalization

The serialized template comes from `DanmakuPreferences().toJson()`, so the importer
shares the model's field types. All five booleans (`enabled`, `showScrolling`,
`showTop`, `showBottom`, `mergeRepeated`) require bool. `blockedKeywords` requires
a list of Strings. The six numerical fields must be finite and must not be
clamped by the real model:

| Field | Existing model domain | Compatibility preserved |
| --- | --- | --- |
| `opacity` | `minOpacity`..`maxOpacity` (0.2..1) | finite fractional values |
| `fontSize` | `minFontSize`..`maxFontSize` (10..30) | e.g. 15.5 is legal, not restricted to UI buttons |
| `laneCount` | existing finite-num `toInt`, then 1..24 | 12.0, 12.5 ->12 and 24.9 ->24 remain legal; only conversion results requiring range clamping are rejected |
| `scrollDurationSeconds` | `minScrollDurationSeconds`..`maxScrollDurationSeconds` (3..20) | finite fractional values |
| `displayArea` | `minDisplayArea`..`maxDisplayArea` (0.25..1) | finite fractional values |
| `strokeWidth` | `minStrokeWidth`..`maxStrokeWidth` (0..3) | zero and finite fractional values |

Partial old Danmaku documents still receive missing-field defaults. Existing
keyword trimming/case-insensitive deduplication and the prior primitive extension
field policy are retained. Speed sorting, duplicate removal, normal-speed
insertion, empty speed lists and String spellings such as `1` versus `1.0` are
accepted; they are intentional list semantics rather than a rejected range
change. Layout reconciliation likewise retains unknown old IDs, removes duplicate
or blank IDs and restores required cards. The importer does not replace these
policies with a current-UI-only preset/ID list.

## Commands and observed results

Windows host, existing Flutter 3.44.6/Dart 3.12.2, cached dependencies. Every new
test uses mock SharedPreferences, fake runtime settings, synthetic native channels
or temporary test files. No real sessions, account data, login export, application
installation, macOS/iOS device, network writes, SDK source edits or lock-file
manipulation were involved. Flutter used its normal SDK lock with sufficient
execution permissions; `--no-pub` and `--no-version-check` prevented resolution
or SDK refresh.

The actual launcher was the existing SDK's `bin/cache/dart-sdk/bin/dart.exe`
running `bin/cache/flutter_tools.snapshot` with `FLUTTER_ROOT` set to that SDK;
the command listings below show the equivalent Flutter tool arguments. Direct
`dart analyze` of the two production files and two new tests reported **No issues
found**; `dart format --output=none --set-exit-if-changed` reported **0 changed**;
`git diff --check` passed.

The exact pristine detached baseline is retained at
`task-5/v18-settings-import-baseline-red`, HEAD `0125080`, with only copies of the
two new test files untracked. Product source is unchanged (`git diff --quiet`
against the base succeeds). The same 25 tests there produced **5 passed / 20
failed, exit 1**. This includes direct/parsed Danmaku fallback, actual playback
TypeError, mutable speed loss, and all ten loader-changing range examples.

```text
flutter --no-version-check test --no-pub \
  test/review_settings_import_schema_test.dart \
  test/settings_transfer_model_ranges_test.dart --reporter expanded
```

The fixed independent worktree ran this combination with **72 passed, exit 0**:

```text
flutter --no-version-check test --no-pub \
  test/review_settings_import_schema_test.dart \
  test/settings_transfer_model_ranges_test.dart \
  test/settings_transfer_test.dart \
  test/settings_transfer_search_threshold_test.dart \
  test/settings_runtime_adapter_test.dart \
  test/settings_native_subscription_integration_test.dart \
  test/data_transfer_file_service_test.dart \
  test/danmaku_preferences_test.dart \
  test/playback_preferences_test.dart \
  test/app_theme_mode_service_test.dart --reporter expanded
```

The two unchanged settings transaction tests still verify rollback of an earlier
regular write and of partially written runtime settings. The new tests verify all
values are rejected before preferences/runtime access, plus complete valid export
roundtrips, missing old Danmaku fields, every quality/capacity enum, numerical
boundaries and deliberate normalization. Windows/iOS native tests are channel
simulations on Windows, not device validation. No full-suite or native app build
was run for this patch.
