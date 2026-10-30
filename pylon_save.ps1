# Applies the working camera configuration, saves it to UserSet1, makes UserSet1 the
# power-on default and verifies it by reloading Default and then UserSet1.
# pylon Viewer must be closed (it holds the camera); -CloseViewer closes it for you.
# Usage: .\pylon_save.ps1            (defaults = known-good settings)
#        .\pylon_save.ps1 -ExposureUs 20000 -CloseViewer
param(
    [double]$ExposureUs = 30000,      # multiple of 10 ms = flicker-free under 50 Hz lighting
    [int]$GainRaw = 95,               # with GainSelector=All (range 0-95)
    [int]$InterPacketDelay = 5300,    # GevSCPD; <=5250 caused lost packets / stalls
    [int]$PacketSize = 1500,          # jumbo frames fail on this network path
    [int]$Width = 1024,
    [int]$Height = 768,
    [switch]$CloseViewer
)

$ErrorActionPreference = 'Stop'

$v = @(Get-Process pylonviewer -ErrorAction SilentlyContinue)
if ($v.Count -gt 0) {
    if (-not $CloseViewer) { throw 'pylon Viewer is running and holds the camera. Close it or pass -CloseViewer.' }
    $v | ForEach-Object { $_.Kill(); $null = $_.WaitForExit(5000) }
    Start-Sleep -Seconds 4
}

$asm = 'C:\Program Files\Basler\pylon 6\Development\Assemblies\Basler.Pylon\x64\Basler.Pylon.dll'
Add-Type -Path $asm

$code = @"
using System;
using Basler.Pylon;

public static class PylonSave
{
    static string Dump(IParameterCollection p)
    {
        p[PLCamera.GainSelector].SetValue("All");
        long gAll = p[PLCamera.GainRaw].GetValue();
        return "ROI=" + p[PLCamera.Width].GetValue() + "x" + p[PLCamera.Height].GetValue()
            + " Pix=" + p[PLCamera.PixelFormat].GetValue()
            + " Exp=" + p[PLCamera.ExposureTimeAbs].GetValue().ToString("F0")
            + " ExpAuto=" + p[PLCamera.ExposureAuto].GetValue()
            + " GainAuto=" + p[PLCamera.GainAuto].GetValue()
            + " GainRaw(All)=" + gAll
            + " FpsEn=" + p[PLCamera.AcquisitionFrameRateEnable].GetValue()
            + " FpsSet=" + p[PLCamera.AcquisitionFrameRateAbs].GetValue().ToString("F3")
            + " FpsResult=" + p[PLCamera.ResultingFrameRateAbs].GetValue().ToString("F3")
            + " Packet=" + p[PLCamera.GevSCPSPacketSize].GetValue()
            + " IPD=" + p[PLCamera.GevSCPD].GetValue();
    }

    public static string Run(double exposureUs, long gainRaw, long ipd, long packetSize, long width, long height)
    {
        var sb = new System.Text.StringBuilder();
        var cams = CameraFinder.Enumerate();
        if (cams.Count == 0) return "No camera found.";
        try
        {
        using (var cam = new Camera(cams[0]))
        {
            cam.Open();
            var p = cam.Parameters;

            // Offsets are auto-centered (CenterX/CenterY) on this camera; only set width/height
            p[PLCamera.Width].SetValue(width);
            p[PLCamera.Height].SetValue(height);
            p[PLCamera.PixelFormat].SetValue("Mono8");
            p[PLCamera.ExposureAuto].SetValue("Off");
            p[PLCamera.GainAuto].SetValue("Off");
            p[PLCamera.ExposureTimeAbs].SetValue(exposureUs);
            p[PLCamera.GainSelector].SetValue("All");
            p[PLCamera.GainRaw].SetValue(gainRaw);
            p[PLCamera.GevSCPSPacketSize].SetValue(packetSize);
            p[PLCamera.GevSCPD].SetValue(ipd);
            p[PLCamera.AcquisitionFrameRateEnable].SetValue(true);

            // Frame rate is quantized; pick the setpoint whose resulting rate is closest to 30.000
            double best = 30.0, bestErr = double.MaxValue;
            foreach (double f in new double[] { 30.0, 30.002, 30.005, 30.008, 30.01, 30.012, 30.015, 30.02 })
            {
                p[PLCamera.AcquisitionFrameRateAbs].SetValue(f);
                double r = p[PLCamera.ResultingFrameRateAbs].GetValue();
                sb.AppendLine("  set " + f.ToString("F3") + " -> " + r.ToString("F4"));
                double e = Math.Abs(r - 30.0);
                if (e < bestErr - 1e-9) { bestErr = e; best = f; }
            }
            p[PLCamera.AcquisitionFrameRateAbs].SetValue(best);
            sb.AppendLine("Chosen FpsSet=" + best.ToString("F3"));
            sb.AppendLine("Configured: " + Dump(p));

            p[PLCamera.UserSetSelector].SetValue("UserSet1");
            p[PLCamera.UserSetSave].Execute();
            p[PLCamera.UserSetDefaultSelector].SetValue("UserSet1");
            sb.AppendLine("Saved UserSet1; DefaultSelector=" + p[PLCamera.UserSetDefaultSelector].GetValue());

            p[PLCamera.UserSetSelector].SetValue("Default");
            p[PLCamera.UserSetLoad].Execute();
            sb.AppendLine("After load Default:  " + Dump(p));

            p[PLCamera.UserSetSelector].SetValue("UserSet1");
            p[PLCamera.UserSetLoad].Execute();
            sb.AppendLine("After load UserSet1: " + Dump(p));
            try { cam.Close(); } catch { }
        }
        }
        catch (Exception ex) { sb.AppendLine("EXCEPTION: " + ex.Message); }
        return sb.ToString();
    }
}
"@

Add-Type -TypeDefinition $code -ReferencedAssemblies $asm -ErrorAction Stop
[PylonSave]::Run($ExposureUs, $GainRaw, $InterPacketDelay, $PacketSize, $Width, $Height)
