# pstop.ps1  v5.7   a btop-style system monitor for Windows
# ---------------------------------------------------------------------------
# CPU (per core, with frequency), memory, disks (usage, throughput, busy,
# latency, queue), network throughput, GPU, TCP/UDP connections by process,
# kernel object counts, and a process tree you can sort, filter, inspect and
# kill. Single file, nothing to install.
#
# Sampling goes through the NT API rather than WMI: one syscall returns every
# process with its CPU, I/O, memory and handle figures, which is what Task
# Manager itself uses. GPU data comes from NVML directly, not by shelling out
# to nvidia-smi. The C# for all of it is embedded below and compiled at
# startup (about a second, once per session).
#
# CONFIG AND LOGS live in the SAME FOLDER AS THIS SCRIPT:
#   pstop.config.json    settings, written when you press w. If it is missing
#                        or unreadable, pstop starts with built-in defaults and
#                        says so. Delete it to reset.
#   pstop-alerts.log     threshold crossings, when alerts are on
#   pstop-metrics.csv    one row per sample, when -Log is given
#   pstop-diag.log       phase timings, when -Diag is given
#
# REQUIREMENTS
#   Windows x64, PowerShell 5.1 or 7+. Windows Terminal strongly preferred.
#   Elevation is optional. Without it a few protected processes show no owner.
#
# USAGE
#   .\pstop.ps1                      defaults, or whatever the config file says
#   .\pstop.ps1 -Interval 500        half-second refresh
#   .\pstop.ps1 -Theme nord          btop, nord, gruvbox, dracula, solarized,
#                                    default, matrix, ice, amber, mono
#   .\pstop.ps1 -Preset storage      full, minimal, network, storage, compute
#   .\pstop.ps1 -Graph block         graph symbols: braille (default), block, tty
#   .\pstop.ps1 -Mouse               click to select, wheel to scroll
#   .\pstop.ps1 -Log                 append a row per sample to pstop-metrics.csv
#   .\pstop.ps1 -Ascii               no Unicode block glyphs
#   .\pstop.ps1 -Diag                write phase timings, for debugging
#
# KEYS
#   up/down          move selection       pgup/pgdn  page
#   home/end         first / last
#   c m p n i h      sort: cpu mem pid name io handles
#   r                reverse sort
#   l                sort smoothing on/off (cpu lazy / cpu direct)
#   M                nest the disks box inside mem (btop style)
#   t                tree view
#   f                filter (type, Enter apply, Esc clear)
#   d                detail pane for the selected process
#   k                kill selected (asks first)
#   1 2 3 4          toggle cpu / mem / disk / net
#   g                cycle graph symbols (block, braille, tty)
#   T                cycle theme (btop, nord, gruvbox, dracula, solarized, ...)
#   5 6 7            toggle gpu / connections / kernel
#   P                cycle layout presets
#   a                alerts on/off
#   w                write current settings to pstop.config.json
#   + -              update interval up / down (ms)
#   space            pause
#   ?                help
#   q or Esc         quit
# ---------------------------------------------------------------------------

param(
    [int]$Interval = 0,
    [ValidateSet('','btop','nord','gruvbox','dracula','solarized','default','mono','matrix','ice','amber')]
    [string]$Theme = '',
    [ValidateSet('','full','minimal','network','storage','compute')]
    [string]$Preset = '',
    [ValidateSet('','braille','block','tty')]
    [string]$Graph = '',
    [string]$ConfigPath = '',
    [switch]$Mouse,
    [switch]$Log,
    [switch]$Diag,
    [switch]$Ascii,
    [switch]$NoConfig,
    [switch]$Plain
)

# Stop while setting up so a broken prerequisite is loud. The render loop drops
# this to Continue, so one failing counter cannot silently kill the display.
$ErrorActionPreference = 'Stop'
$AppVersion = '5.7'

if ([IntPtr]::Size -ne 8) {
    Write-Host 'pstop needs 64-bit PowerShell. Start powershell.exe from System32, not SysWOW64.' -ForegroundColor Red
    return
}

# ---------------------------------------------------------------------------
# Where things live: the folder this script was started from.
# ---------------------------------------------------------------------------

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    try { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition } catch { }
}
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'pstop.config.json' }
$AlertLog   = Join-Path $ScriptDir 'pstop-alerts.log'
$MetricsCsv = Join-Path $ScriptDir 'pstop-metrics.csv'
$DiagFile   = Join-Path $ScriptDir 'pstop-diag.log'

# ---------------------------------------------------------------------------
# Defaults, then config file, then command line. Last one wins.
# ---------------------------------------------------------------------------

function New-DefaultConfig {
    [pscustomobject]@{
        Interval  = 1000
        Theme     = 'btop'
        # braille is the highest resolution; it needs U+28xx in the console font,
        # so fall back with -Graph block or tty (or press g) if it renders as boxes.
        GraphSymbol = 'braille'
        Ascii     = $false
        Mouse     = $false
        SortKey   = 'cpu'
        SortDesc  = $true
        Tree      = $false
        Alerts    = $true
        # Sort cpu by a smoothed value so the list stops reshuffling every tick.
        # btop calls this "cpu lazy"; the percentages shown are still live.
        LazySort  = $true
        # disks nested inside the mem box, btop style. Off by default so the
        # layout does not change shape when the window is resized.
        CombineMemDisk = $false
        # GPU is off by default: utilisation, temperature, clock and the card
        # name already appear inside the cpu box, so the separate panel is
        # duplication that costs the left column a slot. Press 5 for the full
        # panel (VRAM, power, fan), then w to keep it.
        Panels    = [pscustomobject]@{
            Cpu = $true; Mem = $true; Disk = $true; Net = $true
            Gpu = $false; Conn = $false; Kernel = $false; Proc = $true
        }
        Thresholds = [pscustomobject]@{
            CpuPercent     = 90
            MemPercent     = 90
            DiskBusy       = 90
            ProcCpuPercent = 50
            ProcMemMB      = 4096
            SysHandles     = 500000
        }
        ConnLines = 8
    }
}

$ConfigStatus = 'defaults'
$cfg = New-DefaultConfig

if (-not $NoConfig -and (Test-Path $ConfigPath)) {
    try {
        $loaded = Get-Content $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        # merge shallowly so a config written by an older version still works
        foreach ($p in $loaded.PSObject.Properties) {
            if ($p.Name -eq 'Panels' -or $p.Name -eq 'Thresholds') {
                foreach ($q in $p.Value.PSObject.Properties) {
                    if ($cfg.($p.Name).PSObject.Properties.Name -contains $q.Name) {
                        $cfg.($p.Name).($q.Name) = $q.Value
                    }
                }
            } elseif ($cfg.PSObject.Properties.Name -contains $p.Name) {
                $cfg.($p.Name) = $p.Value
            }
        }
        $ConfigStatus = 'loaded'
    } catch {
        $ConfigStatus = 'unreadable, using defaults'
    }
}

# command line beats the file
if ($Interval -gt 0) { $cfg.Interval = $Interval }
if ($Theme)          { $cfg.Theme = $Theme }
if ($Ascii)          { $cfg.Ascii = $true }
if ($Mouse)          { $cfg.Mouse = $true }
if ($Graph)          { $cfg.GraphSymbol = $Graph }
if ($Ascii)          { $cfg.GraphSymbol = 'tty' }
$script:GraphMode = [string]$cfg.GraphSymbol
if ($script:GraphMode -notin @('braille','block','tty')) { $script:GraphMode = 'braille' }
$script:GlyphFull = '#'
$script:GlyphEmpty = '.'

if ($cfg.Interval -lt 250)   { $cfg.Interval = 250 }
if ($cfg.Interval -gt 60000) { $cfg.Interval = 60000 }

$Ascii = [bool]$cfg.Ascii

