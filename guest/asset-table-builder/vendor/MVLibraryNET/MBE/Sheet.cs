using System.Diagnostics.CodeAnalysis;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using nietras.SeparatedValues;

namespace MVLibraryNET.MBE;

public unsafe class Sheet
{
    private static readonly SepReaderOptions CsvReader = Sep.Reader(_ => new() { Unescape = true, Sep = new(',') });
    
    internal readonly EntryType[] Entries;
    private readonly long _basePos;
    
    // TODO: Dynamically calculate.
    private readonly int _rowSize;
    private readonly int _initNumRows;
    
    private readonly Dictionary<Cell, object> _cellsChnkValues = [];
    
    // Would *prefer* to calculate cell offset from base pos + row offset
    // but this is shrimply easier... *sigh*
    private readonly Dictionary<long, Cell> _chnkOffsetToCellMap = [];

    public Sheet(string name, string csvContent)
    {
        Name = name;

        using var csv = CsvReader.FromText(csvContent);
        Entries = csv.Header.ColNames.Select(GetColumnType).ToArray();
        _rowSize = Entries.Length;

        var rowIdx = 0;
        foreach (var row in csv)
        {
            for (int colIdx = 0; colIdx < row.ColCount; colIdx++)
            {
                var col = row[colIdx];
                var cellValueStr = col.ToString();
                var cell = new Cell(rowIdx, colIdx);
                var colType = Entries[colIdx];
                var cellValue = GetCellValueFromString(colType, cellValueStr);
                Cells[cell] = cellValue;

                if (IsColumnChnk(colType))
                    _cellsChnkValues[cell] = GetChnkValue(colType, cellValueStr);
            }

            rowIdx++;
        }
    }

    private static EntryType GetColumnType(string typeName)
    {
        typeName = typeName.Split(' ', '_').First().ToLowerInvariant();
        if (Enum.TryParse(typeName, true, out EntryType type) 
            || Enum.TryParse(typeName, true, out type))
        {
            return type;
        }
        
        switch (typeName)
        {
            case "int32": return EntryType.Int;
            case "int16": return EntryType.Short;
            case "int8": return EntryType.Byte;
            case "int array": return EntryType.IntArray;
        }

        throw new InvalidDataException($"Unknown column type: {typeName}");
    }

    public Sheet(string csvFile) : this(Path.GetFileNameWithoutExtension(csvFile), File.ReadAllText(csvFile)) {}

    private readonly record struct EntryProps(int Alignment, int Size);

    private readonly Dictionary<EntryType, EntryProps> _entryTypeProps = new()
    {
        [EntryType.IntArray] = new(8, 16),
        [EntryType.Int] = new(4, 4),
        [EntryType.Short] = new(2, 2),
        [EntryType.Byte] = new(1, 1),
        [EntryType.Float] = new(4, 4),
        [EntryType.String3] = new(8, 8),
        [EntryType.String] = new(8, 8),
        [EntryType.String2] = new(8, 8),
        [EntryType.Bool] = new(4, 4),
        [EntryType.Empty] = new(0, 0),
        [EntryType.Unk1] = new(0, 0),
    };

