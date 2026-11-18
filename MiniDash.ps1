# MiniDash - 画面右下に常駐する軽量システムモニター
# 操作: ドラッグで移動 / ダブルクリックでタスクマネージャー / 右クリックでメニュー

$ErrorActionPreference = 'Stop'
$cfgDir  = Join-Path $env:APPDATA 'MiniDash'
$posFile = Join-Path $cfgDir 'position.txt'
$logFile = Join-Path $cfgDir 'error.log'
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir | Out-Null }

Add-Content -Path $logFile -Value ("{0}  start (pid {1})" -f (Get-Date), $PID)

# 二重起動防止
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'MiniDash_SingleInstance', [ref]$created)
if (-not $created) { Add-Content -Path $logFile -Value ("{0}  already running, exit" -f (Get-Date)); exit }

try {
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

if (-not ('MiniDashNative' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class MiniDashNative {
    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [StructLayout(LayoutKind.Sequential)]
    public class MEMSTAT {
        public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMSTAT));
        public uint dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx([In, Out] MEMSTAT m);
    static long pIdle, pTotal;
    public static double Cpu() {
        long i, k, u; GetSystemTimes(out i, out k, out u);
        long t = k + u; long di = i - pIdle, dt = t - pTotal; pIdle = i; pTotal = t;
        if (dt <= 0) return 0; return Math.Max(0, Math.Min(100, 100.0 * (dt - di) / dt));
    }
    public static ulong[] Mem() { var m = new MEMSTAT(); GlobalMemoryStatusEx(m); return new ulong[] { m.ullTotalPhys, m.ullAvailPhys }; }
}
"@
}
# GPU部分は読み込めなくても他の表示は続ける
$gpuOk = $false
try {
    if (-not ('MiniDashGpu' -as [type])) {
        Add-Type -TypeDefinition (Get-Content (Join-Path $PSScriptRoot 'MiniDashGpu.cs') -Raw -Encoding UTF8)
    }
    $gpuOk = $true
} catch { Add-Content -Path $logFile -Value ("{0}  GPU module load  {1}" -f (Get-Date), $_) }

$PanelWidth = 186.0

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="MiniDash" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        FontFamily="Segoe UI, Yu Gothic UI" FontSize="11" Foreground="#EEEEF2">
  <Border CornerRadius="8" Background="#E61B1D23" BorderBrush="#40FFFFFF" BorderThickness="1" Padding="10,6,10,8">
    <StackPanel Width="$PanelWidth">
      <StackPanel x:Name="Rows"/>
      <Grid Margin="0,5,0,0">
        <TextBlock Text="Net" Foreground="#A8ADBD"/>
        <TextBlock x:Name="NetText" HorizontalAlignment="Right" FontWeight="SemiBold"/>
      </Grid>
      <Grid x:Name="BattRow" Margin="0,3,0,0" Visibility="Collapsed">
        <TextBlock Text="Battery" Foreground="#A8ADBD"/>
        <TextBlock x:Name="BattText" HorizontalAlignment="Right" FontWeight="SemiBold"/>
      </Grid>
      <Border Height="1" Background="#26FFFFFF" Margin="0,6,0,4"/>
      <Grid>
        <TextBlock x:Name="ProcText" FontFamily="Consolas" FontSize="10" Foreground="#B8BCC8" LineHeight="13"/>
        <Button x:Name="DetailBtn" HorizontalAlignment="Right" VerticalAlignment="Center" Cursor="Hand" ToolTip="タスクマネージャーを開く">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Border x:Name="b" Background="Transparent" CornerRadius="3" Width="20" Height="20">
                <Path x:Name="ic" Width="12" Height="12" Stretch="Uniform" Stroke="#8A8FA0" StrokeThickness="1.4"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                      Data="M7,2 L2,2 L2,14 L14,14 L14,9 M9.5,2 L14,2 L14,6.5 M14,2 L7.5,8.5"/>
              </Border>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="b" Property="Background" Value="#24FFFFFF"/>
                  <Setter TargetName="ic" Property="Stroke" Value="#EEEEF2"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
        </Button>
      </Grid>
    </StackPanel>
  </Border>
</Window>
"@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'Rows','NetText','BattRow','BattText','ProcText','DetailBtn') { $ui[$n] = $win.FindName($n) }
$ui.DetailBtn.Add_Click({ Start-Process taskmgr.exe })

# 1行 = ラベル + 値(右寄せ) + 細いバー
function New-MeterRow([string]$label, [string]$tip) {
    $rowXaml = @"
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,5,0,0">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <TextBlock Foreground="#A8ADBD" TextTrimming="CharacterEllipsis" Margin="0,0,6,0"/>
    <TextBlock Grid.Column="1" HorizontalAlignment="Right"><Run FontWeight="SemiBold"/><Run/><Run/></TextBlock>
  </Grid>
  <Grid Height="3" Margin="0,2,0,0">
    <Border Background="#30FFFFFF" CornerRadius="1.5"/>
    <Border HorizontalAlignment="Left" Width="0" CornerRadius="1.5" Background="#4CC38A"/>
  </Grid>
</StackPanel>
"@
    $row = [Windows.Markup.XamlReader]::Parse($rowXaml)
    $row.Children[0].Children[0].Text = $label
    if ($tip) { $row.Children[0].Children[0].ToolTip = $tip }
    [void]$ui.Rows.Children.Add($row)
    $tb = $row.Children[0].Children[1]
    $runs = @($tb.Inlines)
    [pscustomobject]@{ Main = $runs[0]; Temp = $runs[1]; Extra = $runs[2]; Bar = $row.Children[1].Children[1] }
}

$bc = New-Object System.Windows.Media.BrushConverter
$green = $bc.ConvertFromString('#4CC38A'); $amber = $bc.ConvertFromString('#E5B84B'); $red = $bc.ConvertFromString('#E5534B')
$dim = $bc.ConvertFromString('#8A8FA0')
function Get-LevelBrush([double]$pct) { if ($pct -lt 60) { $green } elseif ($pct -lt 85) { $amber } else { $red } }
function Set-Bar($bar, [double]$pct) {
    $pct = [Math]::Max(0, [Math]::Min(100, $pct))
    $bar.Width = $PanelWidth * $pct / 100
    $bar.Background = Get-LevelBrush $pct
}
function Set-Temp($run, [double]$c) {
    if ($c -le 0) { $run.Text = ''; return }
    $run.Text = '  {0:N0}°C' -f $c
    $run.Foreground = if ($c -ge 90) { $red } elseif ($c -ge 80) { $amber } else { $dim }
}
function Format-Rate([double]$bps) {
    if ($bps -ge 1MB) { '{0:N1}M' -f ($bps / 1MB) } elseif ($bps -ge 1KB) { '{0:N0}K' -f ($bps / 1KB) } else { '{0:N0}B' -f $bps }
}
function Get-NetBytes {
    $rx = 0L; $tx = 0L
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne 'Up' -or $ni.NetworkInterfaceType -eq 'Loopback' -or $ni.NetworkInterfaceType -eq 'Tunnel') { continue }
        try { $s = $ni.GetIPv4Statistics(); $rx += $s.BytesReceived; $tx += $s.BytesSent } catch {}
    }
    , @($rx, $tx)
}
function Get-ProcTimes {
    $h = @{}
    foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
        if ($p.Id -eq 0) { continue }
        try { $h[$p.Id] = @($p.ProcessName, $p.TotalProcessorTime.TotalSeconds) } catch {}
    }
    $h
}