function Save-Config {
    try {
        $cfg.Interval = $state.Interval
        $cfg.SortKey  = $state.SortKey
        $cfg.SortDesc = $state.SortDesc
        $cfg.Tree     = $state.Tree
        $cfg.Alerts   = $state.Alerts
        $cfg.LazySort = $state.Lazy
        $cfg.CombineMemDisk = $state.Combine
        $cfg.GraphSymbol = $script:GraphMode
        $cfg.Theme = [string]$cfg.Theme
        $cfg.Panels.Cpu    = $state.ShowCpu
        $cfg.Panels.Mem    = $state.ShowMem
        $cfg.Panels.Disk   = $state.ShowDisk
        $cfg.Panels.Net    = $state.ShowNet
        $cfg.Panels.Gpu    = $state.ShowGpu
        $cfg.Panels.Conn   = $state.ShowConn
        $cfg.Panels.Kernel = $state.ShowKernel
        $cfg.Panels.Proc   = $state.ShowProc
        $cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------------------
# Native core
# ---------------------------------------------------------------------------

$CoreSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace PsTop20
{
    public static class Native
    {
        [DllImport("ntdll.dll")]
        internal static extern int NtQuerySystemInformation(
            int SystemInformationClass, IntPtr SystemInformation,
            int SystemInformationLength, out int ReturnLength);

        [DllImport("psapi.dll", SetLastError = true)]
        internal static extern bool GetPerformanceInfo(out PERFORMANCE_INFORMATION pPerformanceInformation, int cb);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        internal static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess,
            uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
            uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode,
            IntPtr lpInBuffer, uint nInBufferSize, IntPtr lpOutBuffer, uint nOutBufferSize,
            out uint lpBytesReturned, IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool CloseHandle(IntPtr hObject);

        [StructLayout(LayoutKind.Sequential)]
        public struct PERFORMANCE_INFORMATION
        {
            public int cb;
            public IntPtr CommitTotal;
            public IntPtr CommitLimit;
            public IntPtr CommitPeak;
            public IntPtr PhysicalTotal;
            public IntPtr PhysicalAvailable;
            public IntPtr SystemCache;
            public IntPtr KernelTotal;
            public IntPtr KernelPaged;
            public IntPtr KernelNonpaged;
            public IntPtr PageSize;
            public int HandleCount;
            public int ProcessCount;
            public int ThreadCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MEMORYSTATUSEX
        {
            public uint dwLength;
            public uint dwMemoryLoad;
            public ulong ullTotalPhys;
            public ulong ullAvailPhys;
            public ulong ullTotalPageFile;
            public ulong ullAvailPageFile;
            public ulong ullTotalVirtual;
            public ulong ullAvailVirtual;
            public ulong ullAvailExtendedVirtual;
        }

        public static bool Is64 { get { return IntPtr.Size == 8; } }
    }

    public static class Cpu
    {
        private const int SystemProcessorPerformanceInformation = 8;
        private const int STATUS_INFO_LENGTH_MISMATCH = unchecked((int)0xC0000004);
        private const int ENTRY = 48;

        private static long[] _prevIdle;
        private static long[] _prevKernel;
        private static long[] _prevUser;

        public static int LastStatus = 0;
        public static int CoreCount = 0;

        public static double[] Sample()
        {
            // The buffer length MUST be an exact multiple of the entry size. This
            // class rejects anything else with STATUS_INFO_LENGTH_MISMATCH, no
            // matter how large it is, so padding with spare bytes fails forever.
            // Grow by doubling the ENTRY COUNT, never the byte count.
            int n = Environment.ProcessorCount;
            if (n < 1) { n = 1; }

            IntPtr buf = IntPtr.Zero;
            int status = 0;
            int ret = 0;
            int len = 0;

            for (int attempt = 0; attempt < 8; attempt++)
            {
                len = ENTRY * n;
                buf = Marshal.AllocHGlobal(len);
                status = Native.NtQuerySystemInformation(
                    SystemProcessorPerformanceInformation, buf, len, out ret);
                if (status != STATUS_INFO_LENGTH_MISMATCH) { break; }
                Marshal.FreeHGlobal(buf);
                buf = IntPtr.Zero;
                n = n * 2;
                if (n > 2048) { break; }
            }

            LastStatus = status;

            if (status != 0)
            {
                if (buf != IntPtr.Zero) { Marshal.FreeHGlobal(buf); }
                return new double[Math.Max(1, CoreCount)];
            }

            int cores = ret / ENTRY;
            if (cores <= 0) { cores = Environment.ProcessorCount; }
            CoreCount = cores;
            double[] result = new double[cores];

            try
            {
                long[] idle = new long[cores];
                long[] kern = new long[cores];
                long[] user = new long[cores];

                for (int i = 0; i < cores; i++)
                {
                    long b = buf.ToInt64() + ((long)i * ENTRY);
                    idle[i] = Marshal.ReadInt64(new IntPtr(b + 0));
                    kern[i] = Marshal.ReadInt64(new IntPtr(b + 8));
                    user[i] = Marshal.ReadInt64(new IntPtr(b + 16));
                }

                if (_prevIdle != null && _prevIdle.Length == cores)
                {
                    for (int i = 0; i < cores; i++)
                    {
                        long dIdle = idle[i] - _prevIdle[i];
                        long dKern = kern[i] - _prevKernel[i];
                        long dUser = user[i] - _prevUser[i];
                        long total = dKern + dUser;
                        if (total > 0)
                        {
                            double busy = (double)(total - dIdle) / (double)total * 100.0;
                            if (busy < 0) { busy = 0; }
                            if (busy > 100) { busy = 100; }
                            result[i] = busy;
                        }
                    }
                }

                _prevIdle = idle; _prevKernel = kern; _prevUser = user;
            }
            finally { if (buf != IntPtr.Zero) { Marshal.FreeHGlobal(buf); } }

            return result;
        }
    }

    public static class Mem
    {
        public static object[] Sample()
        {
            Native.PERFORMANCE_INFORMATION pi = new Native.PERFORMANCE_INFORMATION();
            pi.cb = Marshal.SizeOf(typeof(Native.PERFORMANCE_INFORMATION));
            bool ok = Native.GetPerformanceInfo(out pi, pi.cb);

            Native.MEMORYSTATUSEX ms = new Native.MEMORYSTATUSEX();
            ms.dwLength = (uint)Marshal.SizeOf(typeof(Native.MEMORYSTATUSEX));
            Native.GlobalMemoryStatusEx(ref ms);

            long page = ok ? pi.PageSize.ToInt64() : 4096;

            return new object[] {
                (long)ms.ullTotalPhys,
                (long)ms.ullAvailPhys,
                ok ? pi.SystemCache.ToInt64() * page : 0L,
                ok ? pi.CommitTotal.ToInt64() * page : (long)(ms.ullTotalPageFile - ms.ullAvailPageFile),
                ok ? pi.CommitLimit.ToInt64() * page : (long)ms.ullTotalPageFile,
                ok ? pi.KernelPaged.ToInt64() * page : 0L,
                ok ? pi.KernelNonpaged.ToInt64() * page : 0L,
                ok ? pi.ProcessCount : 0,
                ok ? pi.ThreadCount : 0,
                ok ? pi.HandleCount : 0
            };
        }
    }

    public static class Procs
    {
        private const int SystemProcessInformation = 5;
        private const int STATUS_INFO_LENGTH_MISMATCH = unchecked((int)0xC0000004);

        private const int OFF_NEXT       = 0;
        private const int OFF_THREADS    = 4;
        private const int OFF_CREATE     = 32;
        private const int OFF_USERTIME   = 40;
        private const int OFF_KERNELTIME = 48;
        private const int OFF_NAME_LEN   = 56;
        private const int OFF_NAME_BUF   = 64;
        private const int OFF_PID        = 80;
        private const int OFF_PPID       = 88;
        private const int OFF_HANDLES    = 96;
        private const int OFF_SESSION    = 100;
        private const int OFF_WORKINGSET = 144;
        private const int OFF_PRIVATE    = 200;
        private const int OFF_READBYTES  = 232;
        private const int OFF_WRITEBYTES = 240;

        private static Dictionary<int, long> _prevCpu = new Dictionary<int, long>();
        private static Dictionary<int, long> _prevIo  = new Dictionary<int, long>();
        private static long _prevStamp = 0;

        public static int LastStatus = 0;

        public static List<object[]> Sample()
        {
            List<object[]> rows = new List<object[]>();
            if (!Native.Is64) { return rows; }

            int len = 1024 * 1024;
            IntPtr buf = IntPtr.Zero;
            int status = 0;

            for (int attempt = 0; attempt < 12; attempt++)
            {
                buf = Marshal.AllocHGlobal(len);
                int ret;
                status = Native.NtQuerySystemInformation(SystemProcessInformation, buf, len, out ret);
                if (status != STATUS_INFO_LENGTH_MISMATCH) { break; }
                Marshal.FreeHGlobal(buf);
                buf = IntPtr.Zero;
                len = (ret > len) ? ret + (256 * 1024) : len * 2;
                if (len > 128 * 1024 * 1024) { break; }
            }

            LastStatus = status;
            if (status != 0)
            {
                if (buf != IntPtr.Zero) { Marshal.FreeHGlobal(buf); }
                return rows;
            }

            long now = DateTime.UtcNow.Ticks;
            double elapsedSec = 0;
            if (_prevStamp > 0) { elapsedSec = (now - _prevStamp) / 10000000.0; }

            Dictionary<int, long> curCpu = new Dictionary<int, long>();
            Dictionary<int, long> curIo  = new Dictionary<int, long>();
            int cores = Environment.ProcessorCount;

            try
            {
                long p = buf.ToInt64();
                while (true)
                {
                    IntPtr b = new IntPtr(p);

                    int pid  = Marshal.ReadIntPtr(b, OFF_PID).ToInt32();
                    int ppid = Marshal.ReadIntPtr(b, OFF_PPID).ToInt32();
                    int threads  = Marshal.ReadInt32(b, OFF_THREADS);
                    int handles  = Marshal.ReadInt32(b, OFF_HANDLES);
                    int session  = Marshal.ReadInt32(b, OFF_SESSION);
                    long ws      = Marshal.ReadIntPtr(b, OFF_WORKINGSET).ToInt64();
                    long priv    = Marshal.ReadIntPtr(b, OFF_PRIVATE).ToInt64();
                    long ktime   = Marshal.ReadInt64(b, OFF_KERNELTIME);
                    long utime   = Marshal.ReadInt64(b, OFF_USERTIME);
                    long created = Marshal.ReadInt64(b, OFF_CREATE);
                    long rbytes  = Marshal.ReadInt64(b, OFF_READBYTES);
                    long wbytes  = Marshal.ReadInt64(b, OFF_WRITEBYTES);

                    string name = "";
                    short nameLen = Marshal.ReadInt16(b, OFF_NAME_LEN);
                    IntPtr namePtr = Marshal.ReadIntPtr(b, OFF_NAME_BUF);
                    if (namePtr != IntPtr.Zero && nameLen > 0)
                    {
                        name = Marshal.PtrToStringUni(namePtr, nameLen / 2);
                    }
                    if (string.IsNullOrEmpty(name))
                    {
                        name = (pid == 4) ? "System" : "?";
                    }

                    long cpuTicks = ktime + utime;
                    curCpu[pid] = cpuTicks;

                    double cpuPct = 0;
                    if (elapsedSec > 0 && _prevCpu.ContainsKey(pid))
                    {
                        long d = cpuTicks - _prevCpu[pid];
                        if (d > 0)
                        {
                            cpuPct = (d / 10000000.0) / elapsedSec / cores * 100.0;
                            if (cpuPct < 0) { cpuPct = 0; }
                            if (cpuPct > 100) { cpuPct = 100; }
                        }
                    }

                    long io = rbytes + wbytes;
                    curIo[pid] = io;
                    double ioRate = 0;
                    if (elapsedSec > 0 && _prevIo.ContainsKey(pid))
                    {
                        long d = io - _prevIo[pid];
                        if (d > 0) { ioRate = d / elapsedSec; }
                    }

                    if (pid != 0)
                    {
                        rows.Add(new object[] {
                            pid, ppid, name, threads, handles, ws, priv,
                            cpuPct, ioRate, created, session, io
                        });
                    }

                    int next = Marshal.ReadInt32(b, OFF_NEXT);
                    if (next == 0) { break; }
                    p += next;
                }
            }
            finally { if (buf != IntPtr.Zero) { Marshal.FreeHGlobal(buf); } }

            _prevCpu = curCpu;
            _prevIo = curIo;
            _prevStamp = now;
            return rows;
        }
    }

    public static class Disk
    {
        private const uint IOCTL_DISK_PERFORMANCE = 0x00070020;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_SHARE_READ = 1;
        private const uint FILE_SHARE_WRITE = 2;

        // DISK_PERFORMANCE offsets
        private const int O_BYTESREAD  = 0;
        private const int O_BYTESWRITE = 8;
        private const int O_READTIME   = 16;
        private const int O_WRITETIME  = 24;
        private const int O_IDLETIME   = 32;
        private const int O_READCOUNT  = 40;
        private const int O_WRITECOUNT = 44;
        private const int O_QUEUEDEPTH = 48;
        private const int O_QUERYTIME  = 56;

        private static Dictionary<string, long[]> _prev = new Dictionary<string, long[]>();

        // Per drive letter: readBps, writeBps, busyPercent, avgLatencyMs, queueDepth
        public static Dictionary<string, double[]> Sample(string[] driveLetters)
        {
            Dictionary<string, double[]> result = new Dictionary<string, double[]>();
            Dictionary<string, long[]> cur = new Dictionary<string, long[]>();

            foreach (string dl in driveLetters)
            {
                string letter = dl.TrimEnd('\\', ':');
                string path = "\\\\.\\" + letter + ":";
                IntPtr h = Native.CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                              IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                if (h == IntPtr.Zero || h.ToInt64() == -1) { continue; }

                IntPtr outBuf = Marshal.AllocHGlobal(256);
                try
                {
                    uint returned;
                    bool ok = Native.DeviceIoControl(h, IOCTL_DISK_PERFORMANCE, IntPtr.Zero, 0,
                                                     outBuf, 256, out returned, IntPtr.Zero);
                    if (!ok) { continue; }

                    long br = Marshal.ReadInt64(outBuf, O_BYTESREAD);
                    long bw = Marshal.ReadInt64(outBuf, O_BYTESWRITE);
                    long rt = Marshal.ReadInt64(outBuf, O_READTIME);
                    long wt = Marshal.ReadInt64(outBuf, O_WRITETIME);
                    long it = Marshal.ReadInt64(outBuf, O_IDLETIME);
                    int  rc = Marshal.ReadInt32(outBuf, O_READCOUNT);
                    int  wc = Marshal.ReadInt32(outBuf, O_WRITECOUNT);
                    int  qd = Marshal.ReadInt32(outBuf, O_QUEUEDEPTH);
                    long qt = Marshal.ReadInt64(outBuf, O_QUERYTIME);

                    cur[letter] = new long[] { br, bw, rt, wt, it, rc, wc, qt };

                    if (_prev.ContainsKey(letter))
                    {
                        long[] p = _prev[letter];
                        // QueryTime is the device's own clock, so the interval comes
                        // from the counters themselves rather than wall time.
                        double span = (qt - p[7]) / 10000000.0;
                        if (span <= 0) { span = 0.0001; }

                        double r = (br - p[0]) / span;
                        double w = (bw - p[1]) / span;
                        if (r < 0) { r = 0; }
                        if (w < 0) { w = 0; }

                        double busy = 0;
                        long idleDelta = it - p[4];
                        long spanTicks = qt - p[7];
                        if (spanTicks > 0)
                        {
                            busy = (1.0 - ((double)idleDelta / (double)spanTicks)) * 100.0;
                            if (busy < 0) { busy = 0; }
                            if (busy > 100) { busy = 100; }
                        }

                        double lat = 0;
                        long ops = (rc - p[5]) + (wc - p[6]);
                        if (ops > 0)
                        {
                            long svc = (rt - p[2]) + (wt - p[3]);
                            lat = (svc / (double)ops) / 10000.0;   // 100ns ticks to ms
                            if (lat < 0) { lat = 0; }
                        }

                        result[letter] = new double[] { r, w, busy, lat, qd };
                    }
                    else { result[letter] = new double[] { 0, 0, 0, 0, qd }; }
                }
                finally
                {
                    Marshal.FreeHGlobal(outBuf);
                    Native.CloseHandle(h);
                }
            }

            _prev = cur;
            return result;
        }
    }


    // ------------------------------------------------------------- CPU FREQ

    public static class Power
    {
        [DllImport("powrprof.dll")]
        private static extern int CallNtPowerInformation(int InformationLevel,
            IntPtr InputBuffer, int InputBufferLength, IntPtr OutputBuffer, int OutputBufferLength);

        private const int ProcessorInformation = 11;
        private const int ENTRY = 24; // Number, MaxMhz, CurrentMhz, MhzLimit, MaxIdle, CurIdle

        // Returns {currentMhz[], maxMhz[]}
        public static object[] CoreFreq(int cores)
        {
            int[] cur = new int[cores];
            int[] max = new int[cores];
            int len = ENTRY * cores;
            IntPtr buf = Marshal.AllocHGlobal(len);
            try
            {
                int status = CallNtPowerInformation(ProcessorInformation, IntPtr.Zero, 0, buf, len);
                if (status == 0)
                {
                    for (int i = 0; i < cores; i++)
                    {
                        int off = i * ENTRY;
                        max[i] = Marshal.ReadInt32(buf, off + 4);
                        cur[i] = Marshal.ReadInt32(buf, off + 8);
                    }
                }
            }
            catch { }
            finally { Marshal.FreeHGlobal(buf); }
            return new object[] { cur, max };
        }
    }

    // ---------------------------------------------------------- CONNECTIONS

    public static class Conn
    {
        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern int GetExtendedTcpTable(IntPtr pTcpTable, ref int pdwSize,
            bool bOrder, int ulAf, int TableClass, int Reserved);

        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern int GetExtendedUdpTable(IntPtr pUdpTable, ref int pdwSize,
            bool bOrder, int ulAf, int TableClass, int Reserved);

        private const int AF_INET = 2;
        private const int TCP_TABLE_OWNER_PID_ALL = 5;
        private const int UDP_TABLE_OWNER_PID = 1;

        private static readonly string[] States = new string[] {
            "", "CLOSED", "LISTEN", "SYN_SENT", "SYN_RCVD", "ESTABLISHED", "FIN_WAIT1",
            "FIN_WAIT2", "CLOSE_WAIT", "CLOSING", "LAST_ACK", "TIME_WAIT", "DELETE_TCB"
        };

        private static string Ip(uint addr)
        {
            return string.Format("{0}.{1}.{2}.{3}",
                addr & 0xFF, (addr >> 8) & 0xFF, (addr >> 16) & 0xFF, (addr >> 24) & 0xFF);
        }

        private static int Port(uint raw)
        {
            // stored network byte order in the low 16 bits
            return (int)(((raw & 0xFF) << 8) | ((raw >> 8) & 0xFF));
        }

        // rows: proto, local, remote, state, pid
        public static List<object[]> Sample()
        {
            List<object[]> rows = new List<object[]>();

            // --- TCP
            int size = 0;
            GetExtendedTcpTable(IntPtr.Zero, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0);
            if (size > 0)
            {
                IntPtr buf = Marshal.AllocHGlobal(size);
                try
                {
                    if (GetExtendedTcpTable(buf, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0) == 0)
                    {
                        int n = Marshal.ReadInt32(buf, 0);
                        for (int i = 0; i < n; i++)
                        {
                            int off = 4 + (i * 24);
                            uint st = (uint)Marshal.ReadInt32(buf, off + 0);
                            uint la = (uint)Marshal.ReadInt32(buf, off + 4);
                            uint lp = (uint)Marshal.ReadInt32(buf, off + 8);
                            uint ra = (uint)Marshal.ReadInt32(buf, off + 12);
                            uint rp = (uint)Marshal.ReadInt32(buf, off + 16);
                            int pid = Marshal.ReadInt32(buf, off + 20);
                            string state = (st < States.Length) ? States[st] : st.ToString();
                            rows.Add(new object[] {
                                "TCP",
                                Ip(la) + ":" + Port(lp),
                                Ip(ra) + ":" + Port(rp),
                                state, pid
                            });
                        }
                    }
                }
                finally { Marshal.FreeHGlobal(buf); }
            }

            // --- UDP
            size = 0;
            GetExtendedUdpTable(IntPtr.Zero, ref size, false, AF_INET, UDP_TABLE_OWNER_PID, 0);
            if (size > 0)
            {
                IntPtr buf = Marshal.AllocHGlobal(size);
                try
                {
                    if (GetExtendedUdpTable(buf, ref size, false, AF_INET, UDP_TABLE_OWNER_PID, 0) == 0)
                    {
                        int n = Marshal.ReadInt32(buf, 0);
                        for (int i = 0; i < n; i++)
                        {
                            int off = 4 + (i * 12);
                            uint la = (uint)Marshal.ReadInt32(buf, off + 0);
                            uint lp = (uint)Marshal.ReadInt32(buf, off + 4);
                            int pid = Marshal.ReadInt32(buf, off + 8);
                            rows.Add(new object[] {
                                "UDP", Ip(la) + ":" + Port(lp), "*:*", "", pid
                            });
                        }
                    }
                }
                finally { Marshal.FreeHGlobal(buf); }
            }

            return rows;
        }
    }

    // ----------------------------------------------------------- PROC INFO

    public static class ProcInfo
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(int access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool QueryFullProcessImageNameW(IntPtr h, int flags,
            StringBuilder buf, ref int size);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr h, int access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetTokenInformation(IntPtr token, int cls,
            IntPtr info, int len, out int retLen);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool LookupAccountSidW(string sys, IntPtr sid,
            StringBuilder name, ref int cchName, StringBuilder domain, ref int cchDomain, out int use);

        private const int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const int TOKEN_QUERY = 0x0008;
        private const int TokenUser = 1;

        public static string ImagePath(int pid)
        {
            IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) { return ""; }
            try
            {
                StringBuilder sb = new StringBuilder(1024);
                int size = sb.Capacity;
                if (QueryFullProcessImageNameW(h, 0, sb, ref size)) { return sb.ToString(); }
                return "";
            }
            finally { CloseHandle(h); }
        }

        public static string Owner(int pid)
        {
            IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) { return ""; }
            IntPtr token = IntPtr.Zero;
            try
            {
                if (!OpenProcessToken(h, TOKEN_QUERY, out token)) { return ""; }
                int len = 0;
                GetTokenInformation(token, TokenUser, IntPtr.Zero, 0, out len);
                if (len <= 0) { return ""; }
                IntPtr info = Marshal.AllocHGlobal(len);
                try
                {
                    if (!GetTokenInformation(token, TokenUser, info, len, out len)) { return ""; }
                    IntPtr sid = Marshal.ReadIntPtr(info);
                    StringBuilder name = new StringBuilder(256);
                    StringBuilder dom = new StringBuilder(256);
                    int cn = name.Capacity, cd = dom.Capacity, use;
                    if (LookupAccountSidW(null, sid, name, ref cn, dom, ref cd, out use))
                    {
                        return dom.ToString() + "\\" + name.ToString();
                    }
                    return "";
                }
                finally { Marshal.FreeHGlobal(info); }
            }
            catch { return ""; }
            finally
            {
                if (token != IntPtr.Zero) { CloseHandle(token); }
                CloseHandle(h);
            }
        }
    }

    // ----------------------------------------------------------------- GPU

    public static class Gpu
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr LoadLibraryW(string path);

        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "nvmlInit_v2")]
        private static extern int nvmlInit();
        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "nvmlShutdown")]
        private static extern int nvmlShutdown();
        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "nvmlDeviceGetCount_v2")]
        private static extern int nvmlDeviceGetCount(out uint count);
        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "nvmlDeviceGetHandleByIndex_v2")]
        private static extern int nvmlDeviceGetHandleByIndex(uint index, out IntPtr device);
        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "nvmlDeviceGetName")]
        private static extern int nvmlDeviceGetName(IntPtr device, StringBuilder name, uint length);
        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "nvmlDeviceGetUtilizationRates")]
        private static extern int nvmlDeviceGetUtilizationRates(IntPtr device, out Utilization util);
        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "nvmlDeviceGetMemoryInfo")]
        private static extern int nvmlDeviceGetMemoryInfo(IntPtr device, out MemInfo mem);
        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "nvmlDeviceGetTemperature")]
        private static extern int nvmlDeviceGetTemperature(IntPtr device, uint sensorType, out uint temp);
        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "nvmlDeviceGetPowerUsage")]
        private static extern int nvmlDeviceGetPowerUsage(IntPtr device, out uint milliwatts);
        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "nvmlDeviceGetClockInfo")]
        private static extern int nvmlDeviceGetClockInfo(IntPtr device, uint type, out uint clock);
        [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint = "nvmlDeviceGetFanSpeed")]
        private static extern int nvmlDeviceGetFanSpeed(IntPtr device, out uint speed);

        [StructLayout(LayoutKind.Sequential)]
        public struct Utilization { public uint Gpu; public uint Memory; }

        [StructLayout(LayoutKind.Sequential)]
        public struct MemInfo { public ulong Total; public ulong Free; public ulong Used; }

        public static bool Available = false;
        public static string LastError = "";

        private static bool _tried = false;

        // NVML does not always sit on PATH, so probe the usual install locations
        // before the first DllImport resolves the name.
        public static bool Init()
        {
            if (_tried) { return Available; }
            _tried = true;

            string[] candidates = new string[] {
                @"C:\Windows\System32\nvml.dll",
                @"C:\Program Files\NVIDIA Corporation\NVSMI\nvml.dll",
                @"C:\Program Files\NVIDIA Corporation\NVSMI\nvml.dll"
            };
            foreach (string c in candidates)
            {
                try { if (System.IO.File.Exists(c)) { LoadLibraryW(c); break; } } catch { }
            }

            try
            {
                int rc = nvmlInit();
                if (rc != 0) { LastError = "nvmlInit rc=" + rc; return false; }
                Available = true;
                return true;
            }
            catch (Exception ex) { LastError = ex.Message; return false; }
        }

        // rows: name, gpuUtil, memUtil, memUsed, memTotal, tempC, powerW, clockMhz, fanPct
        public static List<object[]> Sample()
        {
            List<object[]> rows = new List<object[]>();
            if (!Available && !Init()) { return rows; }

            uint count = 0;
            try { if (nvmlDeviceGetCount(out count) != 0) { return rows; } }
            catch { Available = false; return rows; }

            for (uint i = 0; i < count; i++)
            {
                IntPtr dev;
                if (nvmlDeviceGetHandleByIndex(i, out dev) != 0) { continue; }

                StringBuilder nm = new StringBuilder(96);
                if (nvmlDeviceGetName(dev, nm, 96) != 0) { nm.Append("GPU " + i); }

                Utilization u = new Utilization();
                nvmlDeviceGetUtilizationRates(dev, out u);

                MemInfo m = new MemInfo();
                nvmlDeviceGetMemoryInfo(dev, out m);

                uint temp = 0;  nvmlDeviceGetTemperature(dev, 0, out temp);
                uint mw = 0;    nvmlDeviceGetPowerUsage(dev, out mw);
                uint clk = 0;   nvmlDeviceGetClockInfo(dev, 0, out clk);   // 0 = graphics
                uint fan = 0;   nvmlDeviceGetFanSpeed(dev, out fan);

                rows.Add(new object[] {
                    nm.ToString(), (int)u.Gpu, (int)u.Memory,
                    (long)m.Used, (long)m.Total,
                    (int)temp, mw / 1000.0, (int)clk, (int)fan
                });
            }
            return rows;
        }
    }
}
'@

