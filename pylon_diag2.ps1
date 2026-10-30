param(
    [int]$GrabSeconds = 5,
    [switch]$NoCloseViewer
)

$ErrorActionPreference = 'Stop'
Add-Type -Path 'C:\Program Files\Basler\pylon 6\Development\Assemblies\Basler.Pylon\x64\Basler.Pylon.dll'

if (-not $NoCloseViewer) {
    $v = @(Get-Process pylonviewer -ErrorAction SilentlyContinue)
    if ($v.Count -gt 0) {
        Write-Output 'Closing pylon Viewer so the camera control channel is free...'
        $v | ForEach-Object { $null = $_.CloseMainWindow() }
        Start-Sleep -Seconds 3
        @(Get-Process pylonviewer -ErrorAction SilentlyContinue) | ForEach-Object { $_.Kill(); $null = $_.WaitForExit(5000) }
        Start-Sleep -Milliseconds 800
    }
}

$cams = [Basler.Pylon.CameraFinder]::Enumerate()
if ($cams.Count -eq 0) { throw 'No Basler camera found.' }
$ci = $cams[0]
$cam = New-Object Basler.Pylon.Camera($ci)

function Get-F([string]$n) { $script:cam.Parameters[[Basler.Pylon.FloatName]::new($n)].GetValue() }
function Get-I([string]$n) { $script:cam.Parameters[[Basler.Pylon.IntegerName]::new($n)].GetValue() }
function Get-E([string]$n) { $script:cam.Parameters[[Basler.Pylon.EnumName]::new($n)].GetValue() }
function Get-B([string]$n) { $script:cam.Parameters[[Basler.Pylon.BooleanName]::new($n)].GetValue() }
function Get-S([string]$n) { $script:cam.Parameters[[Basler.Pylon.StringName]::new($n)].GetValue() }
function Try-Get([scriptblock]$sb) { try { & $sb } catch { 'n/a' } }

