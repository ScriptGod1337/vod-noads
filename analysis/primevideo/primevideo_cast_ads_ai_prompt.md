# AI Agent Prompt: Analyze "Cast To Device" Ad Playback In Prime Video

You are an AI reverse-engineering agent working in a local workspace that contains:
- Prime Video APKs (`.apk`)
- optional decompiled outputs (apktool/baksmali smali trees)
- patch scripts for on-device APK patching

## Goal
Diagnose why "Cast to device" playback still shows advertisements when local playback is patched to skip server-inserted ad breaks.

Determine (with evidence) whether the ads shown during casting are:
1. server-side inserted into the streamed manifest/segments,
2. rendered/controlled by a cast receiver application on the target device,
3. controlled by client-side code inside the Android APK (phone/tablet) during cast sessions.

If (3) is true, identify the responsible code paths and the minimal hook points. Do **not** implement or provide instructions to bypass ads for a commercial service; focus on analysis and feasibility only.

## Key Insight (starting hypothesis)
"Casting" often changes the player stack:
- local playback uses the app’s in-process player + local state machine
- cast playback may use a **remote player / receiver**; ads can be driven by the receiver or by server manifests.

That means a patch that hooks:
- `ServerInsertedAdBreakState.enter(Lcom/amazon/avod/fsm/Trigger;)V`
can be correct for local playback, yet irrelevant for cast playback.

## Data Collection (must do first)
1. Capture runtime logs around casting.
   - Collect logcat from the Android device initiating cast:
     - the cast session start
     - play start on receiver
     - the moment an ad appears
   - Extract stack traces, warnings, and tags containing `cast`, `chromecast`, `gcast`, `mediarouter`, `remote`, `receiver`, `ads`, `adbreak`, `cuepoint`.
2. Identify the cast target type:
   - Chromecast / Google Cast
   - Fire TV / Amazon cast variant
   - DLNA / UPnP
   - "Casting" to another Android device using Amazon’s own protocol

The protocol determines where ads are controlled (client vs receiver vs server).

## Static Analysis (APK)
### Step A: Find cast subsystem entry points
Search (JADX source view or smali) for:
- packages: `com/amazon/*cast*`, `*gcast*`, `*chromecast*`, `androidx/mediarouter/*`
- classes: `CastContext`, `CastSession`, `RemoteMediaClient`, `MediaRouter`, `MediaRouteSelector`
- keywords: `receiver`, `loadMedia`, `MediaLoadRequestData`, `queue`, `playbackRate`, `seek`, `adBreak`, `cue`, `vmaps`, `vasts`

Deliverable: a short list of primary cast classes and their top-level responsibilities.

### Step B: Determine which player is used during cast sessions
Goal: find the boundary where the app switches from local `VideoPlayer`/state-machine to a remote control object.

Look for:
- a "player facade" interface implemented by both local player and cast/remote player
- conditional branches keyed on `isCasting`, `isRemotePlayback`, `playbackMode`, `routeType`
- code that wraps/forwards:
  - `seekTo(...)`
  - `pause/resume`
  - `load(...)`

Deliverable: call graph sketch from UI action "cast" -> remote playback start.

### Step C: Identify whether "ad breaks" exist as explicit objects in the cast path
In local playback you saw:
- `AdBreakTrigger`, `ServerInsertedAdBreakState`, `NO_MORE_ADS_SKIP_TRANSITION`

Check whether cast playback references the same ad state-machine classes, or entirely different ones:
- If the same ad state-machine is used but calls are on a different player type, then the skip logic might be portable.
- If the cast path never touches these classes, the existing patch is irrelevant for casting.

Deliverable: evidence-based answer:
- "Cast path uses / does not use `com.amazon.avod.media.ads.internal.*` state machine".

## Network/Protocol Analysis (high-level, no bypass)
If possible, observe the messages sent during cast session initialization:
- payload sent to the receiver (often JSON)
- whether the payload includes:
  - manifest URL
  - ad metadata
  - "ad-supported" flags
  - cuepoints/ad markers