Write-Host 'pstop: compiling native core...' -ForegroundColor DarkGray
try {
    if (-not ('PsTop20.Procs' -as [type])) {
        Add-Type -TypeDefinition $CoreSource -Language CSharp -ErrorAction Stop
    }
} catch {
    Write-Host ''
    Write-Host 'Failed to compile the native core:' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------------------
# Console
# ---------------------------------------------------------------------------

$ESC = [char]27

$VtSource = @'
using System;
using System.Runtime.InteropServices;
public static class VtMode20 {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    const int STD_OUTPUT = -11;
    const int STD_INPUT  = -10;
    const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;
    const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
    const uint ENABLE_EXTENDED_FLAGS  = 0x0080;
    const uint ENABLE_MOUSE_INPUT     = 0x0010;
    const uint ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
    const uint ENABLE_LINE_INPUT   = 0x0002;
    const uint ENABLE_ECHO_INPUT   = 0x0004;
    const uint ENABLE_PROCESSED_INPUT = 0x0001;

    public static uint SavedInputMode = 0;
    public static bool HadQuickEdit = false;

    public static bool EnableVt() {
        IntPtr h = GetStdHandle(STD_OUTPUT);
        uint mode;
        if (!GetConsoleMode(h, out mode)) { return false; }
        return SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }

    // QuickEdit is on by default. A click or drag inside the window then puts the
    // console into selection mode, which BLOCKS every write until the user presses
    // Esc or right-clicks. To anyone watching, the program has frozen.
    public static bool PrepareInput(bool wantMouse) {
        IntPtr h = GetStdHandle(STD_INPUT);
        uint mode;
        if (!GetConsoleMode(h, out mode)) { return false; }
        SavedInputMode = mode;
        HadQuickEdit = (mode & ENABLE_QUICK_EDIT_MODE) != 0;

        uint want = mode & ~ENABLE_QUICK_EDIT_MODE & ~ENABLE_LINE_INPUT & ~ENABLE_ECHO_INPUT;
        want |= ENABLE_EXTENDED_FLAGS;
        if (wantMouse) {
            // Mouse events only arrive as VT escape sequences when VT input is on,
            // which also turns every key into a sequence. The reader handles both.
            want |= ENABLE_MOUSE_INPUT | ENABLE_VIRTUAL_TERMINAL_INPUT;
            want &= ~ENABLE_PROCESSED_INPUT;
        } else {
            want &= ~ENABLE_MOUSE_INPUT;
            want &= ~ENABLE_VIRTUAL_TERMINAL_INPUT;
        }
        return SetConsoleMode(h, want);
    }

    public static bool RestoreInput() {
        if (SavedInputMode == 0) { return false; }
        IntPtr h = GetStdHandle(STD_INPUT);
        return SetConsoleMode(h, SavedInputMode);
    }
}
'@
if (-not ('VtMode20' -as [type])) {
    try { Add-Type -TypeDefinition $VtSource -Language CSharp -ErrorAction Stop } catch { }
}
try { [VtMode20]::EnableVt() | Out-Null } catch { }
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:MouseOn = [bool]$cfg.Mouse
$script:QuickEditWasOn = $false
try {
    [VtMode20]::PrepareInput($script:MouseOn) | Out-Null
    $script:QuickEditWasOn = [VtMode20]::HadQuickEdit
} catch { }

# Only the full block and the light shade are used for graphs: the partial block
# glyphs U+2581..U+2587 are missing from many console fonts and render as empty
# boxes. Vertical resolution comes from stacking rows instead.
$GL = @{
    TL = [char]0x256D; TR = [char]0x256E; BL = [char]0x2570; BR = [char]0x256F
    H  = [char]0x2500; V  = [char]0x2502
    Full = [char]0x2588; Shade = [char]0x2591; Med = [char]0x2592
    Upper = [char]0x2580; Lower = [char]0x2584
    Dot = [char]0x00B7; Tri = [char]0x25B8
    TreeBranch = [char]0x251C; TreeLast = [char]0x2514; TreeLine = [char]0x2500; TreeVert = [char]0x2502
}
if ($Ascii -or $Plain) {
    $GL.TL='+';$GL.TR='+';$GL.BL='+';$GL.BR='+';$GL.H='-';$GL.V='|'
    $GL.Full='#';$GL.Shade='.';$GL.Med=':';$GL.Dot='.';$GL.Tri='>'
    $GL.Upper='"';$GL.Lower='_'
    $GL.TreeBranch='+';$GL.TreeLast='\';$GL.TreeLine='-';$GL.TreeVert='|'
}

function New-Theme {
    param([string]$Name)
    switch ($Name) {
        # --- btop default: maroon frame, white text, green to red load ramp,
        #     blue for the secondary figures (temps, frequency, user)
        'btop' {
            @{ Ramp = @(28,34,40,46,82,118,154,190,208,196)
               Frame=88; Title=231; Text=252; Dim=245; Faint=240
               Accent=203; Accent2=75; Good=46; Warn=226; Bad=196; Sel=236 }
        }
        # --- nord: cool arctic blues, muted and low contrast
        'nord' {
            @{ Ramp = @(24,31,38,44,109,110,111,150,180,174)
               Frame=239; Title=189; Text=152; Dim=103; Faint=60
               Accent=110; Accent2=109; Good=108; Warn=222; Bad=174; Sel=238 }
        }
        # --- gruvbox: warm retro, cream on dark brown
        'gruvbox' {
            @{ Ramp = @(100,106,142,143,172,173,208,209,167,124)
               Frame=237; Title=223; Text=187; Dim=246; Faint=243
               Accent=208; Accent2=109; Good=142; Warn=214; Bad=167; Sel=237 }
        }
        # --- dracula: purple frame, vivid pink and cyan
        'dracula' {
            @{ Ramp = @(61,62,63,69,81,84,120,186,215,212)
               Frame=60; Title=189; Text=253; Dim=103; Faint=61
               Accent=212; Accent2=117; Good=84; Warn=228; Bad=203; Sel=237 }
        }
        # --- solarized dark: the classic low-glare palette
        'solarized' {
            @{ Ramp = @(23,29,30,36,37,64,100,136,166,160)
               Frame=23; Title=230; Text=245; Dim=240; Faint=236
               Accent=33; Accent2=37; Good=64; Warn=136; Bad=160; Sel=235 }
        }
        'mono' {
            @{ Ramp = @(240,244,248,250,252,253,254,255,255,255)
               Frame=236; Title=255; Text=252; Dim=244; Faint=240
               Accent=255; Accent2=250; Good=252; Warn=254; Bad=255; Sel=238 }
        }
        'matrix' {
            @{ Ramp = @(22,28,34,40,46,82,118,154,190,226)
               Frame=22; Title=46; Text=41; Dim=28; Faint=22
               Accent=46; Accent2=40; Good=46; Warn=190; Bad=226; Sel=22 }
        }
        'ice' {
            @{ Ramp = @(24,25,31,38,44,45,51,87,123,159)
               Frame=236; Title=123; Text=152; Dim=67; Faint=60
               Accent=81; Accent2=45; Good=79; Warn=117; Bad=213; Sel=24 }
        }
        'amber' {
            @{ Ramp = @(52,88,130,166,172,178,184,214,220,226)
               Frame=235; Title=222; Text=180; Dim=137; Faint=95
               Accent=214; Accent2=178; Good=142; Warn=214; Bad=203; Sel=236 }
        }
        default {
            @{ Ramp = @(79,78,114,150,186,222,216,209,203,197)
               Frame=237; Title=255; Text=252; Dim=245; Faint=240
               Accent=80; Accent2=140; Good=114; Warn=222; Bad=203; Sel=237 }
        }
    }
}
function Fg { param([int]$N) "${ESC}[38;5;${N}m" }
function Bg { param([int]$N) "${ESC}[48;5;${N}m" }

$RS = "${ESC}[0m"
$BOLD = "${ESC}[1m"
if ($Plain) { $RS = ''; $BOLD = '' }

# Themes are applied through a function so 'T' can switch them at runtime
# without restarting: every colour variable is rebuilt from the palette.
function Apply-Theme {
    param([string]$Name)
    $script:TH = New-Theme $Name
    $script:CFrame  = Fg $TH.Frame
    $script:CTitle  = Fg $TH.Title
    $script:CText   = Fg $TH.Text
    $script:CDim    = Fg $TH.Dim
    $script:CFaint  = Fg $TH.Faint
    $script:CAccent = Fg $TH.Accent
    $script:CAcc2   = Fg $TH.Accent2
    $script:CGood   = Fg $TH.Good
    $script:CWarn   = Fg $TH.Warn
    $script:CBad    = Fg $TH.Bad
    $script:CSelBg  = Bg $TH.Sel
    $script:RampFg = @()
    foreach ($n in $TH.Ramp) { $script:RampFg += (Fg $n) }
    if ($Plain) {
        $script:CFrame=''; $script:CTitle=''; $script:CText=''; $script:CDim=''
        $script:CFaint=''; $script:CAccent=''; $script:CAcc2=''; $script:CGood=''
        $script:CWarn=''; $script:CBad=''; $script:CSelBg=''
        for ($i=0; $i -lt $script:RampFg.Count; $i++) { $script:RampFg[$i] = '' }
    }
}

Apply-Theme $cfg.Theme

# ---------------------------------------------------------------------------
# Drawing primitives
# ---------------------------------------------------------------------------

function Get-VisLen {
    param([string]$S)
    if (-not $S) { return 0 }
    return ($S -replace "$ESC\[[0-9;?]*[a-zA-Z]", '').Length
}

function Pad-Vis {
    param([string]$S, [int]$W)
    $v = Get-VisLen $S
    if ($v -ge $W) { return $S }
    return $S + (' ' * ($W - $v))
}

# Pads OR truncates to an exact visible width, keeping colour codes intact.
# Pad-Vis alone only grows a string, so one row wider than its box punched a
# hole straight through the border. Every box row goes through this instead, so
# a width miscalculation can spoil a row but never the frame.
function Fit-Vis {
    param([string]$S, [int]$W)
    if ($W -le 0) { return '' }
    $v = Get-VisLen $S
    if ($v -eq $W) { return $S }
    if ($v -lt $W) { return $S + (' ' * ($W - $v)) }

    $sb = New-Object System.Text.StringBuilder
    $seen = 0
    $i = 0
    while ($i -lt $S.Length -and $seen -lt $W) {
        if ($S[$i] -eq $ESC) {
            $j = $i + 1
            while ($j -lt $S.Length -and $S[$j] -notmatch '[a-zA-Z]') { $j++ }
            [void]$sb.Append($S.Substring($i, [math]::Min($j - $i + 1, $S.Length - $i)))
            $i = $j + 1
            continue
        }
        [void]$sb.Append($S[$i])
        $seen++
        $i++
    }
    [void]$sb.Append($RS)
    return $sb.ToString()
}

function Trunc-Vis {
    param([string]$S, [int]$W)
    if (-not $S) { return '' }
    if ($S.Length -le $W) { return $S }
    if ($W -le 1) { return '' }
    return $S.Substring(0, $W - 1) + $GL.Dot
}

function Ramp-Colour {
    param([double]$Frac)
    if ($Frac -lt 0) { $Frac = 0 }
    if ($Frac -gt 1) { $Frac = 1 }
    $i = [int][math]::Floor($Frac * $RampFg.Count)
    if ($i -ge $RampFg.Count) { $i = $RampFg.Count - 1 }
    return $RampFg[$i]
}

# The symbol set applies to meters as well as graphs, so pressing g changes the
# whole display rather than only the two history graphs. Recomputed on change
# rather than per call: Bar runs a few hundred times a frame.
function Set-Glyphs {
    if ($Ascii -or $Plain) {
        $script:GlyphFull = $GL.Full; $script:GlyphEmpty = $GL.Shade
        return
    }
    switch ($script:GraphMode) {
        'braille' { $script:GlyphFull = [char]0x28FF; $script:GlyphEmpty = [char]0x2801 }
        'tty'     { $script:GlyphFull = '#';          $script:GlyphEmpty = '.' }
        default   { $script:GlyphFull = $GL.Full;     $script:GlyphEmpty = $GL.Shade }
    }
}

function Bar {
    param([double]$Frac, [int]$W, [string]$Flat = '')
    if ($W -lt 1) { return '' }
    if ($Frac -lt 0) { $Frac = 0 }
    if ($Frac -gt 1) { $Frac = 1 }
    $fill = [int][math]::Round($Frac * $W)
    $sb = New-Object System.Text.StringBuilder
    $last = ''
    for ($i = 0; $i -lt $W; $i++) {
        if ($i -lt $fill) {
            $c = $Flat
            if (-not $c) { $c = Ramp-Colour ($i / [double]$W) }
            if ($c -ne $last) { [void]$sb.Append($c); $last = $c }
            [void]$sb.Append($script:GlyphFull)
        } else {
            if ($last -ne $CFaint) { [void]$sb.Append($CFaint); $last = $CFaint }
            [void]$sb.Append($script:GlyphEmpty)
        }
    }
    [void]$sb.Append($RS)
    return $sb.ToString()
}

# Graph renderer with three symbol sets, the same trade-off btop offers:
#
#   braille  4 sub-rows and 2 samples per cell - the highest resolution, but
#            U+28xx is missing from some console fonts
#   block    2 sub-rows per cell using the upper and lower half blocks
#   tty      1 sub-row, two symbols, works with essentially any font
#
# Resolution comes from sub-dividing each cell, so a 3-row braille graph has 12
# vertical steps where a 3-row tty graph has 3.
function Graph-Rows {
    param($Values, [int]$W, [int]$Rows, [double]$Max = 0)
    if ($Rows -lt 1 -or $W -lt 1) { return @() }

    $mode = $script:GraphMode
    $perCell = 1
    $subRows = 1
    if ($mode -eq 'braille') { $perCell = 2; $subRows = 4 }
    elseif ($mode -eq 'block') { $subRows = 2 }

    $need = $W * $perCell
    $vals = @($Values | Select-Object -Last $need)

    $peak = $Max
    if ($peak -le 0) {
        $peak = 0
        foreach ($v in $vals) { if ($v -gt $peak) { $peak = $v } }
    }
    if ($peak -le 0) { $peak = 1 }

    $levels = $Rows * $subRows
    $heights = New-Object 'System.Collections.Generic.List[int]'
    $fracs   = New-Object 'System.Collections.Generic.List[double]'
    # pad the left so the newest sample sits at the right edge
    for ($i = 0; $i -lt ($need - $vals.Count); $i++) { $heights.Add(0); $fracs.Add(-1) }
    foreach ($v in $vals) {
        $f = $v / $peak
        if ($f -lt 0) { $f = 0 }
        if ($f -gt 1) { $f = 1 }
        $fracs.Add($f)
        $heights.Add([int][math]::Round($f * $levels))
    }

    # braille dot bits, top to bottom, left column then right column
    $bitsL = @(0x01, 0x02, 0x04, 0x40)
    $bitsR = @(0x08, 0x10, 0x20, 0x80)

    $lines = @()
    for ($r = 0; $r -lt $Rows; $r++) {
        # sub-row index of the top of this row, counting from the bottom
        $rowBase = ($Rows - $r - 1) * $subRows
        $sb = New-Object System.Text.StringBuilder
        $last = ''

        for ($c = 0; $c -lt $W; $c++) {
            if ($mode -eq 'braille') {
                $i0 = $c * 2
                $i1 = $i0 + 1
                $h0 = $heights[$i0]; $h1 = $heights[$i1]
                $f0 = $fracs[$i0];   $f1 = $fracs[$i1]

                $mask = 0
                for ($s = 0; $s -lt 4; $s++) {
                    $sub = $rowBase + (3 - $s)          # $s 0 = top of the cell
                    if ($h0 -gt $sub) { $mask = $mask -bor $bitsL[$s] }
                    if ($h1 -gt $sub) { $mask = $mask -bor $bitsR[$s] }
                }
                $col = $CFaint
                $fmax = [math]::Max($f0, $f1)
                if ($mask -ne 0) { $col = Ramp-Colour $fmax }
                if ($col -ne $last) { [void]$sb.Append($col); $last = $col }
                if ($mask -eq 0) { [void]$sb.Append($script:GlyphEmpty) }
                else { [void]$sb.Append([char](0x2800 + $mask)) }
            }
            elseif ($mode -eq 'block') {
                $h = $heights[$c]; $f = $fracs[$c]
                $top = ($h -gt ($rowBase + 1))
                $bot = ($h -gt $rowBase)
                $col = $CFaint
                if ($bot) { $col = Ramp-Colour $f }
                if ($col -ne $last) { [void]$sb.Append($col); $last = $col }
                if ($top -and $bot)  { [void]$sb.Append($GL.Full) }
                elseif ($bot)        { [void]$sb.Append($GL.Lower) }
                else                 { [void]$sb.Append($script:GlyphEmpty) }
            }
            else {
                $h = $heights[$c]; $f = $fracs[$c]
                if ($h -gt $rowBase) {
                    $col = Ramp-Colour $f
                    if ($col -ne $last) { [void]$sb.Append($col); $last = $col }
                    [void]$sb.Append($script:GlyphFull)
                } else {
                    if ($last -ne $CFaint) { [void]$sb.Append($CFaint); $last = $CFaint }
                    [void]$sb.Append($script:GlyphEmpty)
                }
            }
        }
        [void]$sb.Append($RS)
        $lines += $sb.ToString()
    }
    return $lines
}

# Pads plain text to a width. Used instead of calling .PadLeft/.PadRight on a
# string literal inside a concatenation: if the width argument is ever not an
# integer, the failure is a clean one here rather than a parameter-binding
# exception that kills the render loop.
function Pad-Col {
    param([string]$Text, [int]$Width, [string]$Align = 'left')
    if ($null -eq $Text) { $Text = '' }
    if ($Width -le 0) { return '' }
    if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, $Width) }
    if ($Align -eq 'right') { return $Text.PadLeft($Width) }
    return $Text.PadRight($Width)
}

# Bytes, 1024-based, labelled KB/MB/GB as Windows itself does. The unit used to
# be a bare K/M/G, which said nothing about bytes versus bits - the distinction
# that actually matters on the network panel.
function Fmt-Bytes {
    param([double]$B, [int]$Dec = 1)
    $u = @('B','KB','MB','GB','TB','PB')
    $i = 0
    while ($B -ge 1024 -and $i -lt 5) { $B /= 1024; $i++ }
    if ($i -eq 0) { return ('{0:0} {1}' -f $B, $u[$i]) }
    $fmt = '{0:0.' + ('0' * $Dec) + '} {1}'
    return ($fmt -f $B, $u[$i])
}

# Bits per second, 1000-based, which is how link speeds are quoted. 1 MB/s of
# traffic is 8 Mbps, so this is the number to compare against "100 Mbps".
function Fmt-Bits {
    param([double]$BytesPerSec)
    $bits = $BytesPerSec * 8
    $u = @('bps','Kbps','Mbps','Gbps','Tbps')
    $i = 0
    while ($bits -ge 1000 -and $i -lt 4) { $bits /= 1000; $i++ }
    if ($i -eq 0) { return ('{0:0} {1}' -f $bits, $u[$i]) }
    return ('{0:0.0} {1}' -f $bits, $u[$i])
}

function Fmt-Rate { param([double]$Bps) return ((Fmt-Bytes $Bps) + '/s') }

function Fmt-Age {
    param([long]$Ticks)
    try {
        $dt = [DateTime]::FromFileTime($Ticks)
        $span = (Get-Date) - $dt
        if ($span.TotalDays -ge 1) { return ('{0}d{1:00}h' -f [int]$span.TotalDays, $span.Hours) }
        return ('{0:00}:{1:00}:{2:00}' -f [int]$span.TotalHours, $span.Minutes, $span.Seconds)
    } catch { return '' }
}

# ---------------------------------------------------------------------------
# Frame buffer with per-line diffing
# ---------------------------------------------------------------------------

$script:Frame = @()
$script:PrevFrame = @()

function Frame-Reset {
    param([int]$H)
    $script:Frame = New-Object string[] $H
    for ($i = 0; $i -lt $H; $i++) { $script:Frame[$i] = '' }
}

function Frame-Set {
    param([int]$Row, [string]$Text)
    if ($Row -ge 0 -and $Row -lt $script:Frame.Length) { $script:Frame[$Row] = $Text }
}

function Frame-Flush {
    $sb = New-Object System.Text.StringBuilder
    $n = $script:Frame.Length
    $same = ($script:PrevFrame.Length -eq $n)
    for ($i = 0; $i -lt $n; $i++) {
        $line = $script:Frame[$i]
        if ($same -and $script:PrevFrame[$i] -eq $line) { continue }
        [void]$sb.Append("${ESC}[$($i + 1);1H")
        [void]$sb.Append($line)
        [void]$sb.Append("${ESC}[K")
    }
    if ($sb.Length -gt 0) { [Console]::Write($sb.ToString()) }
    $script:PrevFrame = $script:Frame.Clone()
}