    public Sheet(BinaryReader reader, Chnk chnk)
    {
        var stream = reader.BaseStream;
        Name = reader.ReadStringIncludingLength();
        
        var numEntries = reader.ReadInt32();
        Entries = GC.AllocateUninitializedArray<EntryType>(numEntries);
        fixed (EntryType* ptr = Entries) stream.ReadExactly(new(ptr, sizeof(EntryType) * numEntries));

        _rowSize = reader.ReadInt32();
        var numRows = reader.ReadInt32();
        
        stream.Align(8);
        var rowBuffer = GC.AllocateUninitializedArray<byte>(Utils.CeilInteger(_rowSize, 8));
        for (var rowIdx = 0; rowIdx < numRows; rowIdx++)
        {
            var rowPos = stream.Position;
            stream.ReadExactly(rowBuffer);
            
            var rowOfs = 0;
            var bitCounter = 0;
            uint currentBits = 0;
            
            for (var entryIdx = 0; entryIdx < numEntries; entryIdx++)
            {
                var cell = new Cell(rowIdx, entryIdx);
                var cellValue = 0L;
                
                var type = Entries[entryIdx];
                var props = _entryTypeProps[type];
                if (type != EntryType.Bool || bitCounter >= 32)
                {
                    if (bitCounter > 0) rowOfs += _entryTypeProps[EntryType.Bool].Size;
                    rowOfs = Utils.CeilInteger(rowOfs, props.Alignment);
                    bitCounter = 0;
                }

                switch (type)
                {
                    case EntryType.Unk1:
                    case EntryType.Empty:
                        break;
                    case EntryType.Bool:
                        if (bitCounter == 0) currentBits = BitConverter.ToUInt32(rowBuffer, rowOfs);
                        cellValue = (currentBits >> bitCounter) & 1;
                        bitCounter++;
                        break;
                    case EntryType.Byte:
                        cellValue = (sbyte)rowBuffer[rowOfs];
                        break;
                    case EntryType.Short:
                        cellValue = BitConverter.ToInt16(rowBuffer, rowOfs);
                        break;
                    case EntryType.Int:
                        cellValue = BitConverter.ToInt32(rowBuffer, rowOfs);
                        break;
                    case EntryType.Float:
                        cellValue = RoundedFloatAsInt(BitConverter.ToSingle(rowBuffer, rowOfs));
                        break;
                    case EntryType.String3:
                    case EntryType.String:
                    case EntryType.String2:
                        chnk.SetChnkItem((int)(rowPos + rowOfs), string.Empty);
                        _chnkOffsetToCellMap[rowPos + rowOfs] = cell;
                        break;
                    case EntryType.IntArray:
                        var numInts = BitConverter.ToInt32(rowBuffer, rowOfs);
                        chnk.SetChnkItem((int)(rowPos + rowOfs), new int[numInts]);
                        _chnkOffsetToCellMap[rowPos + rowOfs] = cell;
                        break;
                    default:
                        throw new ArgumentOutOfRangeException($"Unknown entry type '{type:X}' for entry '{entryIdx}' in row '{rowIdx}'. Sheet: {Name}");
                }

                if (type != EntryType.Bool) rowOfs += props.Size;
                Cells[cell] = cellValue;
            }
        }
    }

    public string Name { get; }

    /// <summary>
    /// Dictionary of cells. Can be assumed to be in sequential order.
    /// </summary>
    public Dictionary<Cell, long> Cells { get; } = [];
    