# --- 行を作る
$sysDrive = $env:SystemDrive
# 製品名を短くする（例: "AMD Ryzen 7 7840HS w/ Radeon 780M Graphics" -> "Ryzen 7 7840HS"）
function Get-ShortName([string]$n) {
    $n = $n -replace '\((R|TM|tm|r)\)', '' -replace '\s+w/.*$', '' -replace '\s+with\s+Radeon.*$', '' `
            -replace '\s+\d+-Core\s+Processor.*$', '' -replace '\s+CPU\s*@.*$', '' -replace '\s+@\s*[\d.]+\s*GHz.*$', '' `
            -replace '\s+Processor$', '' -replace '^\d+(st|nd|rd|th)\s+Gen\s+', '' -replace '^(AMD|Intel)\s+', '' -replace 'NVIDIA\s+GeForce\s+', '' -replace '\s+Laptop\s+GPU', ''
    ($n -replace '\s+', ' ').Trim()
}
$cpuFull = 'CPU'
try { $cpuFull = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0').ProcessorNameString.Trim() } catch {}
$cpuShort = Get-ShortName $cpuFull; if (-not $cpuShort) { $cpuShort = 'CPU' }

$rowCpu  = New-MeterRow $cpuShort $cpuFull
$rowMem  = New-MeterRow 'Memory'
$gpuRows = @()
$gpuList = @()
if ($gpuOk) {
    try { $gpuList = @([MiniDashGpu]::Init()) } catch { Add-Content -Path $logFile -Value ("{0}  GPU init  {1}" -f (Get-Date), $_) }
}
# 内蔵GPUはCPUと同じチップなので、その温度をCPU欄に表示する
$apuLuid = $null
foreach ($g in $gpuList) { if ($g.Integrated) { $apuLuid = $g.Luid; break } }
foreach ($g in $gpuList) {
    $short = Get-ShortName $g.Name
    # "Radeon Graphics" のような汎用名なら、CPU名に書かれた型番（例: Radeon 780M）を使う
    if ($g.Integrated -and $short -match '^Radeon\s+Graphics$' -and $cpuFull -match '(Radeon\s+\S+)\s+Graphics') { $short = $Matches[1] }
    if (-not $short) { $short = 'GPU' }
    $r = New-MeterRow $short $g.Name
    $r | Add-Member Luid $g.Luid
    $r | Add-Member Integrated $g.Integrated
    $gpuRows += $r
}
$rowDisk = New-MeterRow "Disk $sysDrive"

$cores = [Environment]::ProcessorCount
[void][MiniDashNative]::Cpu()
$script:prevNet  = Get-NetBytes
$script:prevProc = Get-ProcTimes
$script:prevTime = [DateTime]::UtcNow

$update = {
    try {
        $now = [DateTime]::UtcNow
        $dt = ($now - $script:prevTime).TotalSeconds; if ($dt -le 0.1) { $dt = 1 }
        $script:prevTime = $now

        # CPU
        $cpu = [MiniDashNative]::Cpu()
        $rowCpu.Main.Text = '{0:N0}%' -f $cpu
        Set-Bar $rowCpu.Bar $cpu

        # Memory
        $m = [MiniDashNative]::Mem()
        $total = [double]$m[0]; $used = $total - [double]$m[1]
        $rowMem.Main.Text = '{0:N1}/{1:N0} GB' -f ($used / 1GB), ($total / 1GB)
        Set-Bar $rowMem.Bar ($(if ($total -gt 0) { 100 * $used / $total } else { 0 }))

        # GPU（使用率はタスクマネージャーと同じく、エンジン種別ごとの最大値）
        if ($gpuRows.Count -gt 0) {
            $gs = @(); try { $gs = @([MiniDashGpu]::Sample()) } catch {}
            foreach ($r in $gpuRows) {
                $g = $gs | Where-Object { $_.Luid -eq $r.Luid } | Select-Object -First 1
                if (-not $g) { continue }
                $r.Main.Text = '{0:N0}%' -f $g.Util
                if (-not $r.Integrated) { Set-Temp $r.Temp $g.TempC }
                $r.Extra.Text = if ($g.TotalBytes -ge 1GB) { '  {0:N1}/{1:N0}G' -f ($g.UsedBytes / 1GB), ($g.TotalBytes / 1GB) } else { '' }
                $r.Extra.Foreground = $dim
                Set-Bar $r.Bar $g.Util
                if ($g.Luid -eq $apuLuid) { Set-Temp $rowCpu.Temp $g.TempC }
            }
        }

        # Disk
        $d = New-Object System.IO.DriveInfo $sysDrive
        $rowDisk.Main.Text = '{0:N0} GB free' -f ($d.AvailableFreeSpace / 1GB)
        Set-Bar $rowDisk.Bar (100 * ($d.TotalSize - $d.AvailableFreeSpace) / $d.TotalSize)

        # Network
        $net = Get-NetBytes
        $down = [Math]::Max(0, ($net[0] - $script:prevNet[0]) / $dt)
        $up   = [Math]::Max(0, ($net[1] - $script:prevNet[1]) / $dt)
        $script:prevNet = $net
        $ui.NetText.Text = ([char]0x2193) + (Format-Rate $down) + '  ' + ([char]0x2191) + (Format-Rate $up)

        # Battery
        $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
        if (([int]$ps.BatteryChargeStatus -band 128) -eq 0) {
            $ui.BattRow.Visibility = 'Visible'
            $state = if ($ps.PowerLineStatus -eq 'Online') { ' (AC)' } else { '' }
            $ui.BattText.Text = ('{0:N0}%' -f ($ps.BatteryLifePercent * 100)) + $state
        } else { $ui.BattRow.Visibility = 'Collapsed' }

        # Top processes (同名プロセスは合算)
        $cur = Get-ProcTimes
        $byName = @{}
        foreach ($id in $cur.Keys) {
            if (-not $script:prevProc.ContainsKey($id)) { continue }
            $v = ($cur[$id][1] - $script:prevProc[$id][1]) / $dt / $cores * 100
            if ($v -le 0) { continue }
            $name = $cur[$id][0]
            if ($byName.ContainsKey($name)) { $byName[$name] += $v } else { $byName[$name] = $v }
        }
        $script:prevProc = $cur
        $top = $byName.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3
        $lines = foreach ($t in $top) {
            $n = $t.Key; if ($n.Length -gt 19) { $n = $n.Substring(0, 18) + [char]0x2026 }
            '{0,-20}{1,5:N1}%' -f $n, $t.Value
        }
        while (@($lines).Count -lt 3) { $lines = @($lines) + '' }
        $ui.ProcText.Text = ($lines -join "`n")
    } catch {
        Add-Content -Path $logFile -Value ("{0}  {1}" -f (Get-Date), $_)
    }
}

function Reset-Position {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $win.Left = $wa.Right - $win.ActualWidth - 10
    $win.Top  = $wa.Bottom - $win.ActualHeight - 10
    if (Test-Path $posFile) { Remove-Item $posFile -ErrorAction SilentlyContinue }
}
function Save-Position {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    Set-Content -Path $posFile -Value ($win.Left.ToString($inv) + ',' + $win.Top.ToString($inv))
}

$win.Add_Loaded({
    $placed = $false
    if (Test-Path $posFile) {
        $p = (Get-Content $posFile -Raw).Trim().Split(',')
        if ($p.Count -eq 2) {
            $inv = [Globalization.CultureInfo]::InvariantCulture
            $x = [double]::Parse($p[0], $inv); $y = [double]::Parse($p[1], $inv)
            $vl = [System.Windows.SystemParameters]::VirtualScreenLeft; $vt = [System.Windows.SystemParameters]::VirtualScreenTop
            $vw = [System.Windows.SystemParameters]::VirtualScreenWidth; $vh = [System.Windows.SystemParameters]::VirtualScreenHeight
            if ($x -ge $vl -and $y -ge $vt -and $x -lt ($vl + $vw - 50) -and $y -lt ($vt + $vh - 50)) {
                $win.Left = $x; $win.Top = $y; $placed = $true
            }
        }
    }
    if (-not $placed) { Reset-Position }
})

$win.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.ClickCount -eq 2) { Start-Process taskmgr.exe; return }
    try { $win.DragMove(); Save-Position } catch {}
})

