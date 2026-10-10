using MVLibraryNET.Definitions.MVGL.Structs;
using MVLibraryNET.Definitions.Utilities;

namespace MVLibraryNET.Definitions.MVGL;

/// <summary>
/// API for MVGL reader.
/// </summary>
public interface IMvglReader : IDisposable, IAsyncDisposable
{
    /// <summary>
    /// Gets all the file data info within a MVGL file from a stream.
    /// </summary>
    MvglFile[] GetFiles();

    /// <summary>
    /// Extracts and decompresses the file from the MVGL.
    /// </summary>
    /// <param name="file">Path of file to extract.</param>
    /// <returns>Extracted data.</returns>
    ArrayRental ExtractFile(in MvglFile file);

    /// <summary>
    /// Extracts the file from the MVGL without decompressing.
    /// </summary>
    /// <param name="file">Path of file to extract.</param>
    /// <returns>Extracted data.</returns>
    ArrayRental ExtractFileNoDecompression(in MvglFile file);
}