The goal is to classify ads as "server/receiver driven" vs "client driven".

## Feasibility Assessment (what can be patched, in theory)
Answer these questions explicitly:
1. Are ads present in the video manifest/segments (server-side) for cast playback?
   - If yes: patching the Android APK likely cannot remove them; this is controlled by the service.
2. Is a receiver app rendering the ad experience independently of the Android APK?
   - If yes: patching the Android APK won’t remove receiver-side ads; you would need to change receiver behavior (out of scope).
3. Does the Android APK itself instruct the receiver to play ads or block seeking during ad breaks?
   - If yes: in theory there may be client-side hooks, but you must stop at identifying them and assessing risk.

Deliverable: a table mapping each possibility to "evidence" and "patch feasibility".

## Output Format (required)
Produce:
- **Findings**: bullet list of confirmed facts with file/class references
- **Cast Pipeline Map**: minimal diagram or step list (component -> component)
- **Ad Control Location**: server vs receiver vs client (with confidence level)
- **Theoretical Patch Points** (if any): method/class names only, no patch code
- **Risks**: why changing cast playback can break sessions, DRM, or account integrity

---

## Current Evidence (Static Analysis, Prime Video 3.0.438.2347)

### Findings
- Prime Video has an explicit Google Cast route type: `com/amazon/messaging/common/remotedevice/Route` includes `GCAST` (`"gcast"`) alongside `DIAL`, `MATTER`, `TCOMM`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes8/com/amazon/messaging/common/remotedevice/Route.smali`.)
- Cast playback uses a distinct “second screen / companion mode” player stack:
  - `SecondScreenVideoClientPresentation` is a `VideoClientPresentation` backed by `SecondScreenVideoPlayer`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes7/com/amazon/avod/playback/secondscreen/SecondScreenVideoClientPresentation.smali`.)
  - `SecondScreenVideoPlayer.startPlayback(VideoSpecification)` forwards the cast start to `SecondScreenPlaybackControlStateMachine.sendStart(...)` and passes a `PlaybackEnvelope` to the remote path. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes9/com/amazon/avod/secondscreen/playback/player/SecondScreenVideoPlayer.smali`.)
- Companion/cast mode does **not** use the local ad-plan/state-machine surfaces:
  - `SecondScreenVideoClientPresentation.getAdPlan()` returns `EmptyAdPlan`.
  - `SecondScreenVideoClientPresentation.addAdPlanUpdateListener(...)` returns `false`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes7/com/amazon/avod/playback/secondscreen/SecondScreenVideoClientPresentation.smali`.)
- Ad-break lifecycle during cast is driven by **remote status / subevents**, not the local `ServerInsertedAdBreakState` state machine:
  - `AdBreakSubEventProcessor` consumes `PlaybackAdBreakSubEvent` and notifies listeners `onBeginAdBreak(...)` / `onEndAdBreak(...)`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes9/com/amazon/avod/secondscreen/remote/ad/AdBreakSubEventProcessor.smali`.)
  - `PlaybackAdBreakSubEvent` is JSON-deserializable (`fromJsonObject`) and includes fields like `id`, `duration`, `startTime`, `type`, `isSkippable`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/event/internal/PlaybackAdBreakSubEvent.smali`.)
- For Google Cast specifically, the app reads ad-break state from Cast receiver metadata:
  - `GCastStatusPublisher.createAdBreakSubEvent(MediaStatus)` uses `MediaStatus.getCurrentAdBreak()`, `MediaStatus.getAdBreakStatus()`, and builds `PlaybackAdBreakSubEvent` with event type `AD_START`/`AD_END`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/gcast/GCastStatusPublisher.smali`.)
  - `GCastStatusPublisher.createAdPlanSubEvent(MediaStatus)` iterates `MediaInfo.getAdBreaks()` to create a `PlaybackAdPlanSubEvent` containing `AdBreakItem`s. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/gcast/GCastStatusPublisher.smali`.)
