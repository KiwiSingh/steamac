using System.Runtime.InteropServices;
// ReSharper disable InconsistentNaming

namespace MVLibraryNET.MVGL.x64;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
internal struct MDB1Header64
{
    public uint Magic;
    public uint FileEntryCount;
    public uint FileNameCount;
    public uint DataEntryCount;
    public ulong DataStart;
    public ulong TotalSize;
}