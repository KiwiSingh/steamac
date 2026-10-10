using System.Runtime.InteropServices;
using System.Text;

namespace MVLibraryNET.MVGL.x64;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
internal unsafe struct FileNameEntry64
{
    private const int MaxNameLength = 0x7C;
    
    public fixed byte Extension[4];
    public fixed byte Name[MaxNameLength];

    public override string ToString()
    {
        fixed (byte* namePtr = Name)
        fixed (byte* extPtr = Extension)
        {
            var nameLen = new Span<byte>(namePtr, MaxNameLength).IndexOf((byte)'\0');
            if (nameLen == -1) nameLen = MaxNameLength; // Assumes ' ' isn't always used as some separator character.
            
            var name = Encoding.ASCII.GetString(namePtr, nameLen);
            var extLen = extPtr[3] == (byte)' ' ? 3 : 4;
            var ext = Encoding.ASCII.GetString(extPtr, extLen);
            return $"{name}.{ext}";
        }
    }
}