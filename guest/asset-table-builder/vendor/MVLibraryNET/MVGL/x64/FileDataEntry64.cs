using System.Runtime.InteropServices;

namespace MVLibraryNET.MVGL.x64;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
internal struct FileDataEntry64
{
    public ulong Offset;
    public ulong FullSize;
    public ulong CompressedSize;
}