function Frame-Invalidate { $script:PrevFrame = @() }

# ---------------------------------------------------------------------------
# Boxes
# ---------------------------------------------------------------------------

function Box-Top {
    param([string]$Title, [int]$W, [string]$Right = '', [string]$Num = '')
    # btop puts the toggle key in the title, highlighted, so it reads as a hint
    $t = $CFrame + $GL.TL + $GL.H + $RS
    $used = 2
    if ($Num) {
        $t += $CAcc2 + $Num + $RS
        $used += $Num.Length
    }
    $t += $BOLD + $CTitle + ' ' + $Title + ' ' + $RS
    $used += $Title.Length + 2
    $r = ''
    if ($Right) {
        $r = $CFaint + ' ' + $Right + ' ' + $RS
        $used += $Right.Length + 2
    }
    $fill = $W - $used - 1
    if ($fill -lt 0) { $fill = 0 }
    return $t + $CFrame + ([string]$GL.H * $fill) + $r + $CFrame + $GL.TR + $RS
}

function Box-Bottom {
    param([int]$W, [string]$Hint = '')
    if ($Hint) {
        $used = 1 + $Hint.Length + 2
        $fill = $W - $used - 1
        if ($fill -lt 0) { $fill = 0 }
        return $CFrame + $GL.BL + ([string]$GL.H * $fill) + ' ' + $CFaint + $Hint + ' ' + $CFrame + $GL.BR + $RS
    }
    return $CFrame + $GL.BL + ([string]$GL.H * ($W - 2)) + $GL.BR + $RS
}

function Box-Row {
    param([string]$Content, [int]$W)
    $inner = $W - 4
    return $CFrame + $GL.V + $RS + ' ' + (Fit-Vis $Content $inner) + ' ' + $CFrame + $GL.V + $RS
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

$IDX = @{ Pid=0; Ppid=1; Name=2; Threads=3; Handles=4; WS=5; Priv=6; Cpu=7; Io=8; Created=9; Session=10; IoTotal=11 }

$state = @{
    SortKey    = [string]$cfg.SortKey
    SortDesc   = [bool]$cfg.SortDesc
    Tree       = [bool]$cfg.Tree
    Alerts     = [bool]$cfg.Alerts
    Filter     = ''
    FilterMode = $false
    Sel        = 0
    SelPid     = 0        # the selection follows this process, not a row number
    SelMoved   = $false   # set by the navigation keys, cleared once honoured
    Scroll     = 0
    Lazy       = [bool]$cfg.LazySort
    Combine    = [bool]$cfg.CombineMemDisk
    Interval   = [int]$cfg.Interval
    ShowCpu    = [bool]$cfg.Panels.Cpu
    ShowMem    = [bool]$cfg.Panels.Mem
    ShowDisk   = [bool]$cfg.Panels.Disk
    ShowNet    = [bool]$cfg.Panels.Net
    ShowGpu    = [bool]$cfg.Panels.Gpu
    ShowConn   = [bool]$cfg.Panels.Conn
    ShowKernel = [bool]$cfg.Panels.Kernel
    ShowProc   = [bool]$cfg.Panels.Proc
    Help       = $false
    Detail     = $false
    Message    = ''
    MsgUntil   = [DateTime]::MinValue
    Paused     = $false
    ProcRect   = @{ Top = 0; Left = 0; Rows = 0 }
}

# Presets are just panel combinations, applied on top of whatever is configured.
$Presets = @{
    full    = @{ Cpu=$true;  Mem=$true;  Disk=$true;  Net=$true;  Gpu=$true;  Conn=$false; Kernel=$false; Proc=$true }
    minimal = @{ Cpu=$true;  Mem=$true;  Disk=$false; Net=$false; Gpu=$false; Conn=$false; Kernel=$false; Proc=$true }
    network = @{ Cpu=$true;  Mem=$false; Disk=$false; Net=$true;  Gpu=$false; Conn=$true;  Kernel=$false; Proc=$true }
    storage = @{ Cpu=$true;  Mem=$true;  Disk=$true;  Net=$false; Gpu=$false; Conn=$false; Kernel=$true;  Proc=$true }
    compute = @{ Cpu=$true;  Mem=$true;  Disk=$false; Net=$false; Gpu=$true;  Conn=$false; Kernel=$true;  Proc=$true }
}
$PresetOrder = @('full','minimal','network','storage','compute')
$script:PresetIdx = 0

function Apply-Preset {
    param([string]$Name)
    if (-not $Presets.ContainsKey($Name)) { return }
    $p = $Presets[$Name]
    $state.ShowCpu = $p.Cpu; $state.ShowMem = $p.Mem; $state.ShowDisk = $p.Disk
    $state.ShowNet = $p.Net; $state.ShowGpu = $p.Gpu; $state.ShowConn = $p.Conn
    $state.ShowKernel = $p.Kernel; $state.ShowProc = $p.Proc
    Frame-Invalidate
}
if ($Preset) { Apply-Preset $Preset; $script:PresetIdx = [array]::IndexOf($PresetOrder, $Preset) }

$hist = @{
    Cpu   = New-Object System.Collections.Generic.List[double]
    Mem   = New-Object System.Collections.Generic.List[double]
    NetR  = New-Object System.Collections.Generic.List[double]
    NetS  = New-Object System.Collections.Generic.List[double]
    DiskR = New-Object System.Collections.Generic.List[double]
    DiskW = New-Object System.Collections.Generic.List[double]
    Gpu   = New-Object System.Collections.Generic.List[double]
    GpuMem= New-Object System.Collections.Generic.List[double]
    Handles = New-Object System.Collections.Generic.List[double]
    # Load averages need real timestamps, not a sample count: the refresh rate is
    # adjustable at runtime, so "the last 60 samples" is not "the last minute".
    LoadT = New-Object System.Collections.Generic.List[datetime]
    LoadV = New-Object System.Collections.Generic.List[double]
}

function Push-Load {
    param([double]$V)
    $now = Get-Date
    $hist.LoadT.Add($now)
    $hist.LoadV.Add($V)
    $cut = $now.AddMinutes(-16)
    while ($hist.LoadT.Count -gt 0 -and $hist.LoadT[0] -lt $cut) {
        $hist.LoadT.RemoveAt(0); $hist.LoadV.RemoveAt(0)
    }
    while ($hist.LoadT.Count -gt 6000) {
        $hist.LoadT.RemoveAt(0); $hist.LoadV.RemoveAt(0)
    }
}

function Get-LoadAvg {
    param([int]$Minutes)
    if ($hist.LoadT.Count -eq 0) { return 0.0 }
    $cut = (Get-Date).AddMinutes(-$Minutes)
    $sum = 0.0; $n = 0
    for ($i = $hist.LoadT.Count - 1; $i -ge 0; $i--) {
        if ($hist.LoadT[$i] -lt $cut) { break }
        $sum += $hist.LoadV[$i]; $n++
    }
    if ($n -eq 0) { return 0.0 }
    return ($sum / $n)
}

function Push-Hist {
    param($List, [double]$V, [int]$Max = 400)
    $List.Add($V)
    while ($List.Count -gt $Max) { $List.RemoveAt(0) }
}

function Say {
    param([string]$Text, [int]$Seconds = 3)
    $state.Message = $Text
    $state.MsgUntil = (Get-Date).AddSeconds($Seconds)
}

function Diag {
    param([string]$Phase)
    if (-not $Diag) { return }
    ('{0:HH:mm:ss.fff} tick={1} {2}' -f (Get-Date), $script:Tick, $Phase) | Add-Content $DiagFile
}

# ---------------------------------------------------------------------------
# Alerts
# ---------------------------------------------------------------------------

$script:AlertState = @{}

function Check-Alert {
    param([string]$Key, [bool]$Bad, [string]$Text)
    if (-not $state.Alerts) { return }
    $was = $false
    if ($script:AlertState.ContainsKey($Key)) { $was = $script:AlertState[$Key] }
    if ($Bad -and -not $was) {
        ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) | Add-Content $AlertLog
        Say $Text 6
    }
    $script:AlertState[$Key] = $Bad
}

# ---------------------------------------------------------------------------
# Sampling
# ---------------------------------------------------------------------------

$netPrev = @{}
$netStamp = $null

function Sample-Net {
    $now = Get-Date
    $out = @()
    $elapsed = 0
    if ($netStamp) { $elapsed = ($now - $netStamp).TotalSeconds }

    try { $nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() }
    catch { return @() }

    foreach ($n in $nics) {
        if ($n.OperationalStatus -ne 'Up') { continue }
        if ($n.NetworkInterfaceType -eq 'Loopback') { continue }
        $st = $null
        try { $st = $n.GetIPv4Statistics() } catch { continue }
        $id = $n.Id
        $r = 0.0; $s = 0.0
        if ($elapsed -gt 0 -and $netPrev.ContainsKey($id)) {
            $r = ($st.BytesReceived - $netPrev[$id][0]) / $elapsed
            $s = ($st.BytesSent     - $netPrev[$id][1]) / $elapsed
            if ($r -lt 0) { $r = 0 }
            if ($s -lt 0) { $s = 0 }
        }
        $netPrev[$id] = @($st.BytesReceived, $st.BytesSent)
        $out += [pscustomobject]@{
            Name = $n.Name; Desc = $n.Description
            Recv = $r; Sent = $s
            TotalRecv = $st.BytesReceived; TotalSent = $st.BytesSent
            Speed = $n.Speed
        }
    }
    $script:netStamp = $now
    return $out
}

function Sample-Volumes {
    $vols = @()
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            if (-not $d.IsReady) { continue }
            if ($d.DriveType -eq 'CDRom') { continue }
            $vols += [pscustomobject]@{
                Letter = $d.Name.Substring(0,1)
                Label  = $d.VolumeLabel
                Type   = [string]$d.DriveType
                Total  = $d.TotalSize
                Free   = $d.TotalFreeSpace
                Used   = $d.TotalSize - $d.TotalFreeSpace
            }
        }
    } catch { }
    return $vols
}

# ---------------------------------------------------------------------------
# Process list shaping
# ---------------------------------------------------------------------------

# Exponential moving average of each process's CPU, used only for ordering.
# Sorting on the instantaneous value makes the top of the list reshuffle every
# tick, which is unreadable and moves rows out from under the cursor. The
# displayed percentages remain the live ones.
$script:CpuEma = @{}
$script:EmaAlpha = 0.35

function Update-CpuEma {
    param($Rows)
    $seen = @{}
    foreach ($r in $Rows) {
        $rowPid = [int]$r[$IDX.Pid]
        $seen[$rowPid] = $true
        $cur = [double]$r[$IDX.Cpu]
        if ($script:CpuEma.ContainsKey($rowPid)) {
            $script:CpuEma[$rowPid] = ($script:CpuEma[$rowPid] * (1 - $script:EmaAlpha)) + ($cur * $script:EmaAlpha)
        } else {
            $script:CpuEma[$rowPid] = $cur
        }
    }
    # drop processes that have exited, or the table grows without bound
    if ($script:CpuEma.Count -gt ($Rows.Count * 2 + 64)) {
        foreach ($k in @($script:CpuEma.Keys)) {
            if (-not $seen.ContainsKey($k)) { $script:CpuEma.Remove($k) }
        }
    }
}

function Sort-Rows {
    param($Rows, [string]$Key, [bool]$Desc, [bool]$Lazy = $false)
    $col = switch ($Key) {
        'cpu'     { $IDX.Cpu }
        'mem'     { $IDX.WS }
        'pid'     { $IDX.Pid }
        'name'    { $IDX.Name }
        'io'      { $IDX.Io }
        'handles' { $IDX.Handles }
        default   { $IDX.Cpu }
    }
    if ($Key -eq 'name') {
        $expr = { [string]$_[$col] }
    } elseif ($Key -eq 'cpu' -and $Lazy) {
        # note: $rowPid, not $pid - $PID is an automatic variable
        $expr = {
            $rowPid = [int]$_[0]
            if ($script:CpuEma.ContainsKey($rowPid)) { $script:CpuEma[$rowPid] } else { [double]$_[7] }
        }
    } else {
        $expr = { $_[$col] }
    }
    if ($Desc) { return @($Rows | Sort-Object -Property @{Expression = $expr} -Descending) }
    return @($Rows | Sort-Object -Property @{Expression = $expr})
}

function Build-Tree {
    param($Rows)
    $byParent = @{}
    $known = @{}
    foreach ($r in $Rows) { $known[[int]$r[$IDX.Pid]] = $true }
    foreach ($r in $Rows) {
        $pp = [int]$r[$IDX.Ppid]
        if (-not $known.ContainsKey($pp)) { $pp = -1 }
        if (-not $byParent.ContainsKey($pp)) { $byParent[$pp] = New-Object System.Collections.Generic.List[object] }
        $byParent[$pp].Add($r)
    }

    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    function Walk {
        param($Parent, [int]$Depth)
        if (-not $byParent.ContainsKey($Parent)) { return }
        $kids = $byParent[$Parent]
        for ($i = 0; $i -lt $kids.Count; $i++) {
            $k = $kids[$i]
            $kpid = [int]$k[$IDX.Pid]
            if ($seen.ContainsKey($kpid)) { continue }
            $seen[$kpid] = $true
            $last = ($i -eq $kids.Count - 1)
            $out.Add(@($k, $Depth, $last))
            if ($Depth -lt 12) { Walk $kpid ($Depth + 1) }
        }
    }

    Walk (-1) 0
    foreach ($r in $Rows) {
        if (-not $seen.ContainsKey([int]$r[$IDX.Pid])) { $out.Add(@($r, 0, $true)) }
    }
    return $out
}

# ---------------------------------------------------------------------------
# Panels - laid out after btop4win: a wide graph beside a per-core sub-box,
# disks nested inside the memory box, download/upload nested inside net, and a
# process table with Command, User and a per-row load bar.
# ---------------------------------------------------------------------------

# Sub-box helpers. A sub-box is a framed region drawn inside a panel, composed
# per row so it can sit beside other content on the same line.
function SB-Top {
    param([string]$Title, [int]$W, [string]$Right = '')
    $s = $CFrame + $GL.TL + $RS
    $u = 1
    if ($Title) { $s += $CTitle + $Title + $RS; $u += $Title.Length }
    $tail = ''
    if ($Right) {
        $tail = $CText + $Right + $RS + $CFrame + $GL.H + $RS
        $u += $Right.Length + 1
    }
    $fill = $W - $u - 1
    if ($fill -lt 0) { $fill = 0 }
    return $s + $CFrame + ([string]$GL.H * $fill) + $RS + $tail + $CFrame + $GL.TR + $RS
}

function SB-Row {
    param([string]$C, [int]$W)
    return $CFrame + $GL.V + $RS + (Fit-Vis $C ($W - 2)) + $CFrame + $GL.V + $RS
}

function SB-Bot {
    param([int]$W, [string]$Left = '', [string]$Right = '')
    $s = $CFrame + $GL.BL + $RS
    $u = 1
    if ($Left) { $s += $CTitle + $Left + $RS; $u += $Left.Length }
    $tail = ''
    if ($Right) {
        $tail = $CText + $Right + $RS + $CFrame + $GL.H + $RS
        $u += $Right.Length + 1
    }
    $fill = $W - $u - 1
    if ($fill -lt 0) { $fill = 0 }
    return $s + $CFrame + ([string]$GL.H * $fill) + $RS + $tail + $CFrame + $GL.BR + $RS
}

# Panel bottom border with a label at each end, like btop's "up 04:41:35"
function Box-BottomLR {
    param([int]$W, [string]$Left = '', [string]$Right = '')
    $s = $CFrame + $GL.BL + $GL.H + $RS
    $u = 2
    if ($Left) { $s += $CFaint + ' ' + $Left + ' ' + $RS; $u += $Left.Length + 2 }
    $tail = ''
    if ($Right) { $tail = $CFaint + ' ' + $Right + ' ' + $RS; $u += $Right.Length + 2 }
    $fill = $W - $u - 1
    if ($fill -lt 0) { $fill = 0 }
    return $s + $CFrame + ([string]$GL.H * $fill) + $RS + $tail + $CFrame + $GL.BR + $RS
}

# Rolling history for the small per-core and per-disk graphs
$script:CoreHist = @{}
$script:DiskHist = @{}
$script:CpuModel = $null

function Get-CpuModel {
    if ($null -ne $script:CpuModel) { return $script:CpuModel }
    $script:CpuModel = 'CPU'
    try {
        $k = 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0'
        $n = (Get-ItemProperty -Path $k -Name ProcessorNameString -ErrorAction Stop).ProcessorNameString
        if ($n) { $script:CpuModel = ($n -replace '\(R\)|\(TM\)|CPU|Processor', '' -replace '\s+', ' ').Trim() }
    } catch { }
    return $script:CpuModel
}

function Push-Small {
    param($Table, [string]$Key, [double]$V, [int]$Max = 60)
    if (-not $Table.ContainsKey($Key)) { $Table[$Key] = New-Object System.Collections.Generic.List[double] }
    $Table[$Key].Add($V)
    while ($Table[$Key].Count -gt $Max) { $Table[$Key].RemoveAt(0) }
}

# A one-row graph, used for the per-core and per-disk strips
function Mini-Graph {
    param($Values, [int]$W)
    $g = Graph-Rows $Values $W 1
    if ($g.Count -gt 0) { return $g[0] }
    return (' ' * $W)
}

# ---------------------------------------------------------------------------

