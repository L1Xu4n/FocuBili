# Imported settings: current-value presentation

Base: `35a65bf6e5b130f91027308a473c590e36e1ff20`.
Isolated branch: `codex/v18-settings-picker`.
Review: PR63 discussion `4305752078`.

## Minimal image-capacity fix

Image-cache settings intentionally accept integer byte capacities from 0 through
512 MiB. The cache page previously passed that value to a dropdown containing
only 64/128/256/512 MiB. A legal custom value caused a debug assertion and had no
matching current-value display in release builds.

The page now adds exactly one current custom option when the value differs from
all four presets. It uses the existing byte formatter: for example `自定义 · 0 B`,
`自定义 · 1 B`, `自定义 · 128 B` and `自定义 · 100.0 MB`. Preset values retain
their existing labels/order, and a selected preset is never duplicated. Labels
are single-line with ellipsis for a narrow, enlarged-text picker. The existing
capacity-based widget key and setCapacity callback remain in use.

This changes only `cache_management_page.dart` in production. No import
validator, model, image-cache API, capacity domain, storage key or cache-clearing
behavior changed. No value is clamped to a preset.

## All 32 schema fields: read-only selector audit

The schema has 32 entries including image capacity, so the additional audit
covers the other 31. Source search included every Dropdown/DropdownMenu,
initialValue, Slider and SegmentedButton in `lib`; selectors for unrelated
account login, favorites, collection order and statistics are outside these
32 imported fields. No second missing-current-item assertion was identified.
This is a source/domain audit, not a claim that every possible input was run
through every UI.

Source abbreviations below resolve to:

- **P**: `lib/features/profile/personalization_settings_page.dart`.
- **C**: `lib/features/profile/cache_management_page.dart`.
- **S**: `lib/features/subscriptions/subscription_updates_page.dart`.
- **Playback**: `lib/models/playback_preferences.dart` and its preferences service.

| Imported key | Loader-compatible domain / presentation | Source evidence and result |
| --- | --- | --- |
| `app_behavior.account_read_only` | bool; switch | P:950, value is a bool; no item membership constraint. |
| `app_behavior.search_history_enabled` | bool; switch | P:959; no item membership constraint. |
| `app_behavior.watch_history_enabled` | bool; switch | P:970; no item membership constraint. |
| `app_behavior.wbi_signing_enabled` | bool; switch | P:1007; no item membership constraint. |
| `appearance.theme_mode` | light/dark/system | P:803: all three ThemeMode segments; AppThemeModeService decodes only these enum values. |
| `appearance.theme_color` | supported ARGB integer 1..0xFFFFFFFF, including non-preset colors | P:838/869: a Wrap of optional preset swatches, not a Dropdown; no required selected-item assertion. AppThemeModeController retains the loaded seed Color. No custom-color editor added. |
| `appearance.layout_orientation` | adaptive/portrait/landscape | P:615: all three AppLayoutMode dropdown items match the loader enum. |
| `app_update.check_on_start` | bool; switch | P:1166; no item membership constraint. |
| `app_update.ignored_release` | four-string identity JSON | AppUpdatePreferencesService/controller and `about_page.dart:303`: status and ignore/cancel actions, not a numeric or enum picker. |
| `windows_clipboard_link_detection.enabled` | bool; conditional switch | P:980; platform visibility does not impose item membership. |
| `focus_preferences.enable_do_not_disturb` | bool; conditional switch | P:1096; no item membership constraint. |
| `playback_preferences.enable_double_tap_seek` | bool; switch | P:1059; no item membership constraint. |
| `playback_preferences.speeds` | normalized 0.5..5, two-decimal rates, normal speed retained | P:1037 and `playback_speeds_dialog.dart:119`: chips are built dynamically from the loaded list, so custom 1.23x has its own item. Player speed popup also builds its entries from the loaded list. |
| `playback_preferences.long_press_speed` | 1..5 in 0.25 steps | P:541/547: SimpleDialog enumerates every quarter from 4 through 20; P:1054 displays the actual saved label. No Dropdown initialValue. |
| `playback_preferences.double_tap_regions` | left/right 0.1..0.45, height 0.4..1 | `double_tap_regions_page.dart`: gesture handles and percentage preview read the normalized regions; no fixed-item picker. |
| `playback_preferences.action_animation` | bool; switch | P:1078; no item membership constraint. |
| `playback_preferences.control_scale` | .8..2 in .05 steps | P:1018 and `player_control_size_page.dart:243`: Slider uses the same model min/max and 24 divisions; any imported valid step is in range. |
| `playback_preferences.show_note_time_markers` | bool; switch | P:1028; no item membership constraint. |
| `playback_preferences.subtitle_font_size` | integer-valued 12..36 | `player_subtitle_sheet.dart:195`: Slider min/max are the same model constants, with 24 divisions. |
| `playback_preferences.two_finger_video_transform` | bool; conditional switch | P:1087; no item membership constraint. |
| `playback_preferences.prefer_offline_cache` | bool | PlaybackPreferencesService retains the bool; there is no current settings selector bound to this field, so no Dropdown selection assertion. |
| `playback_preferences.wifi_default_quality` | PreferredPlaybackQuality ids 16/32/64/80/112/116/120 | P:693/704/723: loaded enum and dropdown items both use PreferredPlaybackQuality.values. |
| `playback_preferences.mobile_default_quality` | same quality enum | Same shared P builder; every loaded enum is an item. |
| `focubili_danmaku_preferences_v1` | bool flags, normalized keywords, finite in-range fractions; laneCount 1..24 | `player_overlay_coordinator.dart:748..924`: flags use switches/chips, keywords a TextFormField, numeric fields Sliders with the model's bounds. Finite fractional opacity/font size/etc need not equal a discrete item; Slider divisions govern interaction snapping and do not require membership. |
| `dashboard.layout.home` | order/hidden string lists | DashboardLayout.reconcile/visibleCards and DashboardLayoutService: card order/visibility data, not a selected scalar Dropdown. Unknown legacy ids do not become a missing current item. |
| `dashboard.layout.profile` | order/hidden string lists | Same layout model/service as home; no selected scalar Dropdown. |
| `windows_media_cache_capacity_bytes` | supportedMediaCacheBytes only | C:196/208 and MediaCacheStatus.fromPlatformMap/WindowsMediaCacheService.loadCapacityBytes: loader/import/picker share the five supported capacities. |
| `search.content_filter_v2` | bool learningOnly, integer minimum 0..2,000,000,000 | `search_content_filter_controls.dart:97`: exact numeric TextFormField plus a bounded nearest-preset slider index; a custom threshold is not used as an enum index or Dropdown value. |
| `subscriptions.enabled` | bool; switch | S:821; no item membership constraint. |
| `subscriptions.notifications_enabled` | bool; conditional switch | S:837; no item membership constraint. |
| `subscriptions.background_refresh_enabled` | bool; conditional switch | S:843; no item membership constraint. |
| `resource_cache.image_capacity_bytes` | integer bytes 0..512 MiB, including custom values | C:330/353/358: fixed by adding a unique current custom item while preserving four presets. |

