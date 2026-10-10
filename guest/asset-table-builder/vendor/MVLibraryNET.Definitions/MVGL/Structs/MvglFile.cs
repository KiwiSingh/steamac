namespace MVLibraryNET.Definitions.MVGL.Structs;

/// <summary>
/// Encapsulates all known information about a file in an MVGL.
/// </summary>
public struct MvglFile
{
    /// <summary>
    /// Full file name.
    /// </summary>
    public string FileName { get; init; }

    /// <summary>
    /// Offset of the file inside the MVGL.
    /// </summary>
    public long FileOffset { get; init; }

    /// <summary>
    /// Size of the file in the MVGL.
    /// </summary>
    public int FileSize { get; init; }

    /// <summary>
    /// Size of the file after it's extracted.
    /// </summary>
    public int ExtractSize { get; init; }
}