function Draw-Cpu {
    param([int]$Row, [int]$W, [int]$H, $Cores, [double]$Total, $MemRow, $Freq, $TopProc)

    $inner = $W - 2
    $limit = $Row + $H - 1

    # --- title bar: name and menu items left, clock centred, interval right
    $left = $CFrame + $GL.TL + $GL.H + $RS +
            $CAcc2 + [char]0x00B9 + $RS + $BOLD + $CTitle + 'cpu' + $RS +
            $CFrame + $GL.H + $RS + $CFaint + 'pstop ' + $AppVersion + $RS +
            $CFrame + $GL.H + $RS + $CText + $env:COMPUTERNAME + $RS + $CFrame + $GL.H + $RS
    $clock = $CText + (Get-Date -Format 'HH:mm:ss') + $RS
    $right = $CFaint + '- ' + $RS + $CText + ("{0}ms" -f $state.Interval) + $RS + $CFaint + ' +' + $RS +
             $CFrame + $GL.H + $GL.TR + $RS

    $lL = Get-VisLen $left; $lC = Get-VisLen $clock; $lR = Get-VisLen $right
    $padA = [int](($W - $lL - $lC - $lR) / 2)
    if ($padA -lt 1) { $padA = 1 }
    $padB = $W - $lL - $lC - $lR - $padA
    if ($padB -lt 1) { $padB = 1 }
    Frame-Set $Row ($left + $CFrame + ([string]$GL.H * $padA) + $RS + $clock +
                    $CFrame + ([string]$GL.H * $padB) + $RS + $right)

    # --- geometry: graph on the left, per-core sub-box on the right
    $bodyH = $H - 2
    # Prefer 2 columns, as btop does. If the box is too short for that many
    # rows, pack into more columns instead of letting rows fall off the end.
    $coreCols = 2
    $coreRows = [int][math]::Ceiling($Cores.Count / [double]$coreCols)
    while ((($coreRows + 5) -gt $bodyH) -and ($coreCols -lt 6)) {
        $coreCols += 2
        $coreRows = [int][math]::Ceiling($Cores.Count / [double]$coreCols)
    }
    # Last resort on a very short window with a lot of cores: show fewer core
    # rows. Load AVG and the GPU row are what people actually read, so the core
    # grid gives way rather than pushing them off the bottom.
    $maxCoreRows = $bodyH - 5
    if ($maxCoreRows -lt 1) { $maxCoreRows = 1 }
    if ($coreRows -gt $maxCoreRows) { $coreRows = $maxCoreRows }
    $sbNeed = $coreRows + 5          # top, CPU row, cores, load avg, gpu, bottom
    $sbW = [int]($inner * 0.45)
    if ($sbW -lt 44) { $sbW = 44 }
    $sbMax = 62
    if ($coreCols -gt 2) { $sbMax = 30 * $coreCols }
    if ($sbW -gt $sbMax) { $sbW = $sbMax }
    if ($sbW -gt $inner - 20) { $sbW = $inner - 20 }
    $gW = $inner - $sbW - 1
    if ($gW -lt 10) { $gW = 10 }

    foreach ($i in 0..($Cores.Count - 1)) { Push-Small $script:CoreHist ([string]$i) ([double]$Cores[$i]) }

    # --- left: cpu history, and gpu history underneath when a GPU is present
    $haveGpu = ($gpus -and $gpus.Count -gt 0)
    $gLines = @()
    if ($haveGpu -and $bodyH -ge 7) {
        $topH = [int](($bodyH - 1) / 2)
        $botH = $bodyH - 1 - $topH
        $gLines += Graph-Rows $hist.Cpu $gW $topH 100
        $mid = 'cpu ' + [char]0x25B2 + [char]0x25BC + ' gpu'
        $pad = [int](($gW - $mid.Length) / 2)
        if ($pad -lt 0) { $pad = 0 }
        $gLines += ($CFrame + ([string]$GL.H * $pad) + $RS + $CFaint + $mid + $RS +
                    $CFrame + ([string]$GL.H * [math]::Max(0, $gW - $pad - $mid.Length)) + $RS)
        $gLines += Graph-Rows $hist.Gpu $gW $botH 100
    } else {
        $gLines += Graph-Rows $hist.Cpu $gW $bodyH 100
    }

    # --- right: per-core sub-box
    $sb = @()
    $freqRight = ''
    if ($Freq -and $Freq[1] -and $Freq[1].Count -gt 0) {
        $freqRight = '{0:N2} GHz' -f ($Freq[1][0] / 1000.0)
    }
    $sb += SB-Top (Get-CpuModel) $sbW $freqRight

    $sbInner = $sbW - 2
    # "CPU " is 4 and "{0,5:N0}%" renders 6 characters, not 5
    $cpuBarW = $sbInner - 10
    if ($cpuBarW -lt 6) { $cpuBarW = 6 }
    $sb += SB-Row ($CText + 'CPU ' + $RS + (Bar ($Total / 100) $cpuBarW) +
                   (Ramp-Colour ($Total / 100)) + ('{0,5:N0}%' -f $Total) + $RS) $sbW

    # two columns of cores: label, bar, percent, frequency
    $cellW = [int](($sbInner - ($coreCols - 1)) / $coreCols)
    $cLabelW = 3 + ([string]([math]::Max(1, $Cores.Count - 1))).Length
    $cGraphW = $cellW - $cLabelW - 11    # 5 for the percent, 6 for the MHz
    if ($cGraphW -lt 4) { $cGraphW = 4 }

    # A progress bar per core, not a one-row graph. A single-row graph quantises
    # to whole cells, so every core under 25% rendered as an empty strip - which
    # is exactly what it looked like.
    # Every cell is padded to exactly $cellW. Relying on each field being its
    # nominal width silently broke the moment one was short - a core reporting
    # no frequency, or a 3-character label - and shifted the second column.
    for ($i = 0; $i -lt $coreRows; $i++) {
        $parts = @()
        for ($c = 0; $c -lt $coreCols; $c++) {
            $idx = $i + ($c * $coreRows)
            if ($idx -ge $Cores.Count) { $parts += (' ' * $cellW); continue }
            $v = [double]$Cores[$idx]
            $mhz = '     -'
            if ($Freq -and $Freq[0] -and $idx -lt $Freq[0].Count -and $Freq[0][$idx] -gt 0) {
                $mhz = '{0,6:N0}' -f $Freq[0][$idx]
            }
            $cell = $CFaint + ('C' + $idx).PadRight($cLabelW) + $RS +
                    (Bar ($v / 100) $cGraphW) +
                    (Ramp-Colour ($v / 100)) + ('{0,4:N0}%' -f $v) + $RS +
                    $CAcc2 + $mhz + $RS
            $parts += (Fit-Vis $cell $cellW)
        }
        $sb += SB-Row ($parts -join ' ') $sbW
    }

    $sb += SB-Row ($CFaint + 'Load AVG:' + $RS +
                   $CText + ('{0,8:N2}' -f ((Get-LoadAvg 1) / 100)) +
                   ('{0,8:N2}' -f ((Get-LoadAvg 5) / 100)) +
                   ('{0,8:N2}' -f ((Get-LoadAvg 15) / 100)) + $RS) $sbW

    if ($haveGpu) {
        $gu = [double]$gpus[0][1]
        $gt = [int]$gpus[0][5]
        # "GPU " 4 + bar + percent 6 + temperature 5
        $gpuBarW = $sbInner - 15
        if ($gpuBarW -lt 6) { $gpuBarW = 6 }
        $sb += SB-Row ($CText + 'GPU ' + $RS + (Bar ($gu / 100) $gpuBarW) +
                       (Ramp-Colour ($gu / 100)) + ('{0,5:N0}%' -f $gu) + $RS +
                       $CAcc2 + ('{0,4:N0}C' -f $gt) + $RS) $sbW
        $sb += SB-Bot $sbW (Trunc-Vis ([string]$gpus[0][0]) ($sbW - 14)) (('{0} Mhz' -f $gpus[0][7]))
    } else {
        $sb += SB-Row ($CFaint + 'GPU  no NVML data' + $RS) $sbW
        $sb += SB-Bot $sbW '' ''
    }

    # --- compose
    for ($i = 0; $i -lt $bodyH; $i++) {
        $r = $Row + 1 + $i
        if ($r -ge $limit) { break }
        $l = ''
        if ($i -lt $gLines.Count) { $l = $gLines[$i] }
        $s = ''
        if ($i -lt $sb.Count) { $s = $sb[$i] }
        Frame-Set $r ($CFrame + $GL.V + $RS + (Fit-Vis $l $gW) + ' ' + (Fit-Vis $s $sbW) +
                      $CFrame + $GL.V + $RS)
    }

    $upStr = ''
    if ($script:BootTime) {
        $up = (Get-Date) - $script:BootTime
        $upStr = 'up {0}d {1:00}:{2:00}:{3:00}' -f $up.Days, $up.Hours, $up.Minutes, $up.Seconds
    }
    $busiest = ''
    if ($TopProc) { $busiest = 'busiest {0} {1:N1}%' -f $TopProc[0], [double]$TopProc[1] }
    Frame-Set $limit (Box-BottomLR $W $upStr $busiest)
}

# ---------------------------------------------------------------------------

function Draw-MemDisk {
    param([int]$Row, [int]$W, [int]$H, $M, $Vols, $Io)

    $inner = $W - 2
    $limit = $Row + $H - 1
    Frame-Set $Row (Box-Top 'mem' $W ((Fmt-Bytes ([double]$M[0])) + ' total') ([string][char]0x00B2))

    $total = [double]$M[0]; $avail = [double]$M[1]; $cache = [double]$M[2]
    $commit = [double]$M[3]; $climit = [double]$M[4]
    $used = $total - $avail

    $dW = 0
    # Only carve out the disks half when there are volumes to put in it. Draw-Mem
    # reuses this function with an empty list for the standalone memory box, and
    # without this check a wide panel drew an empty box captioned "disks  io".
    if ($inner -ge 76 -and $Vols -and @($Vols).Count -gt 0) {
        $dW = [int]($inner * 0.5)
        if ($dW -lt 30) { $dW = 30 }
        if ($dW -gt 44) { $dW = 44 }
    }
    $lW = $inner - $dW
    if ($dW -gt 0) { $lW = $inner - $dW - 1 }

    # --- left: one row per metric. Two rows each (value, then bar) meant only
    # Total and Used survived once the box was sharing height with net and gpu.
    $lines = @()
    $labW = 10
    $valW = 9
    $pctW = 5
    $bw = $lW - $labW - $valW - $pctW - 2
    if ($bw -lt 6) { $bw = 6 }

    $lines += ($CText + 'Total:'.PadRight($labW) + $RS +
               (Pad-Vis '' $bw) + ' ' + $CText + (Fmt-Bytes $total).PadLeft($valW) + $RS)
    foreach ($x in @(@('Used', $used, $total), @('Available', $avail, $total),
                     @('Cached', $cache, $total), @('Commit', $commit, $climit))) {
        $frac = 0.0
        if ($x[2] -gt 0) { $frac = $x[1] / $x[2] }
        $lines += ($CText + ([string]$x[0] + ':').PadRight($labW) + $RS +
                   (Bar $frac $bw) + ' ' +
                   $CText + (Fmt-Bytes $x[1]).PadLeft($valW) + $RS +
                   (Ramp-Colour $frac) + ('{0,5:P0}' -f $frac) + $RS)
    }
    $lines += ($CFaint + 'kernel'.PadRight($labW) + 'paged ' + $RS + (Fmt-Bytes ([double]$M[5])) +
               $CFaint + '  nonpaged ' + $RS + (Fmt-Bytes ([double]$M[6])))

    # --- right: disks sub-box
    $dlines = @()
    if ($dW -gt 0) {
        $dlines += SB-Top 'disks' $dW 'io'
        $di = $dW - 2
        foreach ($v in $Vols) {
            $frac = 0.0
            if ($v.Total -gt 0) { $frac = $v.Used / [double]$v.Total }
            $rd = 0.0; $wr = 0.0; $busy = 0.0
            if ($Io -and $Io.ContainsKey($v.Letter)) { $rd = $Io[$v.Letter][0]; $wr = $Io[$v.Letter][1]; $busy = $Io[$v.Letter][2] }
            Push-Small $script:DiskHist $v.Letter $busy

            $label = $v.Letter + ': ' + $(if ($v.Label) { $v.Label } else { $v.Type })
            $act = ''
            if ($rd -gt $wr) { $act = [string][char]0x25BC + (Fmt-Bytes $rd) }
            elseif ($wr -gt 0) { $act = [string][char]0x25B2 + (Fmt-Bytes $wr) }
            $dlines += SB-Row ($CTitle + (Trunc-Vis $label ($di - 20)) + $RS + ' ' +
                               $CAcc2 + $act + $RS +
                               $CFaint + (Fmt-Bytes $v.Total).PadLeft([math]::Max(1, $di - (Get-VisLen ($label + $act)) - 2)) + $RS) $dW
            $gw2 = $di - 12
            if ($gw2 -lt 4) { $gw2 = 4 }
            $dlines += SB-Row ($CFaint + 'IO%' + $RS + ' ' + (Mini-Graph $script:DiskHist[$v.Letter] $gw2) +
                               (Ramp-Colour ($busy / 100)) + ('{0,4:N0}%' -f $busy) + $RS) $dW
            $fb = $di - 22
            if ($fb -lt 4) { $fb = 4 }
            $dlines += SB-Row ($CText + 'Free: ' + $RS + (Ramp-Colour (1 - $frac)) + ('{0,3:N0}%' -f ((1 - $frac) * 100)) + $RS + ' ' +
                               (Bar $frac $fb) + ' ' + $CFaint + (Fmt-Bytes $v.Free).PadLeft(8) + $RS) $dW
        }
        while ($dlines.Count -lt ($H - 3)) { $dlines += SB-Row '' $dW }
        $dlines += SB-Bot $dW '' ''
    }

    $n = [math]::Max($lines.Count, $dlines.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $r = $Row + 1 + $i
        if ($r -ge $limit) { break }
        $l = ''
        if ($i -lt $lines.Count) { $l = $lines[$i] }
        $d = ''
        if ($i -lt $dlines.Count) { $d = $dlines[$i] }
        if ($dW -gt 0) {
            Frame-Set $r ($CFrame + $GL.V + $RS + (Fit-Vis $l $lW) + ' ' + (Fit-Vis $d $dW) + $CFrame + $GL.V + $RS)
        } else {
            Frame-Set $r ($CFrame + $GL.V + $RS + (Fit-Vis $l $inner) + $CFrame + $GL.V + $RS)
        }
    }
    for ($r = $Row + 1 + $n; $r -lt $limit; $r++) { Frame-Set $r (Box-Row '' $W) }
    Frame-Set $limit (Box-Bottom $W)
}

function Draw-Mem { param([int]$Row, [int]$W, [int]$H, $M) Draw-MemDisk $Row $W $H $M @() $null }

function Draw-Disk {
    # NOTE: PowerShell variable names are case-insensitive, so a local $h here
    # would BE the [int]$H parameter and assigning a string to it throws
    # "Cannot convert value ... to type System.Int32". The header variable is
    # $hdr for that reason. Same applies to $w and $r in any function below.
    param([int]$Row, [int]$W, [int]$H, $Vols, $Io)
    $limit = $Row + $H - 1
    Frame-Set $Row (Box-Top 'disks' $W ('{0} volumes' -f $Vols.Count) ([string][char]0x00B3))
    $r = $Row + 1
    $inner = $W - 4

    # Columns are dropped from the widest first as the panel narrows, but the
    # read/write pair is kept to the last, since that is the column being asked
    # for. Widths: letter 3, percent 5, free/total 19, io 19, busy 7.
    [int]$ioW   = 21
    [int]$ftW   = 21
    [int]$freeW = 10
    [int]$busyW = 7

    $showBusy = ($inner -ge 90)
    $showFT   = ($inner -ge 72)
    $showFree = ((-not $showFT) -and ($inner -ge 48))
    # On a very narrow panel the read/write pair alone needs 21 columns, so the
    # percentage goes rather than the figures that were asked for.
    $showPct  = ($inner -ge 40)

    [int]$used = 3 + 1 + $ioW
    if ($showPct) { $used = $used + 5 + 1 }
    if ($showFT)   { $used = $used + $ftW + 1 }
    if ($showFree) { $used = $used + $freeW + 1 }
    if ($showBusy) { $used = $used + $busyW }
    [int]$bw = $inner - $used
    if ($bw -lt 5) { $bw = 5 }
    [int]$usedHdrW = $bw + 7

    # header. Built through Pad-Col rather than calling .PadRight on a literal
    # inside a concatenation, which is where the Int32 conversion blew up.
    if ($r -lt $limit) {
        $hdr = $CFaint + '   ' + (Pad-Col 'USED' $usedHdrW 'left')
        if (-not $showPct) { $hdr = $CFaint + '   ' + (Pad-Col 'USED' ([int]($bw + 1)) 'left') }
        if ($showFT)   { $hdr += (Pad-Col 'FREE / TOTAL' $ftW 'right') + ' ' }
        if ($showFree) { $hdr += (Pad-Col 'FREE' $freeW 'right') + ' ' }
        $ioHdr = 'READ' + [string][char]0x25BC + '  WRITE' + [string][char]0x25B2
        $hdr += (Pad-Col $ioHdr $ioW 'right')
        if ($showBusy) { $hdr += (Pad-Col 'BUSY' $busyW 'right') }
        $hdr += $RS
        Frame-Set $r (Box-Row $hdr $W)
        $r++
    }

    foreach ($v in $Vols) {
        if ($r -ge $limit) { break }
        $frac = 0.0
        if ($v.Total -gt 0) { $frac = $v.Used / [double]$v.Total }

        $rd = 0.0; $wr = 0.0; $busy = 0.0
        if ($Io -and $Io.ContainsKey($v.Letter)) {
            $rd = $Io[$v.Letter][0]; $wr = $Io[$v.Letter][1]; $busy = $Io[$v.Letter][2]
        }
        Push-Small $script:DiskHist $v.Letter $busy

        $line = $BOLD + $CAccent + $v.Letter + ':' + $RS + ' ' + (Bar $frac $bw) + ' '
        if ($showPct) { $line += (Ramp-Colour $frac) + ('{0,4:P0}' -f $frac) + $RS + ' ' }
        if ($showFT) {
            $line += $CFaint + (Pad-Col ((Fmt-Bytes $v.Free) + ' / ' + (Fmt-Bytes $v.Total)) $ftW 'right') + $RS + ' '
        } elseif ($showFree) {
            $line += $CFaint + (Pad-Col (Fmt-Bytes $v.Free) $freeW 'right') + $RS + ' '
        }

        # the read/write pair, always present
        $rcol = $CFaint
        if ($rd -gt 0) { $rcol = Fg $TH.Good }
        $wcol = $CFaint
        if ($wr -gt 0) { $wcol = Fg $TH.Warn }
        $line += $rcol + ([string][char]0x25BC + (Fmt-Bytes $rd).PadLeft(9)) + $RS +
                 $wcol + (' ' + [string][char]0x25B2 + (Fmt-Bytes $wr).PadLeft(9)) + $RS

        if ($showBusy) {
            $line += (Ramp-Colour ($busy / 100)) + ('{0,6:N0}%' -f $busy) + $RS
        }

        Frame-Set $r (Box-Row $line $W)
        $r++

        Check-Alert ('disk-' + $v.Letter) ($busy -ge $cfg.Thresholds.DiskBusy) ("disk $($v.Letter): busy $([int]$busy)%")
    }

    # totals across all volumes, when there is a spare row
    if ($r -lt $limit -and $Io -and $Io.Count -gt 0) {
        $tr = 0.0; $tw = 0.0
        foreach ($k in $Io.Keys) { $tr += $Io[$k][0]; $tw += $Io[$k][1] }
        $tot = $CFaint + (Pad-Col 'total' ([int]($bw + 11)) 'left') + $RS
        if ($showFT)   { $tot += (Pad-Col '' $ftW 'right') + ' ' }
        if ($showFree) { $tot += (Pad-Col '' $freeW 'right') + ' ' }
        $tot += (Fg $TH.Good) + ([string][char]0x25BC + (Fmt-Bytes $tr).PadLeft(9)) + $RS +
                (Fg $TH.Warn) + (' ' + [string][char]0x25B2 + (Fmt-Bytes $tw).PadLeft(9)) + $RS
        Frame-Set $r (Box-Row $tot $W)
        $r++
    }

    while ($r -lt $limit) { Frame-Set $r (Box-Row '' $W); $r++ }
    Frame-Set $limit (Box-Bottom $W)
}

