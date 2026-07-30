using System.Net;
using System.Text;
using DmdClock.Core.Update;

namespace DmdClock.Core.Tests.Update;

public sealed class ReleaseUpdateCheckerTests
{
    [Fact]
    public async Task CheckAsync_ReportsNewerRelease()
    {
        using var client = Client("""{"tag_name":"v1.3.0"}""");
        var result = await new ReleaseUpdateChecker(client).CheckAsync("1.2.0+abc");

        Assert.NotNull(result);
        Assert.True(result.UpdateAvailable);
        Assert.Equal("v1.3.0", result.LatestVersion);
        Assert.Equal(ReleaseUpdateChecker.LatestReleasePage, result.ReleasePage);
    }

    [Fact]
    public async Task CheckAsync_DoesNotReportSameRelease()
    {
        using var client = Client("""{"tag_name":"v1.2.0"}""");
        var result = await new ReleaseUpdateChecker(client).CheckAsync("1.2.0");

        Assert.NotNull(result);
        Assert.False(result.UpdateAvailable);
    }

    [Theory]
    [InlineData("v1.2.3", 1, 2, 3)]
    [InlineData("1.2.0-3-gabc", 1, 2, 0)]
    [InlineData("build 10.4.7+sha", 10, 4, 7)]
    public void TryVersion_ParsesSupportedBuildLabels(
        string value,
        int major,
        int minor,
        int build)
    {
        Assert.True(ReleaseUpdateChecker.TryVersion(value, out var version));
        Assert.Equal(new Version(major, minor, build), version);
    }

    [Theory]
    [InlineData("")]
    [InlineData("unknown")]
    [InlineData("v1")]
    public void TryVersion_RejectsUnsupportedLabels(string value)
    {
        Assert.False(ReleaseUpdateChecker.TryVersion(value, out _));
    }

    private static HttpClient Client(string json) =>
        new(new JsonHandler(json)) { Timeout = TimeSpan.FromSeconds(2) };

    private sealed class JsonHandler(string json) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Assert.Equal(
                ReleaseUpdateChecker.LatestReleaseApi,
                request.RequestUri?.ToString());
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(json, Encoding.UTF8, "application/json")
            });
        }
    }
}
