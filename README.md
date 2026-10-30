# Basler acA1300-60gm — 30 fps without errors, flicker or dark images

Camera: Basler acA1300-60gm, SN 25311512, FW V5.2-0, IP 192.168.1.101 (GigE)
Host NIC: "Ethernet 4" (Basler GigE Vision Adapter, Intel 82574L), 192.168.1.10/24
Software: pylon 6 (`C:\Program Files\Basler\pylon 6`)

## Summary of the problem and the fix

| Symptom | Cause | Fix |
|---|---|---|
| ~97 errors / 575 frames, dropped frames, frame rate jumping (~20 fps) | The camera sends each frame as a burst of ~540 packets. The NIC/driver path loses packets in that burst; every unrecovered packet costs a resend or a ~1 s stall | **Inter-Packet Delay (GevSCPD) = 5300**, packet size 1500 |
| Frame rate 29.99 instead of 30 | The camera only supports certain frame rates: setting 30.000 gives 29.989 | **Acquisition Frame Rate = 30.002** → resulting 30.002 fps (33.33 ms per frame) |
| Image too dark | Default gain selector `AnalogAll` only allows GainRaw 0–3 | **Gain Selector = All**, **GainRaw = 95**, longer exposure |
| Image flickers | Room lighting on 50 Hz mains pulses at 100 Hz (every 10 ms). 25 ms exposure = 2.5 pulses, so frame brightness alternated ±10 % | **Exposure = 30000 µs** (3 whole light pulses) |
| Settings lost after power cycle | Settings were only active, not stored | Saved to **UserSet1** and set as **Default Startup Set** |

### Measured results (final settings, 30 s runs)

- 898 frames, 0 failed grabs, camera-measured 30.00 fps, frame interval exactly 33.33 ms
- Flicker at 30 ms exposure: 3.1 % peak-to-peak (sd 0.39); it was 20.6 % at 25 ms
- Confirmed in pylon Viewer: 30 fps, no errors

### What was tested and rejected

- **Jumbo frames** (packet size 4000/8192): 36–50 % of packets failed on this network path, so packet size stays 1500.
- **Inter-Packet Delay 0–5250**: stalls, incomplete buffers or the camera's control connection dropping. 6000/7000 are clean, but too slow for 30 fps (27.6 / 24.4 fps).
- **Smaller ROI**: does not fix the stalls; only packet pacing does.
- **Filter driver vs. performance driver**: both work at IPD 5300. The pylon Viewer default (Intel performance driver) was the cleaner of the two in the final runs, so nothing needs changing there.
- **Exposure vs. flicker** (50 Hz lighting): 16.7 ms → 28.5 %, 20 ms → 3.9 %, 25 ms → 20.6 %, 30 ms → 3.1–4.9 %.

### Final camera configuration (stored in UserSet1, loaded at power-on)

| Feature | Value |
|---|---|
| Width × Height | 1024 × 768 (auto-centered, offsets are read-only) |
| Pixel Format | Mono8 |
| Exposure Auto / Gain Auto | Off / Off |
| Exposure Time (Abs) | 30000 µs |
| Gain Selector / Gain (Raw) | All / 95 (maximum) |
| Acquisition Frame Rate Enable | On |
| Acquisition Frame Rate (Abs) | 30.002 (resulting 30.002 fps) |
| Packet Size (GevSCPSPacketSize) | 1500 |
| Inter-Packet Delay (GevSCPD) | 5300 |
| Default Startup Set | User Set 1 |

The viewer's buffer memory (`HKCU\Software\Basler\pylon Viewer 64-Bit\Grab\UsedBufferMemory`) is 64 MB (67108864).

---

## Guide A — fix it with the scripts

All scripts are in this folder and use the pylon .NET SDK. **Close pylon Viewer first**: only one program can control the camera at a time.

| Script | Purpose |
|---|---|
| `pylon_save.ps1` | Applies the final configuration, saves it to UserSet1, sets UserSet1 as startup default, and verifies it by reloading |
| `pylon_bench.ps1` | Streams for N seconds and reports delivered fps, camera-timestamp fps, frame intervals, brightness, failed buffers/packets and resends |
| `pylon_flicker.ps1` | Measures frame-to-frame brightness variation for a list of exposure times |
| `pylon_diag2.ps1` | Dumps camera/network/stream parameters and stream statistics |
| `old\` | Earlier exploration scripts, kept for reference (not needed) |

### 1. Re-apply and save the known-good settings

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\pylon_save.ps1 -CloseViewer
```

Check the last line `After load UserSet1:`. It must show `Exp=30000 GainRaw(All)=95 FpsResult=30.002 Packet=1500 IPD=5300`.