    /// <summary>
    /// Writes sheet data to stream.
    /// </summary>
    /// <param name="bw"><see cref="BinaryWriter"/> to use.</param>
    /// <param name="chnk">Chnk instance.</param>
    /// <returns>Position to start of row data (needed for writing string map).</returns>
    public void Write(BinaryWriter bw, Chnk chnk)
    {
        var stream = bw.BaseStream;

        var nameBuffer = Encoding.UTF8.GetBytes(Name + '\0');
        Array.Resize(ref nameBuffer, Utils.CeilInteger(nameBuffer.Length, 4));
        bw.Write(nameBuffer.Length);
        bw.Write(nameBuffer);

        bw.Write(Entries.Length);
        fixed (EntryType* ptr = Entries) stream.Write(new(ptr, sizeof(EntryType) * Entries.Length));

        // Cells are sequential, last cell row idx is the same as the total rows.
        var numRows = GetNumRows();
        bw.Write(_rowSize);
        bw.Write(numRows);

        stream.Align(8);
        var rowBuffer = GC.AllocateUninitializedArray<byte>(Utils.CeilInteger(_rowSize, 8));
        for (var rowIdx = 0; rowIdx < numRows; rowIdx++)
        {
            Array.Fill(rowBuffer, (byte)0xCC);
            var rowPos = stream.Position;

            var rowOfs = 0;
            var bitCounter = 0;
            uint currentBits = 0;

            for (var entryIdx = 0; entryIdx < Entries.Length; entryIdx++)
            {
                var cell = new Cell(rowIdx, entryIdx);
                var type = Entries[entryIdx];
                var props = _entryTypeProps[type];
                var cellValue = Cells[cell];

                if (type != EntryType.Bool || bitCounter >= 32)
                {
                    if (bitCounter > 0)
                    {
                        BitConverter.TryWriteBytes(rowBuffer.AsSpan(rowOfs), currentBits);
                        rowOfs += _entryTypeProps[EntryType.Bool].Size;
                    }
                    
                    rowOfs = Utils.CeilInteger(rowOfs, props.Alignment);
                    bitCounter = 0;
                }

                switch (type)
                {
                    case EntryType.Unk1:
                    case EntryType.Empty:
                        break;
                    case EntryType.Bool:
                        if (bitCounter == 0) currentBits = 0;
                        if (cellValue == 1) currentBits |= 1u << bitCounter;
                        bitCounter++;
                        break;
                    case EntryType.Byte:
                        rowBuffer[rowOfs] = Unsafe.BitCast<sbyte, byte>((sbyte)cellValue);
                        break;
                    case EntryType.Short:
                        BitConverter.TryWriteBytes(rowBuffer.AsSpan(rowOfs), (short)cellValue);
                        break;
                    case EntryType.Int:
                        BitConverter.TryWriteBytes(rowBuffer.AsSpan(rowOfs), (int)cellValue);
                        break;
                    case EntryType.Float:
                        BitConverter.TryWriteBytes(rowBuffer.AsSpan(rowOfs), RoundedFloatFromInt((int)cellValue));
                        break;
                    case EntryType.String3:
                    case EntryType.String:
                    case EntryType.String2:
                        BitConverter.TryWriteBytes(rowBuffer.AsSpan(rowOfs), 0L);
                        if (_cellsChnkValues.TryGetValue(cell, out var strChnk))
                            chnk.SetChnkItem((int)(rowPos + rowOfs), strChnk);
                        break;
                    case EntryType.IntArray:
                        if (_cellsChnkValues.TryGetValue(cell, out var intsChnk) && intsChnk is int[] ints)
                        {
                            BitConverter.TryWriteBytes(rowBuffer.AsSpan(rowOfs), ints.Length);
                            chnk.SetChnkItem((int)(rowPos + rowOfs), intsChnk);
                        }
                        break;
                    default:
                        throw new ArgumentOutOfRangeException($"Unknown entry type '{type:X}' for entry '{entryIdx}' in row '{rowIdx}'. Sheet: {Name}");
                }

                if (type != EntryType.Bool) rowOfs += props.Size;
            }
            
            // Flush remaining bits.
            if (bitCounter > 0) BitConverter.TryWriteBytes(rowBuffer.AsSpan(rowOfs), currentBits);
            
            stream.Write(rowBuffer);
        }
    }
    
    public void MergeDiff(SheetDiff diff)
    {
        foreach (var kvp in diff.Cells) Cells[kvp.Key] = kvp.Value;
        foreach (var kvp in diff.ChnkCells) _cellsChnkValues[kvp.Key] = kvp.Value;
    }

    /// <summary>
    /// Appends CSV data to sheet.
    /// </summary>
    /// <param name="csvContent">CSV row string.</param>
    public void AppendCsv(string csvContent)
    {
        var csv = CsvReader.FromText(csvContent);

        var rowIdx = GetNumRows();
        foreach (var row in csv)
        {
            for (var colIdx = 0; colIdx < row.ColCount; colIdx++)
            {
                var col = row[colIdx];
                var cellValueStr = col.ToString();
                var cell = new Cell(rowIdx, colIdx);
                var colType = Entries[colIdx];
                var cellValue = GetCellValueFromString(colType, cellValueStr);
                Cells[cell] = cellValue;

                if (IsColumnChnk(colType))
                    _cellsChnkValues[cell] = GetChnkValue(colType, cellValueStr);
            }

            rowIdx++;
        }
    }

    public record SheetDiff(IReadOnlyDictionary<Cell, long> Cells, IReadOnlyDictionary<Cell, object> ChnkCells);
    
