using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

public class MiniDashGpuInfo {
    public string Name; public string Luid; public double TotalBytes; public double Util; public double UsedBytes;
    public uint LuidLow; public int LuidHigh; public bool Integrated; public double TempC;
}

public static class MiniDashGpu {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DXGI_ADAPTER_DESC1 {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        public uint VendorId, DeviceId, SubSysId, Revision;
        public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
        public uint LuidLow; public int LuidHigh; public uint Flags;
    }
    [ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDXGIAdapter1 {
        void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
        void EnumOutputs(); void GetDesc(); void CheckInterfaceSupport();
        [PreserveSig] int GetDesc1(out DXGI_ADAPTER_DESC1 desc);
    }
    [ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDXGIFactory1 {
        void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
        void EnumAdapters(); void MakeWindowAssociation(); void GetWindowAssociation(); void CreateSwapChain(); void CreateSoftwareAdapter();
        [PreserveSig] int EnumAdapters1(uint index, out IDXGIAdapter1 adapter);
    }
    [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IDXGIFactory1 factory);

    [DllImport("gdi32.dll")] static extern int D3DKMTOpenAdapterFromLuid(byte[] p);
    [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(byte[] p);
    [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(IntPtr p);

    // タスクマネージャーと同じ方法(D3DKMT ADAPTERPERFDATA)でGPU温度を取得。単位は0.1℃。取れなければ0
    static double ReadTemp(uint low, int high) {
        byte[] o = new byte[12];
        BitConverter.GetBytes(low).CopyTo(o, 0); BitConverter.GetBytes(high).CopyTo(o, 4);
        if (D3DKMTOpenAdapterFromLuid(o) != 0) return 0;
        uint h = BitConverter.ToUInt32(o, 8);
        IntPtr perf = Marshal.AllocHGlobal(64), q = Marshal.AllocHGlobal(24);
        try {
            for (int i = 0; i < 64; i++) Marshal.WriteByte(perf, i, 0);
            Marshal.WriteInt32(q, 0, (int)h); Marshal.WriteInt32(q, 4, 62); Marshal.WriteIntPtr(q, 8, perf); Marshal.WriteInt32(q, 16, 64);
            if (D3DKMTQueryAdapterInfo(q) != 0) return 0;
            return Marshal.ReadInt32(perf, 56) / 10.0;
        } finally {
            Marshal.FreeHGlobal(perf); Marshal.FreeHGlobal(q);
            D3DKMTCloseAdapter(BitConverter.GetBytes(h));
        }
    }

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhOpenQueryW(string src, IntPtr user, out IntPtr query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhAddEnglishCounterW(IntPtr query, string path, IntPtr user, out IntPtr counter);
    [DllImport("pdh.dll")] static extern uint PdhCollectQueryData(IntPtr query);
    [DllImport("pdh.dll")] static extern uint PdhCloseQuery(IntPtr query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhGetFormattedCounterArrayW(IntPtr counter, uint fmt, ref uint size, out uint count, IntPtr buf);

    static List<MiniDashGpuInfo> gpus;
    static IntPtr query = IntPtr.Zero, cEngine, cMem;
    static int tick = 0;
    static Regex reLuid = new Regex(@"luid_(0x[0-9A-Fa-f]+_0x[0-9A-Fa-f]+)", RegexOptions.Compiled);
    static Regex reEng = new Regex(@"engtype_(.*)$", RegexOptions.Compiled);

    public static MiniDashGpuInfo[] Init() {
        gpus = new List<MiniDashGpuInfo>();
        try {
            Guid g = typeof(IDXGIFactory1).GUID; IDXGIFactory1 f;
            if (CreateDXGIFactory1(ref g, out f) == 0) {
                for (uint i = 0; ; i++) {
                    IDXGIAdapter1 a; if (f.EnumAdapters1(i, out a) != 0) break;
                    DXGI_ADAPTER_DESC1 d;
                    if (a.GetDesc1(out d) == 0 && (d.Flags & 2) == 0 && d.VendorId != 0x1414) {
                        string luid = string.Format("0x{0:X8}_0x{1:X8}", (uint)d.LuidHigh, d.LuidLow);
                        if (!gpus.Exists(x => x.Luid == luid))
                            gpus.Add(new MiniDashGpuInfo { Name = d.Description, Luid = luid, TotalBytes = (double)d.DedicatedVideoMemory.ToUInt64(),
                                LuidLow = d.LuidLow, LuidHigh = d.LuidHigh,
                                Integrated = (d.VendorId == 0x1002 || d.VendorId == 0x8086) && d.DedicatedVideoMemory.ToUInt64() < 2UL * 1024 * 1024 * 1024 });
                    }
                    Marshal.ReleaseComObject(a);
                }
                Marshal.ReleaseComObject(f);
            }
        } catch { }
        Reopen();
        return gpus.ToArray();
    }

    static void Reopen() {
        if (query != IntPtr.Zero) PdhCloseQuery(query);
        query = IntPtr.Zero;
        if (PdhOpenQueryW(null, IntPtr.Zero, out query) != 0) { query = IntPtr.Zero; return; }
        PdhAddEnglishCounterW(query, @"\GPU Engine(*)\Utilization Percentage", IntPtr.Zero, out cEngine);
        PdhAddEnglishCounterW(query, @"\GPU Adapter Memory(*)\Dedicated Usage", IntPtr.Zero, out cMem);
        PdhCollectQueryData(query);
    }

    static List<KeyValuePair<string, double>> Read(IntPtr counter) {
        var r = new List<KeyValuePair<string, double>>();
        uint size = 0, count;
        PdhGetFormattedCounterArrayW(counter, 0x200 | 0x8000, ref size, out count, IntPtr.Zero);
        if (size == 0) return r;
        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try {
            if (PdhGetFormattedCounterArrayW(counter, 0x200 | 0x8000, ref size, out count, buf) == 0) {
                for (int i = 0; i < count; i++) {
                    IntPtr item = buf + i * 24;
                    if (Marshal.ReadInt32(item, 8) > 1) continue; // CStatus invalid
                    string name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(item));
                    double v = BitConverter.Int64BitsToDouble(Marshal.ReadInt64(item, 16));
                    r.Add(new KeyValuePair<string, double>(name, v));
                }
            }
        } finally { Marshal.FreeHGlobal(buf); }
        return r;
    }

    public static MiniDashGpuInfo[] Sample() {
        if (gpus == null) Init();
        if (query == IntPtr.Zero) return gpus.ToArray();
        // 新しく起動したプロセスのGPU使用分も拾うため、定期的にカウンターを作り直す
        if (++tick % 15 == 0) { Reopen(); return gpus.ToArray(); }
        if (PdhCollectQueryData(query) != 0) return gpus.ToArray();

        var perEng = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
        foreach (var kv in Read(cEngine)) {
            var ml = reLuid.Match(kv.Key); var me = reEng.Match(kv.Key);
            if (!ml.Success || !me.Success) continue;
            string k = ml.Groups[1].Value + "|" + me.Groups[1].Value;
            double cur; perEng.TryGetValue(k, out cur); perEng[k] = cur + kv.Value;
        }
        var mem = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
        foreach (var kv in Read(cMem)) {
            var ml = reLuid.Match(kv.Key); if (!ml.Success) continue;
            double cur; mem.TryGetValue(ml.Groups[1].Value, out cur); mem[ml.Groups[1].Value] = cur + kv.Value;
        }
        foreach (var g in gpus) {
            double mx = 0;
            foreach (var kv in perEng)
                if (kv.Key.StartsWith(g.Luid + "|", StringComparison.OrdinalIgnoreCase) && kv.Value > mx) mx = kv.Value;
            g.Util = Math.Min(100, mx);
            double u; g.UsedBytes = mem.TryGetValue(g.Luid, out u) ? u : 0;
            try { g.TempC = ReadTemp(g.LuidLow, g.LuidHigh); } catch { g.TempC = 0; }
        }
        return gpus.ToArray();
    }
}
