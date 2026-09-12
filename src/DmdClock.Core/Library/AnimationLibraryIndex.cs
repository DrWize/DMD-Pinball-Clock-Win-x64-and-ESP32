namespace DmdClock.Core.Library;

public sealed record AnimationLibraryIndex(
    int SchemaVersion,
    string RootPath,
    DateTimeOffset ScannedAtUtc,
    IReadOnlyList<AnimationLibraryItem> Items)
{
    public const int CurrentSchemaVersion = 2;
}
