using MVLibraryNET.Definitions.MVGL;
using MVLibraryNET.Definitions.MVGL.Structs;
using MVLibraryNET.Definitions.Utilities;

namespace MVLibraryNET.MVGL;

public class MvglReader(Stream stream, bool ownsStream, MvglReaderConfig? config = null) : IMvglReader
{
    private readonly long _initialStreamPosition = stream.Position;

    public MvglFile[] GetFiles()
    {
        stream.Position = _initialStreamPosition;
        return MvglHelper.GetFilesFromStream(stream, config?.FileNameNormalizer);
    }

    public ArrayRental ExtractFile(in MvglFile file)
    {
        stream.Position = _initialStreamPosition;
        return MvglHelper.ExtractFile(file, stream);
    }
    
    public ArrayRental ExtractFileNoDecompression(in MvglFile file)
    {
        stream.Position = _initialStreamPosition;
        return MvglHelper.ExtractFileNoDecompression(file, stream);
    }

    public void Dispose()
    {
        GC.SuppressFinalize(this);
        if (ownsStream)
            stream.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        GC.SuppressFinalize(this);
        if (ownsStream)
            await stream.DisposeAsync();
    }
}