# ---------------------------------------------------------------------------

function Draw-Net {
    param([int]$Row, [int]$W, [int]$H, $Nics)

    $inner = $W - 2
    $limit = $Row + $H - 1
    $ip = ''
    $name = ''
    if ($Nics.Count -gt 0) {
        $name = $Nics[0].Name
        try {
            foreach ($a in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                if ($a.Name -ne $name) { continue }
                foreach ($u in $a.GetIPProperties().UnicastAddresses) {
                    if ($u.Address.AddressFamily -eq 'InterNetwork') { $ip = $u.Address.ToString(); break }
                }
            }
        } catch { }
    }
    Frame-Set $Row (Box-Top 'net' $W $(if ($ip) { $ip } else { $name }) ([string][char]0x2074))

    $totR = 0.0; $totS = 0.0; $ttR = 0; $ttS = 0
    foreach ($n in $Nics) { $totR += $n.Recv; $totS += $n.Sent; $ttR += $n.TotalRecv; $ttS += $n.TotalSent }
    $peakR = 1.0; $peakS = 1.0
    foreach ($v in $hist.NetR) { if ($v -gt $peakR) { $peakR = $v } }
    foreach ($v in $hist.NetS) { if ($v -gt $peakS) { $peakS = $v } }

    $bodyH = $H - 2
    $gW = $inner

    # ONE layout at every height: a summary line then a graph, for each
    # direction. The panel used to switch to side sub-boxes past ten rows,
    # which meant resizing the window changed what the panel looked like and
    # where the numbers were - or, once the sub-box code was removed, left a
    # blank column and no figures at all.
    $dn = [string][char]0x25BC
    $up = [string][char]0x25B2

    # Rate in bytes/sec with the bits/sec equivalent beside it, as btop does.
    # People compare network throughput against a link speed quoted in Mbps, so
    # showing only MB/s invites a factor-of-eight mistake.
    $downLine = (Fg $TH.Good) + $dn + ' ' + (Fmt-Bits $totR).PadRight(11) + $RS
    $upLine   = (Fg $TH.Warn) + $up + ' ' + (Fmt-Bits $totS).PadRight(11) + $RS
    if ($inner -ge 66) {
        $downLine += $CDim + ('(' + (Fmt-Rate $totR) + ')').PadRight(14) + $RS
        $upLine   += $CDim + ('(' + (Fmt-Rate $totS) + ')').PadRight(14) + $RS
    }
    if ($inner -ge 34) {
        $downLine += $CFaint + 'peak ' + (Fmt-Bits $peakR).PadRight(11) + $RS
        $upLine   += $CFaint + 'peak ' + (Fmt-Bits $peakS).PadRight(11) + $RS
    }
    if ($inner -ge 52) {
        $downLine += $CFaint + 'total ' + (Fmt-Bytes $ttR) + $RS
        $upLine   += $CFaint + 'total ' + (Fmt-Bytes $ttS) + $RS
    }

    $rows = @()
    $gh = $bodyH - 2
    if ($gh -lt 2) {
        $rows += $downLine
        $rows += $upLine
    } else {
        $dh = [int]($gh / 2)
        $uh = $gh - $dh
        if ($dh -lt 1) { $dh = 1 }
        if ($uh -lt 1) { $uh = 1 }
        $rows += $downLine
        $rows += Graph-Rows $hist.NetR $gW $dh $peakR
        $rows += $upLine
        $rows += Graph-Rows $hist.NetS $gW $uh $peakS
    }

    for ($i = 0; $i -lt $bodyH; $i++) {
        $r = $Row + 1 + $i
        if ($r -ge $limit) { break }
        $l = ''
        if ($i -lt $rows.Count) { $l = $rows[$i] }
        Frame-Set $r ($CFrame + $GL.V + $RS + (Fit-Vis $l $inner) + $CFrame + $GL.V + $RS)
    }
    Frame-Set $limit (Box-Bottom $W)
}

# ---------------------------------------------------------------------------

function Draw-Gpu {
    param([int]$Row, [int]$W, [int]$H, $Gpus)
    $limit = $Row + $H - 1
    $right = ''
    if ($Gpus.Count -gt 0) { $right = Trunc-Vis ([string]$Gpus[0][0]) 28 }
    Frame-Set $Row (Box-Top 'gpu' $W $right ([string][char]0x2075))
    $r = $Row + 1
    $inner = $W - 4
    $barW = $inner - 26
    if ($barW -lt 8) { $barW = 8 }

    if ($Gpus.Count -eq 0) {
        $msg = 'No NVIDIA GPU data.'
        if ([PsTop20.Gpu]::LastError) { $msg += '  ' + [PsTop20.Gpu]::LastError }
        Frame-Set $r (Box-Row ($CFaint + $msg + $RS) $W); $r++
    } else {
        foreach ($g in $Gpus) {
            if ($r -ge $limit) { break }
            $util = [double]$g[1]
            $memUsed = [double]$g[3]; $memTotal = [double]$g[4]
            $memFrac = 0.0
            if ($memTotal -gt 0) { $memFrac = $memUsed / $memTotal }
            Frame-Set $r (Box-Row ($CText + 'core '.PadRight(7) + $RS + (Bar ($util/100) $barW) + ' ' +
                          (Ramp-Colour ($util/100)) + ('{0,8:N0}%' -f $util) + $RS) $W); $r++
            if ($r -ge $limit) { break }
            Frame-Set $r (Box-Row ($CText + 'vram '.PadRight(7) + $RS + (Bar $memFrac $barW) + ' ' +
                          (Ramp-Colour $memFrac) + ((Fmt-Bytes $memUsed).PadLeft(9)) + $RS +
                          $CFaint + (' / ' + (Fmt-Bytes $memTotal)) + $RS) $W); $r++
            if ($r -ge $limit) { break }
            Frame-Set $r (Box-Row ($CFaint + 'temp ' + $RS + (Ramp-Colour ([int]$g[5]/100)) + ("$($g[5]) C") + $RS +
                          $CFaint + '   power ' + $RS + ('{0:N0} W' -f [double]$g[6]) +
                          $CFaint + '   clock ' + $RS + ("$($g[7]) MHz") +
                          $CFaint + '   fan ' + $RS + ("$($g[8])%")) $W); $r++
        }
    }
    while ($r -lt $limit) { Frame-Set $r (Box-Row '' $W); $r++ }
    Frame-Set $limit (Box-Bottom $W)
}

function Draw-Kernel {
    param([int]$Row, [int]$W, [int]$H, $M)
    $limit = $Row + $H - 1
    Frame-Set $Row (Box-Top 'kernel' $W 'objects and pool' ([string][char]0x2077))
    $r = $Row + 1
    $inner = $W - 4
    $procs = [int]$M[7]; $thr = [int]$M[8]; $handles = [int]$M[9]

    $gw = $inner - 20
    if ($gw -lt 10) { $gw = 10 }
    $g = Graph-Rows $hist.Handles $gw ([math]::Min(3, [math]::Max(1, $H - 4)))
    for ($i = 0; $i -lt $g.Count; $i++) {
        if ($r -ge $limit) { break }
        $lbl = ''
        if ($i -eq 0) { $lbl = $CText + 'handles ' + $RS + (Ramp-Colour ($handles / [double]$cfg.Thresholds.SysHandles)) + ('{0:N0}' -f $handles) + $RS }
        Frame-Set $r (Box-Row ((Pad-Vis $lbl 19) + ' ' + $g[$i]) $W); $r++
    }
    if ($r -lt $limit) {
        Frame-Set $r (Box-Row ($CFaint + 'processes ' + $RS + ('{0:N0}' -f $procs) +
                      $CFaint + '   threads ' + $RS + ('{0:N0}' -f $thr)) $W); $r++
    }
    if ($r -lt $limit) {
        Frame-Set $r (Box-Row ($CFaint + 'paged pool ' + $RS + (Fmt-Bytes ([double]$M[5])) +
                      $CFaint + '   nonpaged ' + $RS + (Fmt-Bytes ([double]$M[6]))) $W); $r++
    }
    while ($r -lt $limit) { Frame-Set $r (Box-Row '' $W); $r++ }
    Frame-Set $limit (Box-Bottom $W)
    Check-Alert 'handles' ($handles -ge $cfg.Thresholds.SysHandles) ("system handles $('{0:N0}' -f $handles)")
}

function Draw-Conn {
    param([int]$Row, [int]$W, [int]$H, $Conns, $NameByPid)
    $limit = $Row + $H - 1
    Frame-Set $Row (Box-Top 'connections' $W ('{0} sockets' -f $Conns.Count) ([string][char]0x2076))
    $r = $Row + 1
    $inner = $W - 4
    $procW = 18; $stW = 12
    $addrW = [int](($inner - 6 - $procW - $stW - 3) / 2)
    if ($addrW -lt 14) { $addrW = 14 }

    if ($r -lt $limit) {
        Frame-Set $r (Box-Row ($CFaint + 'PRO'.PadRight(5) + 'LOCAL'.PadRight($addrW + 1) +
                      'REMOTE'.PadRight($addrW + 1) + 'STATE'.PadRight($stW) + 'PROCESS' + $RS) $W)
        $r++
    }
    $ordered = @($Conns | Sort-Object -Property @{Expression = {
        if ([string]$_[3] -eq 'ESTABLISHED') { 0 } elseif ([string]$_[3] -eq 'LISTEN') { 1 } else { 2 }
    }}, @{Expression = { [int]$_[4] }})

    foreach ($c in $ordered) {
        if ($r -ge $limit) { break }
        $cpid = [int]$c[4]
        $nm = ''
        if ($NameByPid.ContainsKey($cpid)) { $nm = $NameByPid[$cpid] }
        $st = [string]$c[3]
        $stCol = $CFaint
        if ($st -eq 'ESTABLISHED') { $stCol = Fg $TH.Good }
        elseif ($st -eq 'LISTEN')  { $stCol = Fg $TH.Accent2 }
        elseif ($st -like 'CLOSE*' -or $st -like 'FIN*' -or $st -eq 'TIME_WAIT') { $stCol = Fg $TH.Warn }
        Frame-Set $r (Box-Row ($CFaint + ([string]$c[0]).PadRight(5) + $RS +
                      $CText + (Trunc-Vis ([string]$c[1]) $addrW).PadRight($addrW + 1) + $RS +
                      $CText + (Trunc-Vis ([string]$c[2]) $addrW).PadRight($addrW + 1) + $RS +
                      $stCol + $st.PadRight($stW) + $RS +
                      $CFaint + (Trunc-Vis $nm $procW) + $RS) $W)
        $r++
    }
    while ($r -lt $limit) { Frame-Set $r (Box-Row '' $W); $r++ }
    Frame-Set $limit (Box-Bottom $W)
}

# ---------------------------------------------------------------------------

function Draw-Detail {
    param([int]$Row, [int]$W, [int]$H, $P)
    $limit = $Row + $H - 1
    $inner = $W - 4

    if (-not $P) {
        Frame-Set $Row (Box-Top 'info' $W 'no selection')
        for ($r = $Row + 1; $r -lt $limit; $r++) { Frame-Set $r (Box-Row '' $W) }
        Frame-Set $limit (Box-Bottom $W)
        return
    }

    $dpid = [int]$P[$IDX.Pid]
    Frame-Set $Row (Box-Top ("$dpid " + [string]$P[$IDX.Name]) $W 'd to hide')

    if (-not $script:DetailCache.ContainsKey($dpid)) {
        $path = ''; $owner = ''; $cmd = ''
        try { $path = [PsTop20.ProcInfo]::ImagePath($dpid) } catch { }
        try { $owner = [PsTop20.ProcInfo]::Owner($dpid) } catch { }
        try {
            $w = Get-CimInstance Win32_Process -Filter "ProcessId=$dpid" -ErrorAction SilentlyContinue
            if ($w) { $cmd = [string]$w.CommandLine }
        } catch { }
        $script:DetailCache[$dpid] = @{ Path = $path; Owner = $owner; Cmd = $cmd }
    }
    $d = $script:DetailCache[$dpid]
    $r = $Row + 1

    $memFrac = 0.0
    if ($script:TotalPhys -gt 0) { $memFrac = [double]$P[$IDX.WS] / $script:TotalPhys }

    $rows = @(
        ($CFaint + 'Status: ' + $RS + (Fg $TH.Good) + 'Running' + $RS +
         $CFaint + '   Elapsed: ' + $RS + $CText + (Fmt-Age ([long]$P[$IDX.Created])) + $RS +
         $CFaint + '   Threads: ' + $RS + $CText + [string]$P[$IDX.Threads] + $RS +
         $CFaint + '   Handles: ' + $RS + $CText + ('{0:N0}' -f $P[$IDX.Handles]) + $RS +
         $CFaint + '   Parent: ' + $RS + $CText + [string]$P[$IDX.Ppid] + $RS),
        ($CFaint + 'IO total: ' + $RS + $CText + (Fmt-Bytes $P[$IDX.IoTotal]) + $RS +
         $CFaint + '   IO rate: ' + $RS + $CText + (Fmt-Rate $P[$IDX.Io]) + $RS +
         $CFaint + '   User: ' + $RS + $CText + $(if ($d.Owner) { $d.Owner } else { '-' }) + $RS),
        ($CFaint + 'Memory: ' + $RS + (Ramp-Colour $memFrac) + ('{0:P1}' -f $memFrac) + $RS + ' ' +
         (Bar $memFrac ([math]::Max(6, $inner - 34))) + ' ' + $CText + (Fmt-Bytes $P[$IDX.WS]) + $RS),
        ($CFaint + '"' + $(if ($d.Path) { $d.Path } else { '(path not available)' }) + '"' + $RS)
    )
    if ($d.Cmd) { $rows += ($CFaint + (Trunc-Vis $d.Cmd ($inner - 2)) + $RS) }

    foreach ($l in $rows) {
        if ($r -ge $limit) { break }
        Frame-Set $r (Box-Row $l $W); $r++
    }
    while ($r -lt $limit) { Frame-Set $r (Box-Row '' $W); $r++ }
    Frame-Set $limit (Box-Bottom $W)
}

# ---------------------------------------------------------------------------

