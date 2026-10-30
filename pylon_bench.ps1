param(
    [int]$Seconds = 5,
    [double]$Fps = 30,
    [double]$ExposureUs = 10000,
    [int]$GainRaw = 1,
    [int]$PacketSize = 1500,
    [int]$InterPacketDelay = 0,
    [int]$NumBuffers = 32,
    [string]$Driver = 'WindowsFilterDriver',
    [string]$ExposureAuto = '',
    [int]$AutoTarget = -1,
    [int]$PacketTimeout = -1,
    [int]$FrameRetention = -1,
    [int]$ReceiveWindowSize = -1,
    [int]$Width = 0,
    [int]$Height = 0,
    [int]$OffsetX = -1,
    [int]$OffsetY = -1,
    [string]$GainSelector = ''
)

$ErrorActionPreference = 'Stop'
$asm = 'C:\Program Files\Basler\pylon 6\Development\Assemblies\Basler.Pylon\x64\Basler.Pylon.dll'
Add-Type -Path $asm

$code = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using Basler.Pylon;

public static class PylonBench
{
    public static string Run(int seconds, double fps, double exposureUs, int gainRaw, int packetSize, int ipd, int numBuf, string driver, string exposureAuto, int autoTarget, int packetTimeout, int frameRetention, int receiveWindowSize, int width, int height, int offsetX, int offsetY, string gainSelector)
    {
        var sb = new System.Text.StringBuilder();
        var cams = CameraFinder.Enumerate();
        if (cams.Count == 0) return "No camera found.";
        try
        {
        using (var cam = new Camera(cams[0]))
        {
            Exception openErr = null;
            for (int attempt = 0; attempt < 4; attempt++)
            {
                try { cam.Open(); openErr = null; break; }
                catch (Exception ex) { openErr = ex; System.Threading.Thread.Sleep(2000); }
            }
            if (openErr != null) return "OPEN FAILED: " + openErr.Message;
            var p = cam.Parameters;
            var sg = cam.StreamGrabber;
            var sp = (IParameterCollection)sg.GetType().GetProperty("Parameters").GetValue(sg, null);

            sb.AppendLine("Model=" + cam.CameraInfo[CameraInfoKey.ModelName] + " SN=" + cam.CameraInfo[CameraInfoKey.SerialNumber]);
            sb.AppendLine("Mode: Trigger=" + p[PLCamera.TriggerMode].GetValue()
                + " Acquisition=" + p[PLCamera.AcquisitionMode].GetValue()
                + " ExposureMode=" + p[PLCamera.ExposureMode].GetValue());
            sb.AppendLine("Before: Driver=" + sp[PLStream.Type].GetValue()
                + " Packet=" + p[PLCamera.GevSCPSPacketSize].GetValue()
                + " IPD=" + p[PLCamera.GevSCPD].GetValue()
                + " Exp=" + p[PLCamera.ExposureTimeAbs].GetValue().ToString("F1")
                + " GainRaw=" + p[PLCamera.GainRaw].GetValue()
                + " FpsSet=" + p[PLCamera.AcquisitionFrameRateAbs].GetValue().ToString("F3")
                + " FpsResult=" + p[PLCamera.ResultingFrameRateAbs].GetValue().ToString("F3")
                + " Resend=" + sp[PLStream.EnableResend].GetValue()
                + " Buffers=" + sp[PLStream.MaxNumBuffer].GetValue());

            if (!string.IsNullOrEmpty(driver)) sp[PLStream.Type].SetValue(driver);
            sp[PLStream.AutoPacketSize].SetValue(false);
            sp[PLStream.EnableResend].SetValue(true);
            sp[PLStream.MaxNumBuffer].SetValue((long)numBuf);
            if (packetTimeout > 0) sp[PLStream.PacketTimeout].SetValue((long)packetTimeout);
            if (frameRetention > 0) { try { sp[PLStream.FrameRetention].SetValue((long)frameRetention); } catch { } }
            if (receiveWindowSize >= 0) { try { sp[PLStream.ReceiveWindowSize].SetValue((long)receiveWindowSize); } catch { } }
            if (width > 0 && height > 0)
            {
                p[PLCamera.Width].SetValue((long)width);
                p[PLCamera.Height].SetValue((long)height);
                if (offsetX >= 0) p[PLCamera.OffsetX].SetValue((long)offsetX);
                if (offsetY >= 0) p[PLCamera.OffsetY].SetValue((long)offsetY);
            }
            p[PLCamera.AcquisitionFrameRateEnable].SetValue(true);
            p[PLCamera.AcquisitionFrameRateAbs].SetValue(fps);
            p[PLCamera.GevSCPSPacketSize].SetValue((long)packetSize);
            p[PLCamera.GevSCPD].SetValue((long)ipd);

            if (!string.IsNullOrEmpty(exposureAuto))
            {
                p[PLCamera.ExposureAuto].SetValue(exposureAuto);
                if (autoTarget >= 0) p[PLCamera.AutoTargetValue].SetValue((long)autoTarget);
            }
            if (exposureUs > 0) p[PLCamera.ExposureTimeAbs].SetValue(exposureUs);
            if (!string.IsNullOrEmpty(gainSelector)) p[PLCamera.GainSelector].SetValue(gainSelector); if (gainRaw >= 0) p[PLCamera.GainRaw].SetValue((long)gainRaw);

            sb.AppendLine("After : Driver=" + sp[PLStream.Type].GetValue()
                + " Packet=" + p[PLCamera.GevSCPSPacketSize].GetValue()
                + " IPD=" + p[PLCamera.GevSCPD].GetValue()
                + " Exp=" + p[PLCamera.ExposureTimeAbs].GetValue().ToString("F1")
                + " GainRaw=" + p[PLCamera.GainRaw].GetValue()
                + " FpsSet=" + p[PLCamera.AcquisitionFrameRateAbs].GetValue().ToString("F3")
                + " FpsResult=" + p[PLCamera.ResultingFrameRateAbs].GetValue().ToString("F3")
                + " ExposureAuto=" + p[PLCamera.ExposureAuto].GetValue()
                + " PacketTimeout=" + sp[PLStream.PacketTimeout].GetValue()
                + " ROI=" + p[PLCamera.Width].GetValue() + "x" + p[PLCamera.Height].GetValue() + "@" + p[PLCamera.OffsetX].GetValue() + "," + p[PLCamera.OffsetY].GetValue()
                + " Payload=" + p[PLCamera.PayloadSize].GetValue());

            long ok = 0, fail = 0;
            long firstImage = -1, lastImage = -1, firstTs = -1, lastTs = -1;
            var intervals = new List<double>();
            var errors = new Dictionary<string, int>();
            string brightType = "";
            double brightMean = -1, brightScale = 0;

            sg.Start(long.MaxValue, GrabStrategy.OneByOne, GrabLoop.ProvidedByUser);
            var sw = Stopwatch.StartNew();
            while (sw.Elapsed.TotalSeconds < seconds)
            {
                using (var gr = sg.RetrieveResult(1000, TimeoutHandling.Return))
                {
                    if (gr == null) continue;
                    if (gr.GrabSucceeded)
                    {
                        ok++;
                        if (firstImage < 0) { firstImage = gr.ImageNumber; firstTs = gr.Timestamp; }
                        if (lastTs >= 0) intervals.Add((double)(gr.Timestamp - lastTs));
                        lastImage = gr.ImageNumber; lastTs = gr.Timestamp;
                        if (brightMean < 0 && gr.Container.Count > 0)
                        {
                            var dc = gr.Container[0];
                            object pd = dc.PixelData;
                            byte[] b = pd as byte[];
                            ushort[] u = pd as ushort[];
                            if (b != null && b.Length > 0)
                            {
                                int step = Math.Max(1, b.Length / 20000);
                                double sum = 0; int cnt = 0;
                                for (int i = 0; i < b.Length; i += step) { sum += b[i]; cnt++; }
                                brightMean = sum / cnt; brightScale = 255; brightType = "byte[]";
                            }
                            else if (u != null && u.Length > 0)
                            {
                                int step = Math.Max(1, u.Length / 20000);
                                double sum = 0; int cnt = 0;
                                for (int i = 0; i < u.Length; i += step) { sum += u[i]; cnt++; }
                                brightMean = sum / cnt; brightScale = 4095; brightType = "ushort[]";
                            }
                            else
                            {
                                brightType = pd == null ? "null" : pd.GetType().FullName;
                                object[] oa = pd as object[];
                                if (oa != null)
                                {
                                    brightType += " len=" + oa.Length;
                                    if (oa.Length > 0 && oa[0] != null) brightType += " el0=" + oa[0].GetType().FullName;
                                }
                            }
                        }
                    }
                    else
                    {
                        fail++;
                        string k = gr.ErrorCode + ": " + gr.ErrorDescription;
                        if (!errors.ContainsKey(k)) errors[k] = 0;
                        errors[k]++;
                    }
                }
            }
            sg.Stop();
            double elapsed = sw.Elapsed.TotalSeconds;

            sb.AppendLine("Result: ok=" + ok + " fail=" + fail + " total=" + (ok + fail) + " elapsed=" + elapsed.ToString("F2") + "s delivered=" + (ok / elapsed).ToString("F2") + " fps");
            if (firstTs >= 0 && lastTs > firstTs)
            {
                double tsFps = (lastImage - firstImage) / ((lastTs - firstTs) / 125000000.0);
                sb.AppendLine("Camera timestamps: " + tsFps.ToString("F2") + " fps avg (tick=125MHz)");
            }
            if (intervals.Count > 0)
            {
                double avg = 0, min = double.MaxValue, max = 0;
                foreach (double v in intervals) { avg += v; if (v < min) min = v; if (v > max) max = v; }
                avg /= intervals.Count;
                sb.AppendLine("Interval ticks: avg=" + avg.ToString("F0") + " min=" + min.ToString("F0") + " max=" + max.ToString("F0")
                    + " (ms: " + (avg / 125000.0).ToString("F2") + " / " + (min / 125000.0).ToString("F2") + " / " + (max / 125000.0).ToString("F2") + ")");
            }
            if (brightMean >= 0) sb.AppendLine("Brightness: " + brightMean.ToString("F1") + " of " + brightScale + " (" + brightType + ")");
            else sb.AppendLine("Brightness: unreadable (" + brightType + ")");
            foreach (var kv in errors) sb.AppendLine("  error x" + kv.Value + ": " + kv.Key);

            sb.AppendLine("Stats: totalBuf=" + sp[PLStream.Statistic_Total_Buffer_Count].GetValue()
                + " failedBuf=" + sp[PLStream.Statistic_Failed_Buffer_Count].GetValue()
                + " totalPkt=" + sp[PLStream.Statistic_Total_Packet_Count].GetValue()
                + " failedPkt=" + sp[PLStream.Statistic_Failed_Packet_Count].GetValue()
                + " resendReq=" + sp[PLStream.Statistic_Resend_Request_Count].GetValue()
                + " resendPkt=" + sp[PLStream.Statistic_Resend_Packet_Count].GetValue());
            sb.AppendLine("Final FpsResult=" + p[PLCamera.ResultingFrameRateAbs].GetValue().ToString("F3"));
            try { cam.Close(); } catch { }
        }
        }
        catch (Exception ex) { sb.AppendLine("EXCEPTION: " + ex.Message); }
        return sb.ToString();
    }
}
"@

Add-Type -TypeDefinition $code -ReferencedAssemblies $asm -ErrorAction Stop
[PylonBench]::Run($Seconds, $Fps, $ExposureUs, $GainRaw, $PacketSize, $InterPacketDelay, $NumBuffers, $Driver, $ExposureAuto, $AutoTarget, $PacketTimeout, $FrameRetention, $ReceiveWindowSize, $Width, $Height, $OffsetX, $OffsetY, $GainSelector)