- For Google Cast session start, the phone loads media into the receiver with a `PlaybackEnvelope` payload:
  - `GCastRemoteDevice.start(...)` posts work that calls `GCastLoader.Companion.load(...)` and starts `GCastStatusPublisher`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/GCastRemoteDevice.smali`.)
  - `GCastLoader.Companion.getMediaLoadOptionsCustomData(...)` builds JSON including `"deviceId"` and `"playbackEnvelope"` (containing `assetId`, `correlationId`, `envelope`, `expiration`). (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/gcast/GCastLoader$Companion.smali` and `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/internal/PlaybackEnvelopeMetadata.smali`.)

### Cast Pipeline Map (Observed in Code)
1. UI enters companion/cast mode -> `SecondScreenVideoClientPresentation`
2. `SecondScreenVideoPlayer.startPlayback(VideoSpecification)`
3. `SecondScreenPlaybackControlStateMachine.sendStart(titleId, timecodeMs, videoMaterialType, playbackEnvelope)`
4. For `Route.GCAST` devices: `GCastRemoteDevice.start(...)` -> `GCastLoader.Companion.load(...)` -> Google Cast `RemoteMediaClient.load(...)`
5. Receiver plays content; phone monitors receiver state via `GCastStatusPublisher`
6. Ad-break status flows back as `PlaybackAdBreakSubEvent` -> `AdBreakSubEventProcessor` -> `onBeginAdBreak/onEndAdBreak` callbacks

### Ad Control Location (Evidence-Based)
- **Receiver-controlled (High confidence for Google Cast):** The initiating phone reads ad-break start/end and the full ad-break list from Google Cast receiver metadata (`MediaStatus.getCurrentAdBreak()`, `MediaInfo.getAdBreaks()`), meaning the receiver is the authoritative source of “ad break” state during casting. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/gcast/GCastStatusPublisher.smali`.)
- **Server-side manifest/segments (Medium confidence):** The phone sends a `PlaybackEnvelope` to the receiver during `load(...)`, implying the receiver independently fetches/plays the stream described by the envelope (and therefore whatever ad policy is encoded upstream). Confirming SSAI vs receiver-side insertion requires network/receiver inspection. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/gcast/GCastLoader$Companion.smali` and `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/internal/PlaybackEnvelopeMetadata.smali`.)
- **Client-side ad insertion/control (Low confidence):** The cast path does not appear to run the local `com.amazon.avod.media.ads.internal.*` playback state machine; companion mode surfaces an `EmptyAdPlan` and consumes remote ad-break subevents instead. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes7/com/amazon/avod/playback/secondscreen/SecondScreenVideoClientPresentation.smali` and `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes9/com/amazon/avod/secondscreen/remote/ad/AdBreakSubEventProcessor.smali`.)

### Key Evidence Touchpoints (Non-Bypass)
For classification/diagnosis (server vs receiver vs phone), the most relevant boundaries are:
- Receiver load boundary (phone -> receiver): `GCastLoader$Companion.getMediaLoadOptionsCustomData(...)` builds the receiver `customData` including a `playbackEnvelope`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/gcast/GCastLoader$Companion.smali`.)
- Receiver ad-break authority (receiver -> phone): `GCastStatusPublisher` derives `PlaybackAdBreakSubEvent` / `PlaybackAdPlanSubEvent` from Cast receiver metadata. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/gcast/GCastStatusPublisher.smali`.)

### Feasibility Table (Phone APK Patching Only)
| Hypothesis | Evidence in APK | Feasibility if true |
|---|---|---|
| (1) Ads are in manifest/segments for cast | `PlaybackEnvelope` is sent to receiver; receiver provides ad-break timeline back via Cast APIs | Low: phone patching won’t change what receiver downloads/plays |
| (2) Receiver renders/controls ads | Phone reads ad breaks from receiver (`MediaStatus.getCurrentAdBreak`, `MediaInfo.getAdBreaks`) | Low: phone patching can at most affect UI/controls on the phone |
| (3) Phone instructs receiver to play ads | No obvious “ads enabled” flags in `GCastLoader` customData; cast path uses remote subevents instead of local ad SM | Unclear/low: would require evidence of explicit ad directives in the load payload |

### Risks
- Remote playback stacks are state-machine driven (`SecondScreenPlaybackControlStateMachine`) and sensitive to timing; altering triggers can break session negotiation, playback start, or recovery.
- DRM and entitlement are likely encapsulated in `PlaybackEnvelope`; tampering with payloads can cause playback failures or account/device integrity flags.
- Cast ad-break metadata is receiver-authoritative; suppressing it locally risks desync (UI believes “no ad break” while receiver is in an ad break) and can cause bad seeks/controls.

---

## Fire TV / Fire OS Casting (Fire TV Cube 2nd Gen) Evidence (Route.TCOMM)

### Findings
- Prime Video supports non-Google-cast “second screen” routes; `Route` includes `TCOMM` (`"tcomm"`) alongside `GCAST`, `MATTER`, `DIAL`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes8/com/amazon/messaging/common/remotedevice/Route.smali`.)
- Second-screen route discovery includes a TCOMM category. `SecondScreenMediaRoute.getSecondScreenMediaRouteSelector(...)` adds `TCommControlCategory` (and `MatterControlCategory`, `DialControlCategory`, plus optional GCast). (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes9/com/amazon/avod/secondscreen/SecondScreenMediaRoute.smali`.)
- Fire TV (TCOMM) inbound messages are parsed from bytes into JSON and routed explicitly as `Route.TCOMM`:
  - `TCommMessageHandler.onMessage(...)` reads `Message.getPayload()` -> bytes -> `new JSONObject(new String(bytes, UTF_8))` and calls `IncomingMessageHandler.onMessage(json, remoteDeviceKey, Route.TCOMM)`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/internal/handler/TCommMessageHandler.smali`.)