function Draw-Proc {
    param([int]$Row, [int]$W, [int]$H, $View, [int]$TotalCount)

    $inner = $W - 4
    $limit = $Row + $H - 1

    # title bar carries the view options, btop style
    $sortLabel = $state.SortKey
    if ($state.SortKey -eq 'cpu' -and $state.Lazy) { $sortLabel = 'cpu lazy' }
    $t = $CFrame + $GL.TL + $GL.H + $RS +
         $CAcc2 + [char]0x2078 + $RS + $BOLD + $CTitle + 'proc' + $RS + $CFrame + $GL.H + $RS +
         $CFaint + 'filter' + $RS + $CFrame + $GL.H + $RS +
         $CFaint + $(if ($state.Tree) { $CTitle + 'tree' + $RS } else { 'tree' }) + $RS + $CFrame + $GL.H + $RS +
         $CFaint + 'detail' + $RS + $CFrame + $GL.H + $RS
    $right = $CFaint + '< ' + $RS + $CText + $sortLabel + $RS +
             $CFaint + $(if ($state.SortDesc) { ' desc' } else { ' asc' }) + ' >' + $RS +
             $CFrame + $GL.H + $GL.TR + $RS
    $fill = $W - (Get-VisLen $t) - (Get-VisLen $right)
    if ($fill -lt 0) { $fill = 0 }
    Frame-Set $Row ($t + $CFrame + ([string]$GL.H * $fill) + $RS + $right)

    $r = $Row + 1

    # columns: Pid, Program, Command, Threads, User, MemB, Cpu%
    $pidW = 7; $thrW = 8; $memW = 9; $cpuW = 7; $graphW = 7
    $userW = 0
    if ($inner -ge 86) { $userW = 10 }
    $cmdW = 0
    $progW = 16
    $fixed = $pidW + $progW + $thrW + $userW + $memW + $cpuW + $graphW + 2
    if ($inner -ge 100) {
        $cmdW = $inner - $fixed
        if ($cmdW -lt 12) { $cmdW = 0 }
        if ($cmdW -gt 40) { $progW += [math]::Min(14, $cmdW - 40); $cmdW = $inner - ($pidW + $progW + $thrW + $userW + $memW + $cpuW + $graphW + 2) }
    } else {
        $progW = $inner - ($pidW + $thrW + $userW + $memW + $cpuW + $graphW + 2)
        if ($progW -lt 10) { $progW = 10 }
    }

    $hdr = $CFaint + 'Pid:'.PadRight($pidW) + 'Program:'.PadRight($progW + 1)
    if ($cmdW -gt 0) { $hdr += 'Command:'.PadRight($cmdW + 1) }
    $hdr += 'Threads:'.PadLeft($thrW)
    if ($userW) { $hdr += ' ' + 'User:'.PadRight($userW) }
    $hdr += 'MemB'.PadLeft($memW) + ''.PadLeft($graphW) + 'Cpu%'.PadLeft($cpuW) + $RS
    Frame-Set $r (Box-Row $hdr $W)
    $r++

    $listH = $limit - $r
    if ($listH -lt 1) { $listH = 1 }
    $state.ProcRect.Top = $r
    $state.ProcRect.Rows = $listH

    if ($state.Sel -lt 0) { $state.Sel = 0 }
    if ($state.Sel -ge $View.Count) { $state.Sel = [math]::Max(0, $View.Count - 1) }
    if ($state.Sel -lt $state.Scroll) { $state.Scroll = $state.Sel }
    if ($state.Sel -ge $state.Scroll + $listH) { $state.Scroll = $state.Sel - $listH + 1 }
    if ($state.Scroll -lt 0) { $state.Scroll = 0 }

    for ($i = 0; $i -lt $listH; $i++) {
        $vi = $state.Scroll + $i
        if ($vi -ge $View.Count) { Frame-Set $r (Box-Row '' $W); $r++; continue }

        $entry = $View[$vi]
        $p = $entry[0]; $depth = [int]$entry[1]; $isLast = [bool]$entry[2]
        $ppid = [int]$p[$IDX.Pid]

        $nm = [string]$p[$IDX.Name]
        if ($state.Tree -and $depth -gt 0) {
            $branch = if ($isLast) { $GL.TreeLast } else { $GL.TreeBranch }
            $nm = (' ' * (($depth - 1) * 2)) + [string]$branch + [string]$GL.TreeLine + ' ' + $nm
        }

        $cpu = [double]$p[$IDX.Cpu]
        $ws  = [double]$p[$IDX.WS]

        $nameCol = $CTitle
        if ($state.Alerts) {
            if ($cpu -ge $cfg.Thresholds.ProcCpuPercent) { $nameCol = Fg $TH.Bad }
            elseif (($ws / 1MB) -ge $cfg.Thresholds.ProcMemMB) { $nameCol = Fg $TH.Warn }
        }

        $line = $CFaint + ([string]$ppid).PadRight($pidW) + $RS +
                $nameCol + (Trunc-Vis $nm $progW).PadRight($progW + 1) + $RS

        if ($cmdW -gt 0) {
            if (-not $script:PathCache.ContainsKey($ppid)) {
                $pp = ''
                try { $pp = [PsTop20.ProcInfo]::ImagePath($ppid) } catch { }
                if (-not $pp) { $pp = '-' }
                $script:PathCache[$ppid] = $pp
            }
            $line += $CFaint + (Trunc-Vis $script:PathCache[$ppid] $cmdW).PadRight($cmdW + 1) + $RS
        }

        $line += $CText + ([string]$p[$IDX.Threads]).PadLeft($thrW) + $RS
        if ($userW) {
            if (-not $script:OwnerCache.ContainsKey($ppid)) {
                $o = ''
                try { $o = [PsTop20.ProcInfo]::Owner($ppid) } catch { }
                if ($o -and $o.Contains('\')) { $o = $o.Substring($o.LastIndexOf('\') + 1) }
                if (-not $o) { $o = '-' }
                $script:OwnerCache[$ppid] = $o
            }
            $line += ' ' + $CAcc2 + (Trunc-Vis $script:OwnerCache[$ppid] ($userW - 1)).PadRight($userW) + $RS
        }
        $line += $CText + (Fmt-Bytes $ws).PadLeft($memW) + $RS +
                 ' ' + (Bar ($cpu / 100) ($graphW - 1)) +
                 (Ramp-Colour ($cpu / 100)) + ('{0,6:N1}' -f $cpu) + $RS

        if ($vi -eq $state.Sel) {
            $plain = ($line -replace "$ESC\[[0-9;?]*[a-zA-Z]", '')
            $line = $CSelBg + $BOLD + (Fg $TH.Title) + (Pad-Vis $plain $inner) + $RS
        }
        Frame-Set $r (Box-Row $line $W)
        $r++
    }

    $hintL = ''
    if ($state.FilterMode) {
        $hintL = 'filter: ' + $state.Filter + '_  Enter apply  Esc cancel'
    } elseif ($state.Filter) {
        $hintL = 'filter: ' + $state.Filter
    } else {
        $hintL = [string][char]0x2191 + ' select ' + [string][char]0x2193 + '   d info   k terminate'
    }
    $counter = '{0}/{1}' -f ($state.Sel + 1), $View.Count
    Frame-Set $limit (Box-BottomLR $W $hintL $counter)
}

# ---------------------------------------------------------------------------

function Draw-Help {
    param([int]$W, [int]$H)
    $lines = @(
        '',
        '  ' + $BOLD + (Fg $TH.Title) + "pstop $AppVersion" + $RS + $CFaint + '   a btop-style monitor for Windows' + $RS,
        '',
        '  ' + $CAccent + 'navigation' + $RS,
        '    up down          move selection        pgup pgdn   page',
        '    home end         first and last process',
        '',
        '  ' + $CAccent + 'sorting and view' + $RS,
        '    c m p n i h      sort by cpu, memory, pid, name, io, handles',
        '    r                reverse the sort order',
        '    t                tree view on and off',
        '    l                cpu sort smoothing (lazy) on and off',
        '    M                nest disks inside the mem box',
        '    f                filter by name or pid',
        '    d                detail pane: owner, path, command line',
        '    g                graph symbols: block, braille, tty',
        '    T                cycle theme',
        '',
        '  ' + $CAccent + 'panels' + $RS,
        '    1 2 3 4          cpu, mem, disk, net',
        '    5 6 7            gpu, connections, kernel',
        '    P                cycle layout presets',
        '',
        '  ' + $CAccent + 'actions' + $RS,
        '    k                kill the selected process (confirms first)',
        '    a                alerts on and off',
        '    w                write settings to pstop.config.json',
        '    + -              update interval up and down (ms)',
        '    space            pause and resume sampling',
        '    q or Esc         quit',
        '',
        '  ' + $CFaint + 'CPU% is normalised across all cores, so one saturated core of' + $RS,
        '  ' + $CFaint + 'sixteen reads as about 6%, matching Task Manager.' + $RS,
        '  ' + $CFaint + 'Config and logs live beside this script.' + $RS,
        '',
        '  ' + $CFaint + 'press any key to go back' + $RS
    )
    Frame-Reset $H
    Frame-Set 0 (Box-Top 'help' $W '')
    for ($i = 0; $i -lt $lines.Count -and $i -lt $H - 2; $i++) { Frame-Set ($i + 1) (Box-Row $lines[$i] $W) }
    for ($i = $lines.Count + 1; $i -lt $H - 1; $i++) { Frame-Set $i (Box-Row '' $W) }
    Frame-Set ($H - 1) (Box-Bottom $W)
}


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

# Returns one of: $null, a ConsoleKeyInfo-like hashtable, or a mouse hashtable.
#
# $Host.UI.RawUI.KeyAvailable reports true for ANY console input event, mouse
# movement and focus changes included, but ReadKey then blocks until a real key
# arrives. Moving the mouse over the window was enough to hang the program.
# [Console]::KeyAvailable discards non-key events, so the pair cannot deadlock.
# With mouse mode on, VT input is enabled and everything arrives as escape
# sequences, so that path is parsed by hand instead.
function Read-Event {
    $have = $false
    try { $have = [Console]::KeyAvailable } catch { return $null }
    if (-not $have) { return $null }

    $k = [Console]::ReadKey($true)

    if (-not $script:MouseOn) {
        return @{ Kind = 'key'; Char = [string]$k.KeyChar; Key = [string]$k.Key }
    }

    # VT input mode: Esc starts a sequence
    if ($k.KeyChar -ne [char]27) {
        return @{ Kind = 'key'; Char = [string]$k.KeyChar; Key = [string]$k.Key }
    }

    $seq = ''
    $deadline = [DateTime]::UtcNow.AddMilliseconds(40)
    while ([DateTime]::UtcNow -lt $deadline -and $seq.Length -lt 32) {
        $more = $false
        try { $more = [Console]::KeyAvailable } catch { }
        if (-not $more) { Start-Sleep -Milliseconds 2; continue }
        $c = [Console]::ReadKey($true).KeyChar
        $seq += [string]$c
        if ($seq.Length -gt 1 -and ($c -eq 'M' -or $c -eq 'm' -or ($c -match '[A-La-lN-Zn-z~]' -and $seq[0] -eq '['))) { break }
    }

    if (-not $seq) { return @{ Kind = 'key'; Char = ''; Key = 'Escape' } }

    # SGR mouse: [<button;col;rowM  (press) or m (release)
    if ($seq -match '^\[<(\d+);(\d+);(\d+)([Mm])$') {
        $btn = [int]$Matches[1]
        return @{
            Kind = 'mouse'
            Button = $btn
            X = [int]$Matches[2]
            Y = [int]$Matches[3]
            Down = ($Matches[4] -eq 'M')
            Wheel = $(if ($btn -eq 64) { -1 } elseif ($btn -eq 65) { 1 } else { 0 })
        }
    }

    switch -Regex ($seq) {
        '^\[A'   { return @{ Kind = 'key'; Char = ''; Key = 'UpArrow' } }
        '^\[B'   { return @{ Kind = 'key'; Char = ''; Key = 'DownArrow' } }
        '^\[C'   { return @{ Kind = 'key'; Char = ''; Key = 'RightArrow' } }
        '^\[D'   { return @{ Kind = 'key'; Char = ''; Key = 'LeftArrow' } }
        '^\[5~'  { return @{ Kind = 'key'; Char = ''; Key = 'PageUp' } }
        '^\[6~'  { return @{ Kind = 'key'; Char = ''; Key = 'PageDown' } }
        '^\[1~'  { return @{ Kind = 'key'; Char = ''; Key = 'Home' } }
        '^\[4~'  { return @{ Kind = 'key'; Char = ''; Key = 'End' } }
        '^\[7~'  { return @{ Kind = 'key'; Char = ''; Key = 'Home' } }
        '^\[8~'  { return @{ Kind = 'key'; Char = ''; Key = 'End' } }
        '^\[H'   { return @{ Kind = 'key'; Char = ''; Key = 'Home' } }
        '^\[F'   { return @{ Kind = 'key'; Char = ''; Key = 'End' } }
    }

    # An escape sequence we do not recognise is IGNORED, never reported as a bare
    # Escape. Reporting it as Escape made function keys, Delete, Insert and the
    # terminal's own replies all quit the program.
    Diag ('unhandled input sequence: ' + ($seq -replace '[^\x20-\x7e]', '?'))
    return $null
}

# Returns one of: 'quit', 'kill', 'redraw', 'none' - ALWAYS a string.
#
# It used to return $true for a handled key, and the caller tested
# `$res -eq 'quit'`. PowerShell coerces the right operand to the left operand's
# type, so [bool]$true -eq 'quit' became $true -eq [bool]'quit' - and a
# non-empty string is $true. Every handled keypress therefore quit the program.
function Handle-Key {
    param($Ev, $View)

    if ($Ev.Kind -eq 'mouse') {
        Diag ('mouse btn={0} x={1} y={2} down={3}' -f $Ev.Button, $Ev.X, $Ev.Y, $Ev.Down)
        if ($Ev.Wheel -ne 0) { $state.Sel += ($Ev.Wheel * 3); $state.SelMoved = $true; return 'redraw' }
        if ($Ev.Down -and $Ev.Button -eq 0) {
            # terminal coordinates are 1-based
            $row = $Ev.Y - 1
            $col = $Ev.X - 1
            $top = $state.ProcRect.Top
            if ($row -ge $top -and $row -lt $top + $state.ProcRect.Rows -and
                $col -ge $state.ProcRect.Left) {
                $idx = $state.Scroll + ($row - $top)
                if ($idx -lt $View.Count) { $state.Sel = $idx; $state.SelMoved = $true; return 'redraw' }
            }
        }
        return 'none'
    }

    $ch = [string]$Ev.Char
    $key = [string]$Ev.Key

    if ($state.FilterMode) {
        if ($key -eq 'Enter')     { $state.FilterMode = $false; $state.Sel = 0; $state.Scroll = 0; return 'redraw' }
        if ($key -eq 'Escape')    { $state.FilterMode = $false; $state.Filter = ''; return 'redraw' }
        if ($key -eq 'Backspace') {
            if ($state.Filter.Length -gt 0) { $state.Filter = $state.Filter.Substring(0, $state.Filter.Length - 1) }
            return 'redraw'
        }
        if ($ch -and [int][char]$ch -ge 32) { $state.Filter += $ch; return 'redraw' }
        return 'redraw'
    }

    if ($state.Help) { $state.Help = $false; Frame-Invalidate; return 'redraw' }

    switch ($key) {
        'UpArrow'   { $state.Sel--;      $state.SelMoved = $true; return 'redraw' }
        'DownArrow' { $state.Sel++;      $state.SelMoved = $true; return 'redraw' }
        'PageUp'    { $state.Sel -= 10;  $state.SelMoved = $true; return 'redraw' }
        'PageDown'  { $state.Sel += 10;  $state.SelMoved = $true; return 'redraw' }
        'Home'      { $state.Sel = 0;    $state.SelMoved = $true; return 'redraw' }
        'End'       { $state.Sel = $View.Count - 1; $state.SelMoved = $true; return 'redraw' }
        'Escape'    { return 'quit' }
    }

    switch -CaseSensitive ($ch) {
        'q' { return 'quit' }
        'k' { return 'kill' }
        'K' { return 'kill' }
        'c' { $state.SortKey = 'cpu';     return 'redraw' }
        'm' { $state.SortKey = 'mem';     return 'redraw' }
        'p' { $state.SortKey = 'pid';     return 'redraw' }
        'n' { $state.SortKey = 'name';    return 'redraw' }
        'i' { $state.SortKey = 'io';      return 'redraw' }
        'h' { $state.SortKey = 'handles'; return 'redraw' }
        'r' { $state.SortDesc = -not $state.SortDesc; return 'redraw' }
        't' { $state.Tree = -not $state.Tree; $state.Sel = 0; $state.Scroll = 0; return 'redraw' }
        'f' { $state.FilterMode = $true; return 'redraw' }
        'd' { $state.Detail = -not $state.Detail; Frame-Invalidate; return 'redraw' }
        'M' {
            $state.Combine = -not $state.Combine
            Say $(if ($state.Combine) { 'disks nested in mem box' } else { 'disks in their own box' })
            Frame-Invalidate
            return 'redraw'
        }
        'l' {
            $state.Lazy = -not $state.Lazy
            Say $(if ($state.Lazy) { 'sort: cpu lazy' } else { 'sort: cpu direct' })
            return 'redraw'
        }
        'a' {
            $state.Alerts = -not $state.Alerts
            Say $(if ($state.Alerts) { 'alerts on' } else { 'alerts off' })
            return 'redraw'
        }
        'T' {
            $order = @('btop','nord','gruvbox','dracula','solarized','default','matrix','ice','amber','mono')
            $i = [array]::IndexOf($order, [string]$cfg.Theme)
            if ($i -lt 0) { $i = 0 }
            $cfg.Theme = $order[($i + 1) % $order.Count]
            Apply-Theme $cfg.Theme
            Say ('theme: ' + $cfg.Theme)
            Frame-Invalidate
            return 'redraw'
        }
        'g' {
            $order = @('braille','block','tty')
            $i = [array]::IndexOf($order, $script:GraphMode)
            if ($i -lt 0) { $i = 0 }
            $script:GraphMode = $order[($i + 1) % $order.Count]
            Set-Glyphs
            Say ('graph symbols: ' + $script:GraphMode)
            Frame-Invalidate
            return 'redraw'
        }
        'w' {
            if (Save-Config) { Say ('settings written to ' + (Split-Path -Leaf $ConfigPath)) }
            else { Say 'could not write config' 5 }
            return 'redraw'
        }
        'P' {
            $script:PresetIdx = ($script:PresetIdx + 1) % $PresetOrder.Count
            Apply-Preset $PresetOrder[$script:PresetIdx]
            Say ('preset: ' + $PresetOrder[$script:PresetIdx])
            return 'redraw'
        }
        '?' { $state.Help = $true; Frame-Invalidate; return 'redraw' }
        '1' { $state.ShowCpu    = -not $state.ShowCpu;    Frame-Invalidate; return 'redraw' }
        '2' { $state.ShowMem    = -not $state.ShowMem;    Frame-Invalidate; return 'redraw' }
        '3' { $state.ShowDisk   = -not $state.ShowDisk;   Frame-Invalidate; return 'redraw' }
        '4' { $state.ShowNet    = -not $state.ShowNet;    Frame-Invalidate; return 'redraw' }
        '5' { $state.ShowGpu    = -not $state.ShowGpu;    Frame-Invalidate; return 'redraw' }
        '6' { $state.ShowConn   = -not $state.ShowConn;   Frame-Invalidate; return 'redraw' }
        '7' { $state.ShowKernel = -not $state.ShowKernel; Frame-Invalidate; return 'redraw' }
        # The title bar reads "- 1500ms +", so + raises the number and - lowers
        # it, as in btop. It was inverted.
        '+' { $state.Interval = [math]::Min(60000, $state.Interval + 250); Say ("update {0} ms" -f $state.Interval); return 'redraw' }
        '=' { $state.Interval = [math]::Min(60000, $state.Interval + 250); Say ("update {0} ms" -f $state.Interval); return 'redraw' }
        '-' { $state.Interval = [math]::Max(250, $state.Interval - 250); Say ("update {0} ms" -f $state.Interval); return 'redraw' }
        '_' { $state.Interval = [math]::Max(250, $state.Interval - 250); Say ("update {0} ms" -f $state.Interval); return 'redraw' }
        ' ' { $state.Paused = -not $state.Paused; return 'redraw' }
    }
    return 'none'
}

function Confirm-Kill {
    param($Proc, [int]$W, [int]$H)
    $name = [string]$Proc[$IDX.Name]
    $procId = [int]$Proc[$IDX.Pid]

    $box = @(
        '',
        '  ' + $BOLD + (Fg $TH.Bad) + 'Kill this process?' + $RS,
        '',
        '    ' + $CText + $name + $RS + $CFaint + '   pid ' + $procId + $RS,
        '    ' + $CFaint + 'threads ' + $Proc[$IDX.Threads] + '   handles ' + $Proc[$IDX.Handles] +
              '   mem ' + (Fmt-Bytes $Proc[$IDX.WS]) + $RS,
        '',
        '  ' + $CWarn + 'y' + $RS + $CFaint + ' to confirm, anything else to cancel' + $RS,
        ''
    )
    $bw = [math]::Min(60, $W - 4)
    $top = [int](($H - $box.Count - 2) / 2)

    Frame-Set $top (Box-Top 'confirm' $bw '')
    for ($i = 0; $i -lt $box.Count; $i++) { Frame-Set ($top + 1 + $i) (Box-Row $box[$i] $bw) }
    Frame-Set ($top + $box.Count + 1) (Box-Bottom $bw)
    Frame-Flush

    $k = [Console]::ReadKey($true)
    Frame-Invalidate
    if ([string]$k.KeyChar -match '^(y|Y)$') {
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
            Say ("killed $name ($procId)")
            ('[{0:yyyy-MM-dd HH:mm:ss}] killed {1} pid {2}' -f (Get-Date), $name, $procId) | Add-Content $AlertLog
        } catch {
            Say ("could not kill $name : " + $_.Exception.Message) 5
        }
    } else { Say 'cancelled' }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($Diag) {
    "pstop $AppVersion diagnostic start $(Get-Date -Format 's')" | Set-Content $DiagFile
    "host=$($Host.Name) ps=$($PSVersionTable.PSVersion) config=$ConfigStatus mouse=$script:MouseOn" |
        Add-Content $DiagFile
}

$script:BootTime = $null
try { $script:BootTime = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime }
catch { try { $script:BootTime = (Get-Date).AddMilliseconds(-[Environment]::TickCount) } catch { } }

$script:Tick = 0
$script:DetailCache = @{}
$script:OwnerCache  = @{}
$script:PathCache   = @{}
$script:TotalPhys   = 0
$lastW = 0; $lastH = 0
$volumes = Sample-Volumes
$volTick = 0
$gpuTick = 99
$connTick = 99
$procRows = @()
$gpus = @()
$conns = @()
$view = @()
$freq = $null

try { [PsTop20.Gpu]::Init() | Out-Null } catch { }

if ($Log -and -not (Test-Path $MetricsCsv)) {
    'Time,CpuPct,MemPct,AvailGB,PagedGB,NonPagedGB,Handles,Threads,Procs,NetDownBps,NetUpBps,GpuPct,GpuMemPct' |
        Set-Content $MetricsCsv
}

Set-Glyphs
[Console]::Write("${ESC}[?1049h${ESC}[?25l${ESC}[2J")
# 1000 = button press/release, 1002 = also report drag, 1006 = SGR encoding
# (SGR is the one that keeps working past column 223).
if ($script:MouseOn) { [Console]::Write("${ESC}[?1000h${ESC}[?1002h${ESC}[?1006h") }
$origTitle = ''
try { $origTitle = $Host.UI.RawUI.WindowTitle; $Host.UI.RawUI.WindowTitle = 'pstop' } catch { }

$ErrorActionPreference = 'Continue'

try {
    while ($true) {

        $W = 100; $H = 40
        try { $W = $Host.UI.RawUI.WindowSize.Width; $H = $Host.UI.RawUI.WindowSize.Height } catch { }
        if ($W -lt 60) { $W = 60 }
        if ($H -lt 20) { $H = 20 }
        if ($W -ne $lastW -or $H -ne $lastH) {
            Frame-Invalidate
            [Console]::Write("${ESC}[2J")
            $lastW = $W; $lastH = $H
        }

        $script:CoreCols = 1
        if ($W -ge 100) { $script:CoreCols = 2 }
        if ($W -ge 150) { $script:CoreCols = 3 }
        if ($W -ge 175) { $script:CoreCols = 4 }
        if ($W -ge 215) { $script:CoreCols = 6 }

        # ---- sample
        Diag 'loop-top'
        if (-not $state.Paused) {
            $cores = [PsTop20.Cpu]::Sample()
            Diag ('cpu cores={0} status={1}' -f $cores.Count, [PsTop20.Cpu]::LastStatus)
            $memRow = [PsTop20.Mem]::Sample()
            $procRows = @([PsTop20.Procs]::Sample())
            Diag ('procs={0}' -f $procRows.Count)

            try { $freq = [PsTop20.Power]::CoreFreq($cores.Count) } catch { $freq = $null }

            $volTick++
            if ($volTick -ge 20) { $volumes = Sample-Volumes; $volTick = 0 }
            $letters = [string[]]@($volumes | ForEach-Object { $_.Letter })
            $diskIo = $null
            try { $diskIo = [PsTop20.Disk]::Sample($letters) } catch { }
            Diag 'disk'

            $nics = Sample-Net
            Diag 'net'

            # GPU and the socket table change slowly and cost more, so they are
            # sampled every few seconds rather than every frame.
            $gpuTick++
            # NOT gated on the GPU panel: the cpu box shows a GPU row and the
            # second half of its graph regardless, so gating the sample on the
            # panel left both saying "no NVML data" until you pressed 5.
            # When there is no NVIDIA card, Sample returns immediately.
            if ($gpuTick -ge [math]::Max(1, [int](2000 / $state.Interval))) {
                try { $gpus = @([PsTop20.Gpu]::Sample()) } catch { $gpus = @() }
                $gpuTick = 0
                Diag ('gpu devices={0}' -f $gpus.Count)
            }
            $connTick++
            if ($state.ShowConn -and $connTick -ge [math]::Max(1, [int](2000 / $state.Interval))) {
                try { $conns = @([PsTop20.Conn]::Sample()) } catch { $conns = @() }
                $connTick = 0
                Diag ('conns={0}' -f $conns.Count)
            }

            $totalCpu = 0.0
            if ($cores.Count -gt 0) {
                foreach ($c in $cores) { $totalCpu += $c }
                $totalCpu = $totalCpu / $cores.Count
            }
            Push-Hist $hist.Cpu $totalCpu
            Push-Load $totalCpu
            $script:TotalPhys = [double]$memRow[0]

            $memFrac = 0.0
            if ($memRow[0] -gt 0) { $memFrac = ($memRow[0] - $memRow[1]) / [double]$memRow[0] * 100 }
            Push-Hist $hist.Mem $memFrac
            Push-Hist $hist.Handles ([double]$memRow[9])

            $nr = 0.0; $ns = 0.0
            foreach ($n in $nics) { $nr += $n.Recv; $ns += $n.Sent }
            Push-Hist $hist.NetR $nr
            Push-Hist $hist.NetS $ns

            $gpuPct = 0.0; $gpuMemPct = 0.0
            if ($gpus.Count -gt 0) {
                $gpuPct = [double]$gpus[0][1]
                if ([double]$gpus[0][4] -gt 0) { $gpuMemPct = [double]$gpus[0][3] / [double]$gpus[0][4] * 100 }
            }
            Push-Hist $hist.Gpu $gpuPct
            Push-Hist $hist.GpuMem $gpuMemPct

            Check-Alert 'cpu' ($totalCpu -ge $cfg.Thresholds.CpuPercent) ("cpu at {0:N0}%" -f $totalCpu)
            Check-Alert 'mem' ($memFrac -ge $cfg.Thresholds.MemPercent) ("memory at {0:N0}%" -f $memFrac)

            if ($Log) {
                ('{0:s},{1:N1},{2:N1},{3:N2},{4:N2},{5:N2},{6},{7},{8},{9:N0},{10:N0},{11:N0},{12:N0}' -f `
                    (Get-Date), $totalCpu, $memFrac, ($memRow[1]/1GB), ($memRow[5]/1GB), ($memRow[6]/1GB),
                    $memRow[9], $memRow[8], $memRow[7], $nr, $ns, $gpuPct, $gpuMemPct) |
                    Add-Content $MetricsCsv
            }
        }

        # ---- shape process list
        $rows = $procRows
        if ($state.Filter) {
            $f = $state.Filter
            $rows = @($rows | Where-Object {
                ([string]$_[$IDX.Name]) -like "*$f*" -or ([string]$_[$IDX.Pid]) -like "*$f*"
            })
        }
        Update-CpuEma $procRows
        $sorted = Sort-Rows $rows $state.SortKey $state.SortDesc $state.Lazy

        if ($state.Tree) {
            $view = Build-Tree $sorted
        } else {
            $view = @()
            foreach ($rr in $sorted) { $view += ,@($rr, 0, $true) }
        }

        # Resolve the selection to a PID, not a row number. Without this the
        # highlight stays put while the list reorders underneath it, so the
        # process you aimed at is not the one k or d would act on.
        if ($view.Count -eq 0) {
            $state.Sel = 0
            $state.SelPid = 0
        } elseif ($state.SelMoved -or $state.SelPid -le 0) {
            # the user just moved the cursor: adopt whatever is under it
            if ($state.Sel -lt 0) { $state.Sel = 0 }
            if ($state.Sel -ge $view.Count) { $state.Sel = $view.Count - 1 }
            $state.SelPid = [int]$view[$state.Sel][0][$IDX.Pid]
            $state.SelMoved = $false
        } else {
            $found = -1
            for ($i = 0; $i -lt $view.Count; $i++) {
                if ([int]$view[$i][0][$IDX.Pid] -eq $state.SelPid) { $found = $i; break }
            }
            if ($found -ge 0) {
                $state.Sel = $found
            } else {
                # it exited or was filtered out. Hold the row rather than
                # jumping to the top, and adopt the process now under it.
                if ($state.Sel -ge $view.Count) { $state.Sel = $view.Count - 1 }
                if ($state.Sel -lt 0) { $state.Sel = 0 }
                $state.SelPid = [int]$view[$state.Sel][0][$IDX.Pid]
            }
        }

        if ($state.Help) {
            Draw-Help $W $H
            Frame-Flush
            $null = [Console]::ReadKey($true)
            $state.Help = $false
            Frame-Invalidate
            continue
        }

        Frame-Reset $H

        $script:Tick++

        $y = 0
        $bodyBottom = $H - 1

        if ($state.ShowCpu) {
            # The cpu box height is driven by the per-core sub-box on its right,
            # which lays cores out in 2 columns. Sizing it from $script:CoreCols
            # (which grows with width) made the box SHORTER on a wider terminal
            # and chopped Load AVG and the GPU row off the bottom.
            # Sub-box needs: top border, CPU row, core rows, Load AVG, GPU,
            # bottom border = coreRows + 5, plus the panel's own two borders.
            $coreRows = [int][math]::Ceiling($cores.Count / 2.0)
            $cpuH = $coreRows + 7
            if ($cpuH -gt [int]($H * 0.6)) { $cpuH = [int]($H * 0.6) }
            if ($cpuH -lt 8) { $cpuH = 8 }
            # busiest process by cpu, for the spare room on the stats line
            $topProc = $null
            if ($procRows.Count -gt 0) {
                $best = $null; $bestCpu = -1.0
                foreach ($p in $procRows) {
                    $pc = [double]$p[$IDX.Cpu]
                    if ($pc -gt $bestCpu) { $bestCpu = $pc; $best = $p }
                }
                if ($best) { $topProc = @([string]$best[$IDX.Name], $bestCpu) }
            }
            try { Draw-Cpu $y $W $cpuH $cores $totalCpu $memRow $freq $topProc }
            catch {
                Diag ('panel cpu failed: ' + $_.Exception.Message)
                Frame-Set $y (Box-Top 'cpu' $W 'error')
                Frame-Set ($y + 1) (Box-Row ((Fg $TH.Bad) + (Trunc-Vis ([string]$_.Exception.Message) ($W - 6)) + $RS) $W)
                for ($z = $y + 2; $z -lt $y + $cpuH - 1; $z++) { Frame-Set $z (Box-Row '' $W) }
                Frame-Set ($y + $cpuH - 1) (Box-Bottom $W)
            }
            $y += $cpuH
        }

        $restH = $bodyBottom - $y
        if ($restH -lt 6) { $restH = 6 }

        $leftW = 0
        $sidePanels = @()
        if ($state.ShowMem -or $state.ShowDisk -or $state.ShowNet -or
            $state.ShowGpu -or $state.ShowKernel) {
            $leftW = [int]($W * 0.45)
            if ($leftW -lt 48) { $leftW = 48 }
            if ($state.ShowProc -and $leftW -gt $W - 46) { $leftW = $W - 46 }
            if (-not $state.ShowProc) { $leftW = $W }
        }

        # btop keeps disks inside the memory box. Only do that when the column is
        # wide enough for two readable halves, otherwise they stay separate.
        # Whether disks nest inside the mem box is a SETTING, not something the
        # width decides. It used to flip automatically past 76 columns, so going
        # full screen silently merged two boxes into one and read as a panel
        # disappearing. The set of boxes is now identical at every size.
        $combineMemDisk = ($state.Combine -and $state.ShowMem -and $state.ShowDisk -and ($leftW - 2) -ge 76)
        if ($combineMemDisk) { $sidePanels += 'memdisk' }
        else {
            if ($state.ShowMem)  { $sidePanels += 'mem' }
            if ($state.ShowDisk) { $sidePanels += 'disk' }
        }
        if ($state.ShowNet)    { $sidePanels += 'net' }
        if ($state.ShowGpu)    { $sidePanels += 'gpu' }
        if ($state.ShowKernel) { $sidePanels += 'kernel' }

        if ($sidePanels.Count -gt 0) {
            $sy = $y
            $n = $sidePanels.Count
            $each = [int]($restH / $n)
            if ($each -lt 4) { $each = 4 }
            for ($i = 0; $i -lt $n; $i++) {
                $ph = $each
                if ($i -eq $n - 1) { $ph = $bodyBottom - $sy }
                # never let a panel run past the body, or it is drawn into rows
                # the frame discards and vanishes without explanation
                if ($sy + $ph -gt $bodyBottom) { $ph = $bodyBottom - $sy }
                if ($ph -lt 4) { break }
                # A fault in one panel must not take the program down. It is
                # reported in the panel's own space and in the diag log; every
                # other panel keeps rendering.
                try {
                    switch ($sidePanels[$i]) {
                        'memdisk' { Draw-MemDisk $sy $leftW $ph $memRow $volumes $diskIo }
                        'mem'     { Draw-Mem     $sy $leftW $ph $memRow }
                        'disk'    { Draw-Disk    $sy $leftW $ph $volumes $diskIo }
                        'net'     { Draw-Net     $sy $leftW $ph $nics }
                        'gpu'     { Draw-Gpu     $sy $leftW $ph $gpus }
                        'kernel'  { Draw-Kernel  $sy $leftW $ph $memRow }
                    }
                } catch {
                    Diag ('panel ' + $sidePanels[$i] + ' failed: ' + $_.Exception.Message)
                    Frame-Set $sy (Box-Top $sidePanels[$i] $leftW 'error')
                    $msgTxt = Trunc-Vis ([string]$_.Exception.Message) ($leftW - 6)
                    if ($sy + 1 -lt $sy + $ph - 1) {
                        Frame-Set ($sy + 1) (Box-Row ((Fg $TH.Bad) + $msgTxt + $RS) $leftW)
                    }
                    for ($z = $sy + 2; $z -lt $sy + $ph - 1; $z++) { Frame-Set $z (Box-Row '' $leftW) }
                    Frame-Set ($sy + $ph - 1) (Box-Bottom $leftW)
                }
                $sy += $ph
            }
        }

        if ($state.ShowProc) {
            $px = $leftW
            $pw = $W - $leftW
            if ($pw -lt 40) { $pw = 40 }
            $state.ProcRect.Left = $px

            # split the right column between proc, connections and detail
            $detailH = 0
            if ($state.Detail) { $detailH = [math]::Min(10, [int]($restH * 0.4)) }
            $connH = 0
            if ($state.ShowConn) { $connH = [math]::Min([int]$cfg.ConnLines + 4, [int](($restH - $detailH) * 0.5)) }
            $procH = $restH - $connH - $detailH
            if ($procH -lt 6) { $procH = 6; $connH = [math]::Max(0, $restH - $procH - $detailH) }

            $saveFrame = $script:Frame
            $script:Frame = New-Object string[] $H
            for ($i = 0; $i -lt $H; $i++) { $script:Frame[$i] = '' }

            try { Draw-Proc $y $pw $procH $view $procRows.Count }
            catch {
                Diag ('panel proc failed: ' + $_.Exception.Message)
                Frame-Set $y (Box-Top 'proc' $pw 'error')
                Frame-Set ($y + 1) (Box-Row ((Fg $TH.Bad) + (Trunc-Vis ([string]$_.Exception.Message) ($pw - 6)) + $RS) $pw)
                for ($z = $y + 2; $z -lt $y + $procH - 1; $z++) { Frame-Set $z (Box-Row '' $pw) }
                Frame-Set ($y + $procH - 1) (Box-Bottom $pw)
            }
            if ($connH -ge 4) {
                $nameByPid = @{}
                foreach ($p in $procRows) { $nameByPid[[int]$p[$IDX.Pid]] = [string]$p[$IDX.Name] }
                Draw-Conn ($y + $procH) $pw $connH $conns $nameByPid
            }
            if ($detailH -ge 4) {
                $selProc = $null
                if ($view.Count -gt 0 -and $state.Sel -lt $view.Count) { $selProc = $view[$state.Sel][0] }
                Draw-Detail ($y + $procH + $connH) $pw $detailH $selProc
            }

            $procLines = $script:Frame
            $script:Frame = $saveFrame

            for ($i = $y; $i -lt $y + $restH; $i++) {
                if ($i -ge $H) { break }
                $left = $script:Frame[$i]
                if (-not $left) { $left = '' }
                $left = Pad-Vis $left $px
                Frame-Set $i ($left + $procLines[$i])
            }
        }

        # ---- footer
        $msg = ''
        if ($state.Message -and (Get-Date) -lt $state.MsgUntil) {
            $msg = '  ' + (Fg $TH.Warn) + $state.Message + $RS
        }
        $keys = @('? help','k kill','f filter','t tree','d detail','g graph','T theme','w save','q quit')
        $ksep = ' ' + $GL.Dot + ' '
        $foot = $CFaint + ' ' + ($keys -join $ksep) + $RS + $msg
        if ((Get-VisLen $foot) -gt ($W - 18)) {
            $foot = $CFaint + ' ' + (@('? help','k kill','f filter','T theme','q quit') -join $ksep) + $RS + $msg
        }
        $spin = @('|','/','-','\\')[$script:Tick % 4]
        if (-not $Ascii -and -not $Plain) { $spin = @([char]0x2596,[char]0x2598,[char]0x259D,[char]0x2597)[$script:Tick % 4] }
        $right = $CFaint + ('#{0}  ' -f $script:Tick) + $RS + $CAcc2 + $spin + ' ' + $RS
        $gap = $W - (Get-VisLen $foot) - (Get-VisLen $right)
        if ($gap -lt 1) { $gap = 1 }
        Frame-Set ($H - 1) ($foot + (' ' * $gap) + $right)

        Frame-Flush
        try { [Console]::Out.Flush() } catch { }
        Diag 'flushed'

        # ---- input until the next sample is due
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $redraw = $false
        while ($sw.ElapsedMilliseconds -lt $state.Interval) {
            $ev = Read-Event
            if ($ev) {
                $res = 'none'
                try { $res = [string](Handle-Key $ev $view) }
                catch {
                    Diag ('key handler error: ' + $_.Exception.Message)
                    $res = 'none'
                }
                Diag ('key ' + $ev.Key + ' char=' + $ev.Char + ' -> ' + $res)
                if ($res -eq 'quit') { throw 'pstop-quit' }
                elseif ($res -eq 'kill') {
                    if ($view.Count -gt 0 -and $state.Sel -lt $view.Count) {
                        Confirm-Kill $view[$state.Sel][0] $W $H
                    }
                    $redraw = $true
                    break
                }
                elseif ($res -eq 'redraw') { $redraw = $true; break }
            }
            Start-Sleep -Milliseconds 25
        }
        $sw.Stop()
        Diag ('waited {0} redraw={1}' -f $sw.ElapsedMilliseconds, $redraw)
        if ($redraw) { continue }
    }
}
catch {
    if ("$_" -notmatch 'pstop-quit') {
        [Console]::Write("${ESC}[?25h${ESC}[?1049l")
        try { [VtMode20]::RestoreInput() | Out-Null } catch { }
        Write-Host 'pstop stopped with an error:' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
        return
    }
}
finally {
    if ($script:MouseOn) { [Console]::Write("${ESC}[?1006l${ESC}[?1002l${ESC}[?1000l") }
    [Console]::Write("${ESC}[?25h${ESC}[0m${ESC}[?1049l")
    try { [VtMode20]::RestoreInput() | Out-Null } catch { }
    try { if ($origTitle) { $Host.UI.RawUI.WindowTitle = $origTitle } } catch { }
    Write-Host ("pstop stopped. config {0}: {1}" -f $ConfigStatus, $ConfigPath) -ForegroundColor DarkGray
    if ($Diag) { Write-Host ("diagnostic log: {0}" -f $DiagFile) -ForegroundColor Cyan }
}