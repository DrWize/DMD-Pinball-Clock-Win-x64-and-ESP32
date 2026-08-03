using System.Text.Json;

namespace DmdClock.App.Localization;

public sealed record LocalizationWarning(string Language, string Path, string Reason);

public static class LocalizationManager
{
    private const string EmbeddedEnglishResource = "DmdClock.App.Assets.I18n.en.json";
    private static Dictionary<string, string> _strings = [];

    public static IReadOnlyList<LocalizationWarning> Load(
        string language,
        string? translationDirectory = null)
    {
        var warnings = new List<LocalizationWarning>();
        _strings = ReadEmbeddedEnglish();
        translationDirectory ??= Path.Combine(AppContext.BaseDirectory, "i18n");

        OverlayExternal("en", translationDirectory, warnings);
        if (language != "en")
            OverlayExternal(language, translationDirectory, warnings);

        return warnings;
    }

    public static string Get(string key) => _strings.GetValueOrDefault(key, key);

    public static string? FindKey(string value) =>
        _strings.FirstOrDefault(pair => pair.Value == value).Key;

    private static Dictionary<string, string> ReadEmbeddedEnglish()
    {
        using var stream = typeof(LocalizationManager).Assembly
            .GetManifestResourceStream(EmbeddedEnglishResource)
            ?? throw new InvalidOperationException(
                $"Embedded English translations are missing: {EmbeddedEnglishResource}");

        return JsonSerializer.Deserialize<Dictionary<string, string>>(stream)
            ?? throw new InvalidOperationException("Embedded English translations are invalid.");
    }

    private static void OverlayExternal(
        string language,
        string translationDirectory,
        ICollection<LocalizationWarning> warnings)
    {
        var path = Path.Combine(translationDirectory, language + ".json");
        if (!File.Exists(path))
        {
            warnings.Add(new LocalizationWarning(language, path, "file is missing"));
            return;
        }

        try
        {
            var translations = JsonSerializer.Deserialize<Dictionary<string, string>>(
                File.ReadAllText(path));
            if (translations is null)
            {
                warnings.Add(new LocalizationWarning(language, path, "file contains no translation object"));
                return;
            }

            foreach (var pair in translations) _strings[pair.Key] = pair.Value;
        }
        catch (JsonException exception)
        {
            warnings.Add(new LocalizationWarning(language, path, $"invalid JSON: {exception.Message}"));
        }
        catch (IOException exception)
        {
            warnings.Add(new LocalizationWarning(language, path, $"could not be read: {exception.Message}"));
        }
        catch (UnauthorizedAccessException exception)
        {
            warnings.Add(new LocalizationWarning(language, path, $"access denied: {exception.Message}"));
        }
    }
}
