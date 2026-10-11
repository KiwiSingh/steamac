using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

// Reuse only a verified output from the previous checked published snapshot.
// Recipes include compiler bytes, original game bytes and ordered mod inputs.
static class CompiledReuse
{
    static JsonObject previous = new(), previousHashes = new(), next = new();
    static string? previousRoot;
    static string compiler = "";
    public static void Initialize(string game, string stage, JsonNode profile)
    {
        previous = new(); previousHashes = new(); next = new(); previousRoot = null;
        using (var stream = File.OpenRead(Environment.ProcessPath!)) compiler = Convert.ToHexStringLower(SHA256.HashData(stream));
        var root = profile["baseRoot"]!.GetValue<string>();
        if (root.Length == 0) return;
        var bundle = Path.GetDirectoryName(root)!;
        if (Path.GetDirectoryName(bundle) != Path.GetFullPath(game) || !Path.GetFileName(bundle).StartsWith(".bepis-asset-mod-", StringComparison.Ordinal) || Path.GetFileName(root) != "assets")
            throw new InvalidDataException("Invalid compiled reuse root");
        var receipt = Path.Combine(bundle, "compiled.json");
        if (!File.Exists(receipt)) return;
        previous = JsonNode.Parse(CheckedRead(receipt, 1024 * 1024))!.AsObject();
        previousHashes = JsonNode.Parse(CheckedRead(Path.Combine(bundle, "manifest.json"), 1024 * 1024))!["files"]!.AsObject();
        previousRoot = root;
    }
    static byte[] CheckedRead(string path, int limit)
    {
        var info = new FileInfo(path);
        if (info.LinkTarget != null || info.Length > limit) throw new InvalidDataException("Invalid compiled reuse file");
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length > limit) throw new InvalidDataException("Compiled reuse file grew");
        return bytes;
    }
    public static string Recipe(IEnumerable<string> inputs)
    {
        using var stream = new MemoryStream(); using var writer = new BinaryWriter(stream, Encoding.UTF8, true);
        writer.Write("bepis-compiled-recipe-1"); writer.Write(compiler);
        foreach (var input in inputs) writer.Write(input);
        writer.Flush(); return Convert.ToHexStringLower(SHA256.HashData(stream.ToArray()));
    }
    public static byte[] Output(string target, string recipe, Func<byte[]> build)
    {
        byte[] bytes;
        if (previousRoot != null && previous[target] is JsonObject entry && entry["recipe"]?.GetValue<string>() == recipe)
        {
            var hash = entry["hash"]!.GetValue<string>();
            if (previousHashes[target]?.GetValue<string>() != hash) throw new InvalidDataException("Compiled reuse receipt mismatch");
            bytes = CheckedRead(Path.Combine(previousRoot, target), 128 * 1024 * 1024);
            if (Convert.ToHexStringLower(SHA256.HashData(bytes)) != hash) throw new InvalidDataException("Compiled reuse output changed");
            Console.WriteLine("Reused compiled output: " + target);
        }
        else bytes = build();
        next[target] = new JsonObject { ["recipe"] = recipe, ["hash"] = Convert.ToHexStringLower(SHA256.HashData(bytes)) };
        return bytes;
    }
    public static void SelfTest()
    {
        var game = Path.Combine(Path.GetTempPath(), "bepis-reuse-" + Guid.NewGuid());
        var bundle = Path.Combine(game, ".bepis-asset-mod-a"); var root = Path.Combine(bundle, "assets");
        var stage = Path.Combine(game, "stage"); Directory.CreateDirectory(root); Directory.CreateDirectory(stage);
        try {
            Initialize(game, stage, new JsonObject { ["baseRoot"] = "" });
            var key = Recipe(new[] { "original", "first", "second" });
            if (key == Recipe(new[] { "original", "second", "first" }) || key == Recipe(new[] { "changed", "first", "second" })) throw new InvalidDataException("Recipe invalidation failed");
            var bytes = Output("table.mbe", key, () => new byte[] { 1, 2, 3 });
            File.WriteAllBytes(Path.Combine(root, "table.mbe"), bytes); Save(bundle);
            File.WriteAllText(Path.Combine(bundle, "manifest.json"), new JsonObject { ["files"] = new JsonObject { ["table.mbe"] = Convert.ToHexStringLower(SHA256.HashData(bytes)) } }.ToJsonString());
            Initialize(game, stage, new JsonObject { ["baseRoot"] = root });
            if (!Output("table.mbe", key, () => throw new InvalidDataException("Cache hit compiled again")).SequenceEqual(bytes)) throw new InvalidDataException("Reuse changed output");
            if (!Output("table.mbe", Recipe(new[] { "changed" }), () => new byte[] { 4 }).SequenceEqual(new byte[] { 4 })) throw new InvalidDataException("Changed input was reused");
            File.WriteAllBytes(Path.Combine(root, "table.mbe"), new byte[] { 9 });
            bool rejected = false; try { Output("table.mbe", key, () => bytes); } catch (InvalidDataException) { rejected = true; }
            if (!rejected) throw new InvalidDataException("Tampered cache accepted");
            Console.WriteLine("PASS: compiled reuse avoids rebuild, invalidates original/input/order changes and rejects tampered output");
        } finally { Directory.Delete(game, true); }
    }
    public static void Save(string stage) => File.WriteAllText(Path.Combine(stage, "compiled.json"), next.ToJsonString());
}
