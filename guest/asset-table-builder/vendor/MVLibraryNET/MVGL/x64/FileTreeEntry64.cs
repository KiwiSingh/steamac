using System.Runtime.InteropServices;

namespace MVLibraryNET.MVGL.x64;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
internal struct FileTreeEntry64
{
    public uint CompareBit;
    public uint DataId;
    public uint Left;
    public uint Right;
}