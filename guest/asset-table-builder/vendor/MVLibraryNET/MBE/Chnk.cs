using System.Diagnostics.CodeAnalysis;

namespace MVLibraryNET.MBE;

public class Chnk
{
    public const int Magic = 0x4B4E4843;
    private readonly Dictionary<int, object> _items = [];

    public void SetChnkItem(int offset, object value) => _items[offset] = value;

    public bool TryGetChnkItem(int offset, [NotNullWhen(true)] out object? obj) => _items.TryGetValue(offset, out obj);

    /// <summary>
    /// Reads Chnk section.<br/>
    /// Any known Chnk items must be set prior to know what data should be read.
    /// </summary>
    public unsafe void Read(BinaryReader br)
    {
        var numItems = br.ReadInt32();
        for (int i = 0; i < numItems; i++)
        {
            var offset = br.ReadInt32();
            if (!_items.TryGetValue(offset, out var initValue)) continue;
            
            if (initValue is int[] ints)
            {
                fixed (int* ptr = ints) br.BaseStream.ReadExactly(new(ptr, ints.Length * sizeof(int)));
                _items[offset] = ints;
            }
            else
            {
                _items[offset] = br.ReadStringIncludingLength();
            }
        }
    }

    /// <summary>
    /// Writes Chnk section with the given writer.
    /// </summary>
    public void Write(BinaryWriter bw)
    {
        bw.Write(Magic);
        if (_items.Count <= 0)
        {
            bw.Write(0);
            return;
        }
        
        bw.Write(_items.Count);
        var numItemsPos = bw.BaseStream.Position - sizeof(int);
        var numItemsAct = 0;
        foreach (var kvp in _items)
        {
            if (kvp.Value is string str)
            {
                if (string.IsNullOrEmpty(str)) continue;
                
                bw.Write(kvp.Key);
                bw.WritePaddedStringIncludingLength(str);
            }
            else if (kvp.Value is int[] ints)
            {
                bw.Write(kvp.Key);
                bw.Write(ints.Length);
                foreach (var i in ints) bw.Write(i);
            }
            else
            {
                throw new($"Unknown Chnk item type: {kvp.Value.GetType()}");
            }
            
            numItemsAct++;
        }

        var currPos = bw.BaseStream.Position;
        
        // Write actual amount of items written.
        bw.BaseStream.Position = numItemsPos;
        bw.Write(numItemsAct);

        bw.BaseStream.Position = currPos;
    }
}