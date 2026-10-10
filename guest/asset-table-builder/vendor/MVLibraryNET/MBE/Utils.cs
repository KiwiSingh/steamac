using System.Text;

namespace MVLibraryNET.MBE;

public static class Utils
{
    public static string ReadStringIncludingLength(this BinaryReader br)
    {
        var len = br.ReadInt32();
        if (len == 0) return string.Empty;
        
        var strSpan = new Span<byte>(br.ReadBytes(len));
        if (strSpan[^1] == 0)
        {
            strSpan = strSpan[..strSpan.IndexOf((byte)0)];
        }

        return Encoding.UTF8.GetString(strSpan);
    }
    
    public static void WriteStringIncludingLength(this BinaryWriter bw, string str)
    {
        var bytes = Encoding.UTF8.GetBytes(str + '\0');
        bw.Write(bytes.Length);
        bw.Write(bytes);
    }
    
    public static void WritePaddedStringIncludingLength(this BinaryWriter bw, string str)
    {
        str = str.ReplaceLineEndings("\n");
        
        var bytes = Encoding.UTF8.GetBytes(str);
        var alignedLen = Align4(bytes.Length + 2);
        Array.Resize(ref bytes, alignedLen);
        
        bw.Write(alignedLen);
        bw.Write(bytes);
    }

    public static void Align(this Stream stream, byte alignment) =>
        stream.Position = alignment switch
        {
            8 => Align8((int)stream.Position),
            4 => Align4((int)stream.Position),
            2 => Align2((int)stream.Position),
            _ => throw new InvalidOperationException()
        };

    private static int Align8(int offset) => (offset + 7) & ~7;

    private static int Align4(int offset) => (offset + 3) & ~3;

    private static int Align2(int offset) => (offset + 1) & ~1;
    
    public static int CeilInteger(int value, int step) => step == 0 ? value : (value + step - 1) / step * step;
}