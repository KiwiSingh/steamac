using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using MVLibraryNET.MBE;
using MVLibraryNET.MVGL;

// Only operates on a guest-validated staging snapshot. Source archives/packages
// are read-only. Publication remains the Rust bridge's checked atomic operation.
static class Program
{
    const int Limit = 64 * 1024 * 1024;
    static string PathIn(string root, string key)
    {
        if (key.Contains('\\') || key.Contains(':') || key.Split('/').Any(x => x is "" or "." or ".."))
            throw new InvalidDataException("Invalid table path");
        var p = Path.GetFullPath(Path.Combine(root, key));
        if (!p.StartsWith(Path.GetFullPath(root) + "/", StringComparison.Ordinal)) throw new InvalidDataException("Table path escaped root");
        return p;
    }
    static byte[] Read(string path)
    {
        var info = new FileInfo(path);
        if (info.LinkTarget != null || info.Length > Limit) throw new InvalidDataException("Invalid or oversized table input");
        return File.ReadAllBytes(path);
    }
    static string SheetName(string key) => Regex.Replace(Path.GetFileName(key).Split('.')[0], @"^[0-9]+_", "");
    static string TablePath(string key)
    {
        var at = key.LastIndexOf('/');
        var table = key[..at];
        if (!table.EndsWith(".mbe", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("CSV requires an MBE parent");
        return table;
    }
    static byte[] Original(string game, string key)
    {
        var slash = key.IndexOf('/');
        if (slash <= 0) throw new InvalidDataException("Missing archive name");
        var archive = PathIn(Path.Combine(game, "gamedata"), key[..slash] + ".dx11.mvgl");
        using var stream = File.OpenRead(archive);
        using (var header = new BinaryReader(stream, System.Text.Encoding.UTF8, true))
        {
            if (header.ReadUInt32() != 0x3142444d) throw new InvalidDataException("Invalid MVGL header");
            var tree = header.ReadUInt32(); var names = header.ReadUInt32(); var entries = header.ReadUInt32();
            if (tree > 300000 || names != tree || entries > tree || 32L + tree * 16L + names * 128L + entries * 24L > stream.Length)
                throw new InvalidDataException("Invalid MVGL directory bounds");
        }
        stream.Position = 0;
        using var reader = new MvglReader(stream, false);
        var files = reader.GetFiles();
        var found = files.Where(f => f.FileName.Replace('\\', '/').Equals(key[(slash + 1)..], StringComparison.OrdinalIgnoreCase)).ToArray();
        if (found.Length != 1) throw new InvalidDataException("Missing or ambiguous original MBE: " + key);
        var file = found[0];
        if (file.ExtractSize <= 0 || file.ExtractSize > Limit || file.FileSize <= 0 || file.FileSize > Limit || file.FileOffset < 0 || file.FileOffset > stream.Length - file.FileSize)
            throw new InvalidDataException("Invalid archive table bounds");
        using var bytes = reader.ExtractFile(file);
        return bytes.Span.ToArray();
    }
    static Mbe Parse(byte[] bytes) => new(new MemoryStream(bytes), true);
    static void SelfTest()
    {
        using var fixture = new MemoryStream(); using var writer = new BinaryWriter(fixture);
        writer.Write(0x41505845); writer.Write(1); writer.WriteStringIncludingLength("rides");
        writer.Write(2); writer.Write((int)EntryType.Int); writer.Write((int)EntryType.Int);
        writer.Write(8); writer.Write(2); fixture.Align(8);
        foreach (var n in new[] { 1, 10, 2, 20 }) writer.Write(n);
        writer.Write(Chnk.Magic); writer.Write(0);
        var original = Parse(fixture.ToArray()); var current = Parse(fixture.ToArray());
        current.Sheets["rides"].MergeDiff(original.Sheets["rides"].GenerateDiff(new Sheet("rides", "Int 1,Int 2\n1,11\n2,20\n")));
        current.Sheets["rides"].MergeDiff(original.Sheets["rides"].GenerateDiff(new Sheet("rides", "Int 1,Int 2\n1,10\n2,22\n")));
        current.Sheets["rides"].MergeDiff(original.Sheets["rides"].GenerateDiff(new Sheet("rides", "Int 1,Int 2\n1,12\n2,20\n")));
        current.Sheets["rides"].AppendCsv("Int 1,Int 2\n3,30\n");
        using var output = new MemoryStream(); current.Write(output);
        var result = Parse(output.ToArray()).Sheets["rides"];
        if (result.Cells[new Cell(0, 1)] != 12 || result.Cells[new Cell(1, 1)] != 22 || result.Cells[new Cell(2, 1)] != 30)
            throw new InvalidDataException("Cell composition/priority/append round trip failed");
        if (SheetName("000_rides.ap.csv") != "rides") throw new InvalidDataException("Append sheet name failed");
        foreach (var key in new[] { "../outside", "/absolute", "x/../outside", "C:/outside" })
        {
            bool rejected = false; try { PathIn("/fixture", key); } catch (InvalidDataException) { rejected = true; }
            if (!rejected) throw new InvalidDataException("Containment test failed");
        }
        Console.WriteLine("PASS: cell composition, priority, append, binary round trip, sheet names and containment");
    }
    static int Main(string[] args)
    {
        try
        {
            if (args.SequenceEqual(new[] { "--self-test" })) { SelfTest(); return 0; }
            if (args.Length != 2) throw new InvalidDataException("Expected game and checked staging paths");
            var game = args[0]; var stage = args[1]; var assets = Path.Combine(stage, "assets");
            var profile = JsonNode.Parse(Read(Path.Combine(stage, "profile.json")))!;
            var manifest = JsonNode.Parse(Read(Path.Combine(stage, "manifest.json")))!;
            var hashes = manifest["files"]!.AsObject();
            var edits = new Dictionary<string, List<(string key, string text)>>(StringComparer.OrdinalIgnoreCase);
            foreach (var mod in profile["mods"]!.AsArray())
            {
                if (!mod!["enabled"]!.GetValue<bool>()) continue;
                var root = mod["root"]!.GetValue<string>();
                var source = JsonNode.Parse(Read(Path.Combine(Path.GetDirectoryName(root)!, "manifest.json")))!;
                foreach (var (key, hash) in source["files"]!.AsObject())
                {
                    if (!key.EndsWith(".csv", StringComparison.OrdinalIgnoreCase)) continue;
                    var data = Read(PathIn(root, key));
                    if (Convert.ToHexStringLower(SHA256.HashData(data)) != hash!.GetValue<string>()) throw new InvalidDataException("CSV changed during compilation");
                    var table = TablePath(key);
                    if (!edits.TryGetValue(table, out var list)) edits[table] = list = [];
                    list.Add((key, new System.Text.UTF8Encoding(false, true).GetString(data).TrimStart('\uFEFF')));
                }
            }
            foreach (var key in hashes.Select(x => x.Key).Where(x => x.EndsWith(".csv", StringComparison.OrdinalIgnoreCase)).ToArray())
            {
                File.Delete(PathIn(assets, key)); hashes.Remove(key);
            }
            foreach (var directory in Directory.GetDirectories(assets, "*", SearchOption.AllDirectories).OrderByDescending(x => x.Length))
                if (!Directory.EnumerateFileSystemEntries(directory).Any()) Directory.Delete(directory);
            foreach (var (table, list) in edits)
            {
                if (hashes.Any(x => x.Key.Equals(table, StringComparison.OrdinalIgnoreCase)))
                    throw new InvalidDataException("Whole MBE replacement and CSV edits target the same table: " + table);
                var originalBytes = Original(game, table);
                var original = Parse(originalBytes); var current = Parse(originalBytes);
                foreach (var (key, text) in list.Where(x => !x.key.EndsWith(".ap.csv", StringComparison.OrdinalIgnoreCase)))
                {
                    var name = SheetName(key);
                    if (!original.Sheets.TryGetValue(name, out var sheet)) throw new InvalidDataException("Unknown MBE sheet: " + key);
                    current.Sheets[name].MergeDiff(sheet.GenerateDiff(new Sheet(name, text)));
                }
                foreach (var (key, text) in list.Where(x => x.key.EndsWith(".ap.csv", StringComparison.OrdinalIgnoreCase)))
                {
                    if (!current.Sheets.TryGetValue(SheetName(key), out var sheet)) throw new InvalidDataException("Unknown append sheet: " + key);
                    sheet.AppendCsv(text);
                }
                using var output = new MemoryStream(); current.Write(output);
                if (output.Length > Limit) throw new InvalidDataException("Compiled MBE exceeds limit");
                var bytes = output.ToArray();
                var checkedMbe = Parse(bytes);
                if (current.Sheets.Count != checkedMbe.Sheets.Count || current.Sheets.Any(x => !checkedMbe.Sheets.TryGetValue(x.Key, out var sheet) || x.Value.ToCsv() != sheet.ToCsv()))
                    throw new InvalidDataException("Compiled table round trip changed cells");
                var destination = PathIn(assets, table); Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                using (var file = new FileStream(destination, FileMode.CreateNew)) file.Write(bytes);
                hashes[table] = Convert.ToHexStringLower(SHA256.HashData(bytes));
            }
            File.WriteAllText(Path.Combine(stage, "manifest.json"), manifest.ToJsonString());
            Console.WriteLine($"Compiled {edits.Count} MBE tables"); return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
    }
}
