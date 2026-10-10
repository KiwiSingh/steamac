namespace MVLibraryNET.Definitions.MVGL;

/// <summary>
/// MVGL reader config.
/// </summary>
public class MvglReaderConfig
{
    /// <summary>
    /// Function to normalize MVGL file names with.
    /// </summary>
    public Func<string, string>? FileNameNormalizer { get; init; }
}