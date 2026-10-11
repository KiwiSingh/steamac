using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using SonicAudioLib.CriMw;

// Independently authored bank composition. Uses MIT SonicAudioLib only for UTF
// serialization; does not contain or require Ryo/Reloaded runtime code.
static class AudioBanks
{
    const int Limit = 64 * 1024 * 1024;
    public const string Prefix = "Ryo/Digimon Story Time Stranger/bgm/";
    public static bool IsInput(string key) => key.StartsWith(Prefix, StringComparison.Ordinal);
    static ushort U16(byte[] b, int p) => BinaryPrimitives.ReadUInt16BigEndian(b.AsSpan(p, 2));
    static uint U32(byte[] b, int p) => BinaryPrimitives.ReadUInt32BigEndian(b.AsSpan(p, 4));
    static void Put16(Stream s, int n) { Span<byte> b = stackalloc byte[2]; BinaryPrimitives.WriteUInt16BigEndian(b, checked((ushort)n)); s.Write(b); }
    static CriTable Table(byte[] b)
    {
        if (b.Length < 32 || !b.AsSpan(0,4).SequenceEqual("@UTF"u8) || U32(b,4) > b.Length - 8 || U32(b,28) > 100000)
            throw new InvalidDataException("Invalid UTF audio table");
        // DSTS rejects otherwise equivalent banks serialized with the library's
        // default byte alignment. Root and rebuilt child tables need ADX2 layout.
        var t = new CriTable { WriterSettings=CriTableWriterSettings.Adx2Settings }; t.Load(b); return t;
    }
    static CriTable Child(CriTable t, string name) => Table((byte[])t.Rows[0][name]);
    static uint Number(CriRow r, string key) => Convert.ToUInt32(r[key], CultureInfo.InvariantCulture);
    static CriRow Clone(CriTable table, CriRow source)
    {
        var row=table.NewRow(); foreach(var f in table.Fields) row[f.FieldName]=source[f.FieldName]; table.Rows.Add(row); return row;
    }
    static void Set(CriRow row, string key, object value)
    {
        var field=row.Parent.Fields[key] ?? throw new InvalidDataException("Missing ACB field: "+key);
        row[key]=Convert.ChangeType(value,field.FieldType,CultureInfo.InvariantCulture);
    }
    static byte[] Section(Stream stream, long offset, string magic)
    {
        stream.Position=offset; Span<byte> header=stackalloc byte[16];stream.ReadExactly(header);
        var length=BinaryPrimitives.ReadUInt64LittleEndian(header[8..]);
        if (!header[..4].SequenceEqual(Encoding.ASCII.GetBytes(magic)) || length>Limit || offset<0 || offset>stream.Length-16-(long)length)
            throw new InvalidDataException("Invalid CPK audio directory");
        var b=new byte[(int)length];stream.ReadExactly(b);return b;
    }
    public static byte[] Original(string game,string bank)
    {
        // Later patch archives override the base archive. Only a uniquely named
        // BGM bank, stored uncompressed, can be used as the trusted template.
        foreach(var archive in new[]{"patch","app_0"})
        {
            using var stream=File.OpenRead(Path.Combine(game,"gamedata",archive+".dx11.cpk"));
            var header=Table(Section(stream,0,"CPK ")).Rows[0];
            var tocOffset=checked((long)Convert.ToUInt64(header["TocOffset"]));
            var contentOffset=checked((long)Convert.ToUInt64(header["ContentOffset"]));
            var toc=Table(Section(stream,tocOffset,"TOC "));
            var found=toc.Rows.Cast<CriRow>().Where(r=>string.Equals((string)r["FileName"],bank,StringComparison.OrdinalIgnoreCase) && string.Equals((string)r["DirName"],"bgm",StringComparison.OrdinalIgnoreCase)).ToArray();
            if(found.Length==0)continue;
            if(found.Length!=1)throw new InvalidDataException("Ambiguous original music bank");
            var row=found[0];var size=Number(row,"FileSize");
            var offset=checked((long)Convert.ToUInt64(row["FileOffset"])+Math.Min(tocOffset,contentOffset));
            if(size!=Number(row,"ExtractSize") || size<32 || size>Limit || offset<0 || offset>stream.Length-size)
                throw new InvalidDataException("Unsupported compressed or oversized music bank");
            stream.Position=offset;var bytes=new byte[(int)size];stream.ReadExactly(bytes);return bytes;
        }
        throw new InvalidDataException("Original BGM bank missing: "+bank);
    }
    record Hca(byte[] Bytes,int Channels,uint Rate,uint Samples,bool Loop);
    static Hca ParseHca(byte[] bytes)
    {
        if(bytes.Length<32 || !bytes.AsSpan(0,4).SequenceEqual("HCA\0"u8))throw new InvalidDataException("Unsupported HCA header");
        int header=U16(bytes,6);if(header<32 || header>bytes.Length)throw new InvalidDataException("Truncated HCA header");
        if(!bytes.AsSpan(8,4).SequenceEqual("fmt\0"u8))throw new InvalidDataException("Missing HCA format");
        int channels=bytes[12];uint rate=U32(bytes,12)&0xffffff;uint blocks=U32(bytes,16);
        uint samples=checked(blocks*1024-U16(bytes,20)-U16(bytes,22));
        if(channels<1 || channels>8 || rate<8000 || rate>192000 || samples==0)throw new InvalidDataException("Invalid HCA audio format");
        bool loop=false; int pos=24,blockSize=0;
        while(pos+4<=header)
        {
            var tag=Encoding.ASCII.GetString(bytes,pos,4);
            if(tag=="pad\0")break;
            int length=tag switch {"comp"=>16,"dec\0"=>12,"vbr\0"=>8,"ath\0"=>6,"loop"=>16,"ciph"=>6,"rva\0"=>8,_=>throw new InvalidDataException("Unsupported HCA chunk: "+tag)};
            if(pos+length>header)throw new InvalidDataException("Truncated HCA chunk");
            if(tag is "comp" or "dec\0")blockSize=U16(bytes,pos+4);
            if(tag=="ciph" && U16(bytes,pos+4)!=0)throw new InvalidDataException("Encrypted HCA input is unsupported");
            if(tag=="loop") {loop=true;if(U32(bytes,pos+4)>=blocks || U32(bytes,pos+8)>=blocks)throw new InvalidDataException("Invalid HCA loop points");}
            pos+=length;
        }
        if(blockSize==0 || (long)header+(long)blocks*blockSize!=bytes.Length)throw new InvalidDataException("Truncated HCA frames");
        return new(bytes,channels,rate,samples,loop);
    }
    static byte[] Awb(IReadOnlyList<Hca> tracks)
    {
        using var s=new MemoryStream();using var w=new BinaryWriter(s);
        w.Write("AFS2"u8);w.Write((uint)0x00020401);w.Write(tracks.Count);w.Write((ushort)32);w.Write((ushort)0);
        for(int i=0;i<tracks.Count;i++)w.Write((ushort)i);
        int offsets=(int)s.Position;for(int i=0;i<=tracks.Count;i++)w.Write((uint)0);
        var positions=new List<uint>();
        foreach(var track in tracks){positions.Add((uint)s.Position);while(s.Position%32!=0)w.Write((byte)0);w.Write(track.Bytes);}
        positions.Add((uint)s.Position);s.Position=offsets;foreach(var p in positions)w.Write(p);return s.ToArray();
    }
    static CriTable FixtureTable(string name,params (string key,object value)[] fields)
    {
        var t=new CriTable{TableName=name,WriterSettings=CriTableWriterSettings.Adx2Settings};foreach(var (key,value) in fields)t.Fields.Add(key,value.GetType());
        var row=t.NewRow();foreach(var (key,value) in fields)row[key]=value;t.Rows.Add(row);return t;
    }
    public static void SelfTest()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var wave=FixtureTable("Waveform",("MemoryAwbId",(ushort)0),("EncodeType",(byte)2),("Streaming",(byte)0),("NumChannels",(byte)2),("SamplingRate",48000u),("NumSamples",1024u),("LoopFlag",(byte)0),("ExtensionData",(ushort)0));
        var syn=FixtureTable("Synth",("Type",(byte)0),("CommandIndex",(ushort)65535),("ReferenceItems",new byte[]{0,1,0,0}));
        var seq=FixtureTable("Sequence",("TrackIndex",new byte[]{0,0}),("NumTracks",(ushort)1),("Type",(byte)0),("TrackValues",Array.Empty<byte>()));
        var track=FixtureTable("Track",("EventIndex",(ushort)0));var evt=FixtureTable("TrackEvent",("Command",new byte[]{7,208,4,0,2,0,0,0,0,0}));
        var cue=FixtureTable("Cue",("CueId",0u),("ReferenceType",(byte)3),("ReferenceIndex",(ushort)0),("NumRelatedWaveforms",(ushort)1));
        var names=FixtureTable("CueName",("CueName","test"),("CueIndex",(ushort)0));
        var acb=FixtureTable("Header",("Name","test"),("CueTable",cue.Save()),("CueNameTable",names.Save()),("WaveformTable",wave.Save()),("SynthTable",syn.Save()),("SequenceTable",seq.Save()),("TrackTable",track.Save()),("TrackEventTable",evt.Save()),("SynthCommandTable",Array.Empty<byte>()),("AwbFile",Array.Empty<byte>()),("WaveformExtensionDataTable",Array.Empty<byte>()));
        byte[] hca=new byte[96];"HCA\0"u8.CopyTo(hca);hca[4]=2;hca[7]=64;"fmt\0"u8.CopyTo(hca.AsSpan(8));hca[12]=2;hca[14]=0xbb;hca[15]=0x80;hca[19]=1;"comp"u8.CopyTo(hca.AsSpan(24));hca[29]=32;"ciph"u8.CopyTo(hca.AsSpan(40));"pad\0"u8.CopyTo(hca.AsSpan(46));
        var bytes=Build(acb.Save(),"test",new[]{(hca,0.3f),(hca,0.5f)});var result=Table(bytes);
        foreach(var tableBytes in new[]{bytes}.Concat(new[]{"CueTable","WaveformTable","SynthTable","SequenceTable","TrackTable","TrackEventTable","SynthCommandTable"}.Select(k=>(byte[])result.Rows[0][k])))
            if((U32(tableBytes,16)+8)%32!=0 || tableBytes.Length%32!=0)throw new InvalidDataException("ADX2 table alignment failed");
        if(Number(Child(result,"SequenceTable").Rows[0],"Type")!=3 || Number(Child(result,"WaveformTable").Rows[1],"MemoryAwbId")!=1)throw new InvalidDataException("Random music composition failed");
        var settings=(byte[])Child(result,"SynthCommandTable").Rows[0]["Command"];
        if(((byte[])Child(result,"SequenceTable").Rows[0]["TrackValues"]).Length!=4 || settings[4]!=30)throw new InvalidDataException("Music volume failed");
        void Reject(Action test){try{test();}catch(InvalidDataException){return;}throw new InvalidDataException("Invalid music input accepted");}
        Reject(()=>Build(acb.Save(),"missing",new[]{(hca,1f)}));
        Reject(()=>Build(acb.Save(),"test",new[]{(hca[..80],1f)}));
        Reject(()=>Build(acb.Save(),"test",new[]{(hca,float.NaN)}));
        var encrypted=(byte[])hca.Clone();encrypted[45]=56;Reject(()=>ParseHca(encrypted));
        Reject(()=>Volume("volume: 0.3\nunknown: true"u8.ToArray()));
        Console.WriteLine("PASS: music cue mapping, random sequence, embedded bank, volume, round trip, encrypted/truncated input rejection");
    }
    static float Volume(byte[] bytes)
    {
        var text=new UTF8Encoding(false,true).GetString(bytes).TrimStart('\uFEFF');float volume=1;
        bool found=false;
        foreach(var raw in text.Split('\n')) {
            var line=raw.Split('#')[0].Trim();if(line.Length==0)continue;
            var parts=line.Split(':');
            if(parts.Length!=2 || parts[0].Trim()!="volume" || found || !float.TryParse(parts[1].Trim(),NumberStyles.Float,CultureInfo.InvariantCulture,out volume) || !float.IsFinite(volume) || volume<0 || volume>10)
                throw new InvalidDataException("Unsupported music YAML setting; only volume is supported");
            found=true;
        }
        return volume;
    }
    public static int Compile(string game,string assets,JsonObject hashes,Func<string,byte[]> read,Func<string,string,string> pathIn)
    {
        var keys=hashes.Select(x=>x.Key).Where(IsInput).ToArray();
        var groups=new Dictionary<(string bank,string cue),List<string>>();
        foreach(var key in keys) {
            if(Path.GetFileName(key)==".DS_Store")continue;
            var parts=key[Prefix.Length..].Split('/');
            if(parts.Length!=3 || !parts[0].EndsWith(".acb",StringComparison.Ordinal) || !parts[1].EndsWith(".cue",StringComparison.Ordinal) || !(parts[2].EndsWith(".hca",StringComparison.OrdinalIgnoreCase) || parts[2].EndsWith(".yaml",StringComparison.OrdinalIgnoreCase)))
                throw new InvalidDataException("Unsupported music package layout: "+key);
            if(!parts[2].EndsWith(".hca",StringComparison.OrdinalIgnoreCase)) {
                if(!hashes.ContainsKey(key[..^5]+".hca") && !hashes.ContainsKey(key[..^5]))throw new InvalidDataException("Music YAML has no matching HCA track");
                continue;
            }
            var group=(parts[0],parts[1][..^4]);if(!groups.TryGetValue(group,out var list))groups[group]=list=[];list.Add(key);
        }
        if(groups.Count==0 && keys.Length>0)throw new InvalidDataException("Music package contains no HCA tracks");
        foreach(var (group,list) in groups) {
            var original=Original(game,group.bank);
            var target="_bepis_audio/"+Convert.ToHexStringLower(SHA256.HashData(original))+".acb";
            if(hashes.ContainsKey(target))throw new InvalidDataException("Conflicting compiled music bank");
            var tracks=new List<(byte[] bytes,float volume)>();
            foreach(var key in list.Order(StringComparer.Ordinal)) {
                var bytes=read(pathIn(assets,key));if(Convert.ToHexStringLower(SHA256.HashData(bytes))!=hashes[key]!.GetValue<string>())throw new InvalidDataException("Music track changed during compilation");
                var shortYaml=key[..^4]+".yaml";var fullYaml=key+".yaml";
                if(hashes.ContainsKey(shortYaml) && hashes.ContainsKey(fullYaml))throw new InvalidDataException("Conflicting music volume files");
                var yaml=hashes.ContainsKey(fullYaml)?fullYaml:shortYaml;float volume=1;
                if(hashes.ContainsKey(yaml)) {
                    var settings=read(pathIn(assets,yaml));if(Convert.ToHexStringLower(SHA256.HashData(settings))!=hashes[yaml]!.GetValue<string>())throw new InvalidDataException("Music setting changed during compilation");volume=Volume(settings);
                }
                tracks.Add((bytes,volume));
            }
            var compiled=Build(original,group.cue,tracks);var destination=pathIn(assets,target);Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            using(var file=new FileStream(destination,FileMode.CreateNew))file.Write(compiled);
            hashes[target]=Convert.ToHexStringLower(SHA256.HashData(compiled));
        }
        foreach(var key in keys){File.Delete(pathIn(assets,key));hashes.Remove(key);}
        return groups.Count;
    }
    public static byte[] Build(byte[] original,string cueName,IReadOnlyList<(byte[] bytes,float volume)> inputs)
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        if(inputs.Count==0 || inputs.Count>64)throw new InvalidDataException("Music cue requires 1–64 tracks");
        var acb=Table(original);var cue=Child(acb,"CueTable");var names=Child(acb,"CueNameTable");
        var matches=names.Rows.Cast<CriRow>().Where(r=>(string)r["CueName"]==cueName).ToArray();
        if(matches.Length!=1 || cue.Rows.Count!=1 || Number(matches[0],"CueIndex")!=0 || Number(cue.Rows[0],"ReferenceType")!=3 || Number(cue.Rows[0],"ReferenceIndex")!=0)
            throw new InvalidDataException("Unsupported multi-cue or non-sequence music bank");
        var sequence=Child(acb,"SequenceTable");var track=Child(acb,"TrackTable");var events=Child(acb,"TrackEventTable");var synth=Child(acb,"SynthTable");var wave=Child(acb,"WaveformTable");
        if(sequence.Rows.Count!=1 || track.Rows.Count!=1 || events.Rows.Count!=1 || synth.Rows.Count!=1 || wave.Rows.Count!=1 || Number(wave.Rows[0],"Streaming")!=0)
            throw new InvalidDataException("Unsupported complex or streamed music bank");
        var waveTemplate=wave.Rows[0];var synthTemplate=synth.Rows[0];var trackTemplate=track.Rows[0];var eventTemplate=events.Rows[0];
        wave.Rows.Clear();synth.Rows.Clear();track.Rows.Clear();events.Rows.Clear();
        var commands=new CriTable {TableName="SynthCommand",WriterSettings=CriTableWriterSettings.Adx2Settings};commands.Fields.Add("Command",typeof(byte[]));
        var tracks=new List<Hca>();using var indices=new MemoryStream();
        for(int i=0;i<inputs.Count;i++)
        {
            var (bytes,volume)=inputs[i];if(!float.IsFinite(volume) || volume<0 || volume>10)throw new InvalidDataException("Invalid music volume");
            var hca=ParseHca(bytes);tracks.Add(hca);
            var row=Clone(wave,waveTemplate);Set(row,"MemoryAwbId",i);Set(row,"NumChannels",hca.Channels);Set(row,"SamplingRate",hca.Rate);Set(row,"NumSamples",hca.Samples);Set(row,"LoopFlag",hca.Loop?2:0);Set(row,"ExtensionData",ushort.MaxValue);
            var syn=Clone(synth,synthTemplate);syn["ReferenceItems"]=new byte[]{0,1,(byte)(i>>8),(byte)i};Set(syn,"CommandIndex",i);
            // CRI volume command: base volume percentage with zero random range.
            var command=commands.NewRow();command["Command"]=new byte[]{0,0x59,4,(byte)((int)Math.Round(volume*100)>>8),(byte)(int)Math.Round(volume*100),0,0,0,0,0};commands.Rows.Add(command);
            var tr=Clone(track,trackTemplate);Set(tr,"EventIndex",i);
            var ev=Clone(events,eventTemplate);ev["Command"]=new byte[]{7,0xd0,4,0,2,(byte)(i>>8),(byte)i,0,0,0};Put16(indices,i);
        }
        using var weights=new MemoryStream();
        for(int i=0;i<tracks.Count;i++)Put16(weights,100/tracks.Count+(i<100%tracks.Count?1:0));
        sequence.Rows[0]["TrackValues"]=tracks.Count==1?Array.Empty<byte>():weights.ToArray();
        sequence.Rows[0]["TrackIndex"]=indices.ToArray();Set(sequence.Rows[0],"NumTracks",tracks.Count);Set(sequence.Rows[0],"Type",tracks.Count==1?0:3);
        Set(cue.Rows[0],"NumRelatedWaveforms",tracks.Count);
        foreach(var (name,table) in new[]{("CueTable",cue),("WaveformTable",wave),("SynthTable",synth),("SequenceTable",sequence),("TrackTable",track),("TrackEventTable",events),("SynthCommandTable",commands)})acb.Rows[0][name]=table.Save();
        acb.Rows[0]["AwbFile"]=Awb(tracks);acb.Rows[0]["WaveformExtensionDataTable"]=Array.Empty<byte>();
        var result=acb.Save();if(result.Length>Limit)throw new InvalidDataException("Compiled music bank exceeds limit");
        var round=Table(result);if(Child(round,"WaveformTable").Rows.Count!=tracks.Count || Number(Child(round,"SequenceTable").Rows[0],"NumTracks")!=tracks.Count)throw new InvalidDataException("Audio bank round trip failed");
        return result;
    }
    public static void DiagnosticFixtures(byte[] original, byte[] track, string directory)
    {
        // Private test fixtures: no randomness, volume commands or cue changes.
        // Never invoked by checked profile compilation.
        Directory.CreateDirectory(directory);
        File.WriteAllBytes(Path.Combine(directory,"original.acb"),original);
        var unaligned=Table(original);unaligned.WriterSettings=new CriTableWriterSettings();var roundtrip=unaligned.Save();
        File.WriteAllBytes(Path.Combine(directory,"roundtrip.acb"),roundtrip);
        var aligned=Table(original);aligned.WriterSettings=CriTableWriterSettings.Adx2Settings;
        File.WriteAllBytes(Path.Combine(directory,"roundtrip-aligned.acb"),aligned.Save());
        var acb=Table(original);var wave=Child(acb,"WaveformTable");
        if(wave.Rows.Count!=1 || Number(wave.Rows[0],"Streaming")!=0 || Number(wave.Rows[0],"MemoryAwbId")!=0)
            throw new InvalidDataException("Single-track diagnostic requires one embedded waveform");
        var hca=ParseHca(track);var row=wave.Rows[0];
        Set(row,"NumChannels",hca.Channels);Set(row,"SamplingRate",hca.Rate);Set(row,"NumSamples",hca.Samples);
        // Use a nonlooping fixture first to exclude the loop-extension format.
        Set(row,"LoopFlag",0);Set(row,"ExtensionData",ushort.MaxValue);
        acb.Rows[0]["WaveformTable"]=wave.Save();
        acb.Rows[0]["WaveformExtensionDataTable"]=Array.Empty<byte>();
        acb.Rows[0]["AwbFile"]=Awb(new[]{hca});
        var single=acb.Save();if(single.Length>Limit)throw new InvalidDataException("Diagnostic bank exceeds limit");
        File.WriteAllBytes(Path.Combine(directory,"single.acb"),single);
        Console.WriteLine("Prepared unchanged, serialization-only and single-track/no-volume/no-randomness fixtures");
    }
}