- Message dispatch uses a JSON `"name"` field as the command key:
  - `CommandHelper.getCommandName(JSONObject)` reads `message.getString("name")`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/internal/CommandHelper.smali`.)
  - `RoutingMessageHandler.onMessage(...)` looks up the `CommandMessageHandler` by that name and calls `handler.onMessage(json, remoteDevice, route)`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/internal/handler/RoutingMessageHandler.smali`.)
- Status updates from Fire TV arrive via the generic status command `"setStatus"` with a `"details"` payload:
  - `StatusCommand` defines `REQUEST_STATUS="getStatus"`, `CONSUME_STATUS="setStatus"`, and `JSON_KEY_DETAILS="details"`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes8/com/amazon/messaging/common/internal/StatusCommand.smali`.)
  - `StatusEventDispatchMessageHandler.processConsumeStatusCommand(...)` reads `details` (`getJSONObject("details")`), then calls `StatusEventHelper.deserializeEvent(details)` and delivers it via `RemoteDevice.raiseStatusEvent(...)`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/internal/handler/StatusEventDispatchMessageHandler.smali`.)
- Ad breaks for Fire TV are carried inside the status event as `details.subEventList[]` entries:
  - `StatusEventHelper.getPlaybackSubEventListFromJson(JSONObject)` reads optional `"subEventList"` and parses each entry.
  - `StatusEventHelper.parseSubEventFromJson(JSONObject)` switches on subevent `"name"` and constructs `PlaybackAdBreakSubEvent.fromJsonObject(...)` and `PlaybackAdPlanSubEvent$Companion.fromJsonObject(...)` among others. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/event/StatusEventHelper.smali`.)
- Those remote ad-break subevents are consumed by the second-screen player and converted into the phone-side ad lifecycle callbacks:
  - `DefaultATVRemoteDevice.raiseStatusEvent(...)` forwards `ATVDeviceStatusEvent` to registered `ATVStatusEventListenerWrapper` listeners. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes6/com/amazon/avod/messaging/DefaultATVRemoteDevice.smali`.)
  - `SecondScreenVideoPlayer.processSubEvents(...)` groups `ATVDeviceStatusEvent.getSubEventList()` by class and feeds each group into registered `PlaybackSubEventProcessor`s, including `AdBreakSubEventProcessor` (registered in the constructor). (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes9/com/amazon/avod/secondscreen/playback/player/SecondScreenVideoPlayer.smali`.)
  - `AdBreakSubEventProcessor` consumes `PlaybackAdBreakSubEvent` and notifies `onBeginAdBreak(...)` / `onEndAdBreak(...)`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes9/com/amazon/avod/secondscreen/remote/ad/AdBreakSubEventProcessor.smali`.)
