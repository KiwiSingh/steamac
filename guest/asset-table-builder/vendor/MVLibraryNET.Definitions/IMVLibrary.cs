using MVLibraryNET.Definitions.MVGL;

namespace MVLibraryNET.Definitions;

// ReSharper disable once InconsistentNaming
/// <summary>
/// MVLibrary interface.
/// </summary>
public interface IMVLibrary
{
    /// <summary>
    /// Creates a reader that can used to read a MVGL file.
    /// </summary>
    /// <param name="mvglStream">Stream which starts at the beginning of a MVGL file.</param>
    /// <param name="ownsStream">True to dispose the stream alongside the reader, else false.</param>
    /// <param name="config">MVGL reader config.</param>
    /// <returns>Reader which can be used to read a CPK file.</returns>
    IMvglReader CreateMvglReader(Stream mvglStream, bool ownsStream, MvglReaderConfig? config = null);
}