Optional parameters: `-ExposureUs`, `-GainRaw`, `-InterPacketDelay`, `-PacketSize`, `-Width`, `-Height`.

### 2. Verify the stream (30 s)

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\pylon_bench.ps1 -Seconds 30 -Fps 30.002 -InterPacketDelay 5300 -Driver WindowsIntelPerformanceDriver -ExposureUs 30000 -GainSelector All -GainRaw 95
```

Good result: `fail=0`, `Camera timestamps: 30.00 fps`, interval min/max both ≈ 33.33 ms.
A trailing `Control channel not open` message at close is harmless when the numbers above are good.

If frames fail, increase `-InterPacketDelay` in steps of 100. Keep `Camera timestamps` at 30.00: if the delay is too large, fps drops below 30 (6000 → 27.6 fps).

### 3. Check flicker

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command "& '.\pylon_flicker.ps1' -Exposures 20000,25000,30000 -Frames 150"
```

Pick the exposure with the lowest `flicker=` %. For 50 Hz lighting use multiples of 10000 µs (10/20/30 ms). For 60 Hz lighting use multiples of 8333 µs (16667/25000 µs). At 30 fps the exposure must stay below ~33000 µs. Save the result with `pylon_save.ps1 -ExposureUs <value>`.

---

## Guide B — fix it by hand in pylon Viewer

1. Start `pylonviewer.exe` and double-click the camera in the **Devices** pane to open it. **Stop** any acquisition: Width/Height/Packet Size can only be changed while stopped.
2. In the **Features** pane set the visibility (top of the pane) to **Guru** so all features are shown.
3. **Image Format Controls** → Pixel Format = **Mono 8**.
4. **AOI Controls** → Width = **1024**, Height = **768** (Center X/Y stay on, so offsets are automatic).
5. **Acquisition Controls**
   - Exposure Auto = **Off**
   - Exposure Time (Abs) = **30000** µs (50 Hz lighting; see Guide A step 3 for 60 Hz)
   - Acquisition Frame Rate Enable = **checked**
   - Acquisition Frame Rate (Abs) = **30.002** → check **Resulting Frame Rate** reads 30.002
6. **Analog Controls**
   - Gain Auto = **Off**
   - Gain Selector = **All** (with the default *Analog All* the gain only goes to 3)
   - Gain (Raw) = **95**
7. **Transport Layer**
   - Packet Size = **1500**
   - Inter-Packet Delay = **5300**
8. **User Set Control** (save so it survives power cycles)
   - User Set Selector = **User Set 1** → click **User Set Save** (Execute)
   - Default Startup Set = **User Set 1**
9. Click **Continuous Shot**, let it run ~60 s. The status bar should show ~30 fps and the error count should stay at 0.

### If errors return in the viewer

- **Transport Layer → Inter-Packet Delay** still 5300? If not, set it back and save the user set again.
- Raise Inter-Packet Delay by 100 at a time (stay ≤ ~5500 to keep 30 fps).
- Optional: **Stream Parameters → Type = Windows Filter Driver**. This setting is not saved; it resets every time the viewer opens the camera, and wasn't needed here.
- Cable: connect the camera directly to the NIC (no switch), try a different Cat6 cable.

---

## Optional improvements (not done)

### Firmware update (camera is on V5.2-0)

Not possible without a firmware file. Basler doesn't publish them; the pylon Firmware Updater needs a `.guf` file for this exact model.

1. Request the latest `.guf` for **acA1300-60gm, SN 25311512, current FW V5.2-0** from Basler Support (support form at baslerweb.com).
2. Close all programs using the camera, stop acquisition.
3. pylon Viewer → **Tools → Firmware Updater** (or right-click the camera in Devices) → select the camera → **Next** → choose the `.guf` file → check the *Update summary* (old/new version) → **Next**.
4. **Do not unplug power/PoE during the update.**
5. Afterwards check that UserSet1 is still the Default Startup Set, and re-run `pylon_save.ps1` if the settings were reset.

### NIC tuning (needs admin)

Device Manager → Network adapters → **Ethernet 4 (Basler GigE Vision Adapter)** → Properties → **Advanced**:
- Receive Buffers / Receive Descriptors → **maximum** (2048/4096)
- Interrupt Moderation Rate → **Extreme** or **Adaptive**

This adds headroom against lost packets.

### Brightness

At 30 ms and maximum gain the mean brightness depends on room light (51/255 now; ~100 earlier with more ambient light). Exposure can't go higher at 30 fps, and gain is already at maximum. For a brighter image, add light to the scene (ideally flicker-free LED/DC lighting) or use a lens with a lower f-number.
