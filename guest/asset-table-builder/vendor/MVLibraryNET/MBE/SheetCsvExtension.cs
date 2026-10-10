using System.Globalization;
using System.Runtime.CompilerServices;
using nietras.SeparatedValues;

namespace MVLibraryNET.MBE;

public static class SheetCsvExtension
{
    private static readonly SepWriterOptions CsvWriter = Sep.Writer(_ => new() { Escape =  true, Sep = new(',')});
    
    public static string ToCsv(this Sheet sheet)
    {
        using var writer = CsvWriter.ToText();
        var header = sheet.Entries.Select((x, idx) => $"{x} {idx + 1}").ToArray();

        var row = writer.NewRow();
        var rowIdx = 0;
        foreach (var kvp in sheet.Cells)
        {
            var cell = kvp.Key;
            var value = kvp.Value;
            
            // Entered new row.
            if (cell.Row != rowIdx)
            {
                row.Dispose();
                row = writer.NewRow();
                rowIdx = cell.Row;
            }
            
            var colCode = sheet.Entries[cell.Column];
            switch (colCode)
            {
                case EntryType.Bool:
                    row[header[cell.Column]].Set(value == 0 ? "false" : "true");
                    break;
                case EntryType.Int:
                case EntryType.Short:
                case EntryType.Byte:
                    row[header[cell.Column]].Set(value.ToString());
                    break;
                case EntryType.Float:
                    var fValue = (float)Math.Round(Unsafe.BitCast<int, float>((int)value), 3);
                    row[header[cell.Column]].Set(fValue.ToString(CultureInfo.InvariantCulture));
                    break;
                case EntryType.String:
                case EntryType.String2:
                case EntryType.String3:
                case EntryType.Empty:
                case EntryType.IntArray:
                    if (sheet.TryGetCellChnkValue(cell, out var chnkValue))
                    {
                        row[header[cell.Column]].Set(GetChnkValueStr(chnkValue));
                    }
                    else
                    {
                        row[header[cell.Column]].Set(string.Empty);
                    }
                    break;
                default:
                    throw new ArgumentOutOfRangeException();
            }
        }

        row.Dispose();
        return writer.ToString();
    }

    private static string GetChnkValueStr(object chnkValue)
    {
        if (chnkValue is int[] ints) return string.Join(' ', ints.Select(x => x.ToString()));
        return chnkValue.ToString() ?? string.Empty;
    }
}