    /// <summary>
    /// Generates a diff of cells and strings compared to <paramref name="other"/>.<br/>
    /// Ideal use case is for diffing against original sheet, then merging into an active sheet.
    /// </summary>
    /// <param name="other">Other sheet to compare to.</param>
    public SheetDiff GenerateDiff(Sheet other)
    {
        var diffCells = other.Cells.Where(x => IsCellDiff(x.Key, x.Value)).ToDictionary();
        var diffStrings = other._cellsChnkValues.Where(x => IsCellChnkDiff(x.Key, x.Value)).ToDictionary();
        return new(diffCells, diffStrings);
    }

    private bool IsCellDiff(Cell otherCell, long value)
    {
        if (!Cells.TryGetValue(otherCell, out var cellValue)) return true;
        return cellValue != value;
    }

    private bool IsCellChnkDiff(Cell otherCell, object otherValue)
    {
        if (!_cellsChnkValues.TryGetValue(otherCell, out var currValue)) return true;
        
        if (currValue is int[] currInts)
        {
            // Local fix: equal arrays are not a diff.
            return !currInts.SequenceEqual((int[])otherValue);
        }
        
        return !currValue.Equals(otherValue);
    }

    /// <summary>
    /// Applies an MBE's Chnk to Cell values.
    /// </summary>
    /// <param name="chnk">MBE Chnk section.</param>
    public void ApplyMbeChnk(Chnk chnk)
    {
        foreach (var kvp in _chnkOffsetToCellMap)
        {
            if (chnk.TryGetChnkItem((int)kvp.Key, out var chnkValue))
            {
                _cellsChnkValues[kvp.Value] = chnkValue;
            }
        }
    }

    private static bool IsColumnChnk(EntryType type) =>
        type is EntryType.String or EntryType.String2 or EntryType.String3 or EntryType.IntArray;

    private static object GetChnkValue(EntryType type, string chnkValueStr)
    {
        if (type == EntryType.IntArray)
        {
            return chnkValueStr
                .Split(' ', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
                .Select(int.Parse)
                .ToArray();
        }

        return chnkValueStr;
    }

    public bool TryGetCellChnkValue(Cell cell, [NotNullWhen(true)] out object? value)
    {
        _cellsChnkValues.TryGetValue(cell, out value);
        return value != null;
    }

    private static long GetCellValueFromString(EntryType type, string valueStr)
    {
        var valueOrZero = ValueOrZero(valueStr);
        return type switch
        {
            EntryType.Int => int.Parse(valueOrZero, CultureInfo.InvariantCulture),
            EntryType.Short => short.Parse(valueOrZero, CultureInfo.InvariantCulture),
            EntryType.Byte => sbyte.Parse(valueOrZero, CultureInfo.InvariantCulture),
            EntryType.Float => Unsafe.BitCast<float, int>((float)Math.Round(float.Parse(valueOrZero, CultureInfo.InvariantCulture), 3)),
            EntryType.String3 or EntryType.String or EntryType.String2 => 0,
            EntryType.Bool => char.IsDigit(valueOrZero.First()) ? valueOrZero == "1" ? 1 : 0 : bool.Parse(valueStr) ? 1 : 0,
            EntryType.Empty => 0,
            _ => throw new ArgumentOutOfRangeException(nameof(type), type, null)
        };
    }

    private int GetNumRows() => Cells.Count > 0 ? Cells.Last().Key.Row + 1 : 0;

    private static string ValueOrZero(string value) => string.IsNullOrEmpty(value) ? "0" : value;

    /// <summary>
    /// Rounds float value to 3 decimal places and returns value reinterpreted as an integer.
    /// </summary>
    private static int RoundedFloatAsInt(float value) => Unsafe.BitCast<float, int>((float)Math.Round(value, 3));

    /// <summary>
    /// Reinterprets int value as a float rounded to 3 decimal places.
    /// </summary>
    private static float RoundedFloatFromInt(int value) => (float)Math.Round(Unsafe.BitCast<int, float>(value), 3);
}