All numeric ranges above describe the existing model and import contract; this
change does not redefine them.

## Red-to-green and persistence evidence

Executed on the Windows host with the installed Flutter SDK. All image status
inputs are synthetic; the persistence case uses only a newly created temporary
`focubili_images_v1` directory. Its UI adapter calls the real ImageResourceCache
setCapacity under WidgetTester.runAsync, then each remount reads a new actual
cache instance. No system cache, real account data, image download, application
startup or screenshot capture was used.

Before production changes:

```powershell
flutter test --no-pub --reporter expanded test/cache_management_custom_capacity_test.dart --name 'custom image capacity'
```

Result: **0 passed, 4 failed; exit 1**. Actual CacheManagementPage rendered with
0, 1, 128 and 104857600 bytes failed the framework's exactly-one-current-item
assertion. The tests did not merely instantiate an isolated Dropdown.

After the page fix:

```powershell
flutter test --no-pub --reporter expanded test/cache_management_custom_capacity_test.dart
```

Result: **11 passed, exit 0**: four custom-value cases, all four presets without
duplicates, one actual temporary-cache persistence test covering selection and
remount for every preset, and two 320px/200%-text cases which open the menu and
select a preset without overflow. No implicit mutation occurs when displaying a
custom value.

Combined targeted regressions:

```powershell
flutter test --no-pub --reporter expanded test/cache_management_custom_capacity_test.dart test/cache_management_page_test.dart test/settings_transfer_image_capacity_test.dart test/settings_transfer_model_ranges_test.dart test/settings_transfer_test.dart test/personalization_settings_page_test.dart test/player_control_size_test.dart test/playback_preferences_test.dart test/danmaku_preferences_test.dart test/app_theme_mode_service_test.dart
flutter analyze --no-pub lib/features/profile/cache_management_page.dart test/cache_management_custom_capacity_test.dart
dart format --output=none --set-exit-if-changed lib/features/profile/cache_management_page.dart test/cache_management_custom_capacity_test.dart
git diff --check
```

Results: **98 passed, exit 0**; scoped analyze **no issues, exit 0**. The existing
image-capacity import tests still accept and roundtrip zero, byte-sized custom
values and all presets through the actual runtime/cache service. Existing model
tests retain quarter-speed/5%-scale precision, finite Danmaku fractions and
custom-color compatibility. Final formatting: **2 files, 0 changes, exit 0**;
whitespace check: **exit 0**. No full-suite run, build, publication, push or PR
comment occurred.

Raw local logs are in `task-5/output/v18-settings-picker-*.log`; the read-only
selector-source inventory is `task-5/output/v18-settings-picker-selectors.txt`.
