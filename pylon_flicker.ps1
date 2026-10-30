# Measures frame-to-frame brightness variation (flicker) for one or more exposure times.
# Usage: .\pylon_flicker.ps1 -Exposures 25000,20000,30000 -Frames 150
param(
    [int[]]$Exposures = @(25000, 20000, 30000),
    [int]$Frames = 150
)

$ErrorActionPreference = 'Stop'
$asm = 'C:\Program Files\Basler\pylon 6\Development\Assemblies\Basler.Pylon\x64\Basler.Pylon.dll'
Add-Type -Path $asm

$code = @"
using System;
using System.Collections.Generic;
using Basler.Pylon;

public static class PylonFlicker
{
    public static string Run(int[] exposures, int frames)
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
            var sg = cam.StreamGrabber;
            p[PLCamera.ExposureAuto].SetValue("Off");
            p[PLCamera.GainAuto].SetValue("Off");
            foreach (int exp in exposures)
            {
                p[PLCamera.ExposureTimeAbs].SetValue((double)exp);
                var means = new List<double>();
                long fail = 0;
                sg.Start(long.MaxValue, GrabStrategy.OneByOne, GrabLoop.ProvidedByUser);
                while (means.Count < frames)
                {
                    using (var gr = sg.RetrieveResult(2000, TimeoutHandling.Return))
                    {
                        if (gr == null) break;
                        if (!gr.GrabSucceeded) { fail++; continue; }
                        byte[] b = gr.PixelData as byte[];
                        if (b == null) continue;
                        int step = Math.Max(1, b.Length / 50000);
                        double sum = 0; int cnt = 0;
                        for (int i = 0; i < b.Length; i += step) { sum += b[i]; cnt++; }
                        means.Add(sum / cnt);
                    }
                }
                sg.Stop();
                // Skip the first frames after the exposure change
                if (means.Count > 5) means.RemoveRange(0, 5);
                double avg = 0, min = double.MaxValue, max = 0, var = 0;
                foreach (double m in means) { avg += m; if (m < min) min = m; if (m > max) max = m; }
                avg /= Math.Max(1, means.Count);
                foreach (double m in means) var += (m - avg) * (m - avg);
                double sd = Math.Sqrt(var / Math.Max(1, means.Count));
                var seq = new System.Text.StringBuilder();
                for (int i = 0; i < Math.Min(12, means.Count); i++) seq.Append(means[i].ToString("F1") + " ");
                sb.AppendLine("Exp=" + exp + "us frames=" + means.Count + " fail=" + fail
                    + " mean=" + avg.ToString("F1") + " sd=" + sd.ToString("F2")
                    + " range=" + min.ToString("F1") + ".." + max.ToString("F1")
                    + " flicker=" + (avg > 0 ? (100.0 * (max - min) / avg).ToString("F1") : "?") + "%"
                    + " FpsResult=" + p[PLCamera.ResultingFrameRateAbs].GetValue().ToString("F3"));
                sb.AppendLine("   first: " + seq);
            }
            try { cam.Close(); } catch { }
        }
        }
        catch (Exception ex) { sb.AppendLine("EXCEPTION: " + ex.Message); }
        return sb.ToString();
    }
}
"@

Add-Type -TypeDefinition $code -ReferencedAssemblies $asm -ErrorAction Stop
[PylonFlicker]::Run($Exposures, $Frames)