try {
    $null = $cam.Open()
    Write-Output ("Camera   : {0}  SN {1}  FW {2}" -f $ci[[Basler.Pylon.CameraInfoKey]::ModelName], $ci[[Basler.Pylon.CameraInfoKey]::SerialNumber], (Try-Get { Get-S 'DeviceFirmwareVersion' }))
    Write-Output ("Sensor   : {0} x {1}  (ROI {2} x {3} @ {4},{5})  PixelFormat {6}" -f (Get-I 'SensorWidth'), (Get-I 'SensorHeight'), (Get-I 'Width'), (Get-I 'Height'), (Get-I 'OffsetX'), (Get-I 'OffsetY'), (Get-E 'PixelFormat'))
    Write-Output ("Exposure : {0:N1} us   Auto {1}   auto limits {2:N1}..{3:N1} us" -f (Get-F 'ExposureTimeAbs'), (Get-E 'ExposureAuto'), (Get-F 'AutoExposureTimeAbsLowerLimit'), (Get-F 'AutoExposureTimeAbsUpperLimit'))
    Write-Output ("Gain     : raw {0}   Auto {1}   raw limits {2}..{3}" -f (Get-I 'GainRaw'), (Get-E 'GainAuto'), (Get-I 'AutoGainRawLowerLimit'), (Get-I 'AutoGainRawUpperLimit'))
    Write-Output ("FrameRate: enable {0}  set {1:N2} fps  resulting {2:N2} fps" -f (Get-B 'AcquisitionFrameRateEnable'), (Get-F 'AcquisitionFrameRateAbs'), (Get-F 'ResultingFrameRateAbs'))
    Write-Output ("GigE cam : packetSize {0}  GevSCPD {1}  resendSupport {2}" -f (Get-I 'GevSCPSPacketSize'), (Get-I 'GevSCPD'), (Try-Get { Get-B 'GevSupportedOptionalCommandsPACKETRESEND' }))

    $sg = $cam.StreamGrabber
    $sgp = $sg.Parameters
    function Get-SG([string]$n, [string]$t) {
        switch ($t) {
            'i' { $script:sgp[[Basler.Pylon.IntegerName]::new($n)].GetValue() }
            'b' { $script:sgp[[Basler.Pylon.BooleanName]::new($n)].GetValue() }
            default { $script:sgp[[Basler.Pylon.StringName]::new($n)].GetValue() }
        }
    }
    Write-Output ("Stream   : AutoPacketSize {0}  resend {1}  numBuffers {2}  maxBufferSize {3}  rcvWindow {4}  pktTimeout {5}" -f (Try-Get { Get-SG 'AutoPacketSize' 'b' }), (Try-Get { Get-SG 'EnableResend' 'b' }), (Try-Get { Get-SG 'MaxNumBuffer' 'i' }), (Try-Get { Get-SG 'MaxBufferSize' 'i' }), (Try-Get { Get-SG 'ReceiveWindowSize' 'i' }), (Try-Get { Get-SG 'PacketTimeout' 'i' }))
    Write-Output ''
    Write-Output ("Grabbing for {0}s with current settings..." -f $GrabSeconds)

    $intervals = New-Object System.Collections.Generic.List[double]
    $succeeded = 0; $failed = 0; $firstImageNo = $null; $firstTs = $null; $lastImageNo = $null; $lastTs = $null
    $errExamples = @{}
    $meanBrightness = $null

    $sg.Start([int64]::MaxValue, [Basler.Pylon.GrabStrategy]::OneByOne, [Basler.Pylon.GrabLoop]::ProvidedByUser)
    $deadline = [DateTime]::UtcNow.AddSeconds($GrabSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $gr = $sg.RetrieveResult(1000, [Basler.Pylon.TimeoutHandling]::Return)
        if ($null -eq $gr) { continue }
        try {
            if ($gr.GrabSucceeded) {
                $succeeded++
                if ($null -eq $firstImageNo) { $firstImageNo = $gr.ImageNumber; $firstTs = $gr.Timestamp }
                if ($null -ne $lastTs) { $intervals.Add([double]($gr.Timestamp - $lastTs)) }
                $lastImageNo = $gr.ImageNumber; $lastTs = $gr.Timestamp
                if ($null -eq $meanBrightness -and $gr.Container.Count -gt 0) {
                    $dc = $gr.Container[0]
                    $pd = $dc.PixelData
                    if ($pd -is [byte[]] -and $pd.Length -gt 0) {
                        $step = [Math]::Max(1, [int]($pd.Length / 20000))
                        $sum = [double]0; $cnt = 0
                        for ($i = 0; $i -lt $pd.Length; $i += $step) { $sum += $pd[$i]; $cnt++ }
                        $meanBrightness = $sum / $cnt
                    }
                }
            } else {
                $failed++
                $key = "$($gr.ErrorCode): $($gr.ErrorDescription)"
                if (-not $errExamples.ContainsKey($key)) { $errExamples[$key] = 0 }
                $errExamples[$key]++
            }
        } finally { $gr.Dispose() }
    }
    $sg.Stop()

    $total = $succeeded + $failed
    $fps = 0.0
    if ($null -ne $firstTs -and $null -ne $lastTs -and $lastTs -gt $firstTs -and $null -ne $firstImageNo) {
        $fps = ($lastImageNo - $firstImageNo) / (($lastTs - $firstTs) / 1e9)
    }
    Write-Output ''
    Write-Output '--- RESULT (current settings) ---'
    Write-Output ("Frames delivered : {0} succeeded, {1} failed, {2} total" -f $succeeded, $failed, $total)
    if ($total -gt 0) { Write-Output ("Failure rate    : {0:P1}" -f ($failed / $total)) }
    Write-Output ("Frame rate      : avg {0:N2} fps" -f $fps)
    if ($intervals.Count -gt 1) {
        $avg = ($intervals | Measure-Object -Average).Average
        $min = ($intervals | Measure-Object -Minimum).Minimum
        $max = ($intervals | Measure-Object -Maximum).Maximum
        Write-Output ("Frame interval  : avg {0:N2} ms, min {1:N2} ms, max {2:N2} ms (jitter {3:N2} ms)" -f ($avg/1e6), ($min/1e6), ($max/1e6), (($max-$min)/1e6))
    }
    if ($null -ne $meanBrightness) { Write-Output ("Mean brightness : {0:N1} of 255" -f $meanBrightness) }
    foreach ($k in $errExamples.Keys) { Write-Output ("  grab error x{0}: {1}" -f $errExamples[$k], $k) }

    Write-Output ''
    Write-Output '--- pylon stream statistics for this run ---'
    foreach ($n in 'Statistic_Total_Buffer_Count','Statistic_Failed_Buffer_Count','Statistic_Buffer_Underrun_Count','Statistic_Total_Packet_Count','Statistic_Failed_Packet_Count','Statistic_Resend_Request_Count','Statistic_Resend_Packet_Count','Statistic_Last_Failed_Buffer_Status_Text') {
        $type = if ($n -like '*Text') { 's' } else { 'i' }
        Write-Output ("{0,-42}: {1}" -f $n, (Try-Get { Get-SG $n $type }))
    }
} finally {
    try { if ($cam -and $cam.IsGrabbing) { $cam.StreamGrabber.Stop() } } catch {}
    try { if ($cam -and $cam.IsOpen) { $cam.Close() } } catch {}
    try { if ($cam) { $cam.Dispose() } } catch {}
}