# 右クリックメニュー
$menu = New-Object System.Windows.Controls.ContextMenu
$mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = 'タスクマネージャーを開く'
$mi.Add_Click({ Start-Process taskmgr.exe }); [void]$menu.Items.Add($mi)
$mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = '右下に戻す'
$mi.Add_Click({ Reset-Position }); [void]$menu.Items.Add($mi)
$mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = '常に手前に表示'; $mi.IsCheckable = $true; $mi.IsChecked = $true
$mi.Add_Click({ param($s, $e) $win.Topmost = $s.IsChecked }); [void]$menu.Items.Add($mi)
[void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
$mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = '閉じる'
$mi.Add_Click({ $win.Close() }); [void]$menu.Items.Add($mi)
$win.ContextMenu = $menu

# 予期しないエラーで落ちないようにし、原因をログに残す
$win.Dispatcher.Add_UnhandledException({
    param($s, $e)
    Add-Content -Path $logFile -Value ("{0}  UNHANDLED  {1}" -f (Get-Date), $e.Exception)
    $e.Handled = $true
})
$win.Add_Closed({ Add-Content -Path $logFile -Value ("{0}  closed" -f (Get-Date)) })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick($update)

& $update
$timer.Start()
[void]$win.ShowDialog()
$timer.Stop()
}
catch {
    Add-Content -Path $logFile -Value ("{0}  FATAL  {1}`n{2}" -f (Get-Date), $_, $_.ScriptStackTrace)
}
finally {
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
