using DmdClock.App.Localization;

namespace DmdClock.Core.Tests.Localization;

public sealed class LocalizationManagerTests : IDisposable
{
    private readonly string _directory = Path.Combine(
        Path.GetTempPath(), $"dmdclock-i18n-tests-{Guid.NewGuid():N}");

    [Fact]
    public void Load_MissingExternalEnglish_UsesEmbeddedEnglishAndWarns()
    {
        var warnings = LocalizationManager.Load("en", _directory);

        var warning = Assert.Single(warnings);
        Assert.Equal("en", warning.Language);
        Assert.Contains("missing", warning.Reason, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("Show clock (T)", LocalizationManager.Get("showClock"));
        Assert.Equal("Hot-core glow", LocalizationManager.Get("hotCoreGlow"));
    }

    [Fact]
    public void Load_InvalidSelectedLanguage_UsesEnglishAndWarns()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(Path.Combine(_directory, "en.json"), "{\"showClock\":\"External English\"}");
        File.WriteAllText(Path.Combine(_directory, "sv.json"), "not-json");

        var warnings = LocalizationManager.Load("sv", _directory);

        var warning = Assert.Single(warnings);
        Assert.Equal("sv", warning.Language);
        Assert.Contains("invalid JSON", warning.Reason, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("External English", LocalizationManager.Get("showClock"));
        Assert.Equal("Swedish", LocalizationManager.Get("swedish"));
    }

    [Fact]
    public void Load_PartialSelectedLanguage_OverlaysEmbeddedEnglish()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(Path.Combine(_directory, "en.json"), "{}");
        File.WriteAllText(Path.Combine(_directory, "sv.json"), "{\"showClock\":\"Visa klockan\"}");

        var warnings = LocalizationManager.Load("sv", _directory);

        Assert.Empty(warnings);
        Assert.Equal("Visa klockan", LocalizationManager.Get("showClock"));
        Assert.Equal("English", LocalizationManager.Get("english"));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
