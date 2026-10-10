using MVLibraryNET.Definitions;
using MVLibraryNET.Definitions.MVGL;
using MVLibraryNET.MVGL;

namespace MVLibraryNET;

// ReSharper disable once InconsistentNaming
public class MVLibrary : IMVLibrary
{
    public static readonly IMVLibrary Instance = new MVLibrary();
    
    public IMvglReader CreateMvglReader(Stream mvglStream, bool ownsStream, MvglReaderConfig? config = null) =>
        new MvglReader(mvglStream, ownsStream, config);
}