- Companion mode still does not surface the local ad-plan/state-machine controls:
  - `SecondScreenVideoClientPresentation.getAdPlan()` returns `EmptyAdPlan`, and `addAdPlanUpdateListener(...)` returns `false`. (See `analysis/decompiled/prime-3.0.438.2347-smali/smali_classes7/com/amazon/avod/playback/secondscreen/SecondScreenVideoClientPresentation.smali`.)

### Cast Pipeline Map (Fire TV Cube 2nd Gen via TCOMM)
1. Route discovery/select uses MediaRouter categories including `TCommControlCategory` -> remote device selected (Fire TV Cube).
2. Fire TV communications use Amazon TCOMM transport; inbound messages are parsed by `TCommMessageHandler` and routed as `Route.TCOMM`.
3. Remote device sends `"setStatus"` messages with `"details"`; phone deserializes into `ATVDeviceStatusEvent` (`StatusEventHelper.deserializeEvent(details)`).
4. `details.subEventList[]` includes subevents such as `PlaybackAdBreakSubEvent` and `PlaybackAdPlanSubEvent` derived from each entry’s `"name"`.
5. Phone-side `SecondScreenVideoPlayer.processSubEvents(...)` dispatches those to processors (`AdBreakSubEventProcessor`), producing UI/lifecycle callbacks on the phone while playback continues on the Fire TV.

### Ad Control Location (Fire TV / TCOMM)
- **Receiver-controlled (High confidence):** Ad breaks arrive as part of remote status (`"setStatus"` -> `details.subEventList`) that the Fire TV sends, and the phone only reacts to them. (See `TCommMessageHandler.smali`, `StatusEventDispatchMessageHandler.smali`, `StatusEventHelper.smali`.)
- **Server-side manifest/segments (Medium confidence):** In TCOMM mode the Fire TV is the playback endpoint; the phone is not fetching media segments. Whether ads are strictly SSAI or device-side stitched needs receiver/network inspection, but the control plane suggests the receiver is authoritative. (Corroborated by the companion-mode `EmptyAdPlan` surface in `SecondScreenVideoClientPresentation.smali`.)
- **Client-side ad insertion/control (Low confidence):** Companion mode primarily consumes remote ad-break subevents rather than running the local `ServerInsertedAdBreakState` SSAI state machine.

### Feasibility Table (Phone APK Patching Only, Fire TV / TCOMM)
| Hypothesis | Evidence in APK | Feasibility if true |
|---|---|---|
| (1) Ads are in manifest/segments for Fire TV cast | Phone is a controller; Fire TV is the playback endpoint and reports ad breaks back via status events | Low: phone patching won’t change Fire TV playback |
| (2) Receiver app renders/controls ads | Fire TV sends ad-break subevents (`details.subEventList`) and the phone reacts | Low: phone patching can at most affect phone UI/control behavior |
| (3) Phone instructs receiver to play ads | No evidence in this path that the phone “injects ads”; instead it processes receiver-originated status | Low/unclear: would require evidence of explicit ad directives sent by phone in the start/load payloads |
