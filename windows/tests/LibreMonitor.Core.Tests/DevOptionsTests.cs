using LibreMonitor.Core;

namespace LibreMonitor.Core.Tests;

public class DevOptionsTests
{
    [Fact]
    public void NoFlags_DevModeIsOff() =>
        Assert.Equal(DevOptions.None, DevOptions.Parse(["app.exe"], allowed: true));

    [Fact]
    public void DevFlag_TurnsItOn_WhenAllowed()
    {
        var options = DevOptions.Parse(["app.exe", "--dev"], allowed: true);

        Assert.True(options.Enabled);
        Assert.Null(options.Scenario);
    }

    [Fact]
    public void SimulateFlag_ImpliesDevMode_AndPicksTheScenario()
    {
        var options = DevOptions.Parse(["app.exe", "--simulate", "2"], allowed: true);

        Assert.True(options.Enabled);
        Assert.Equal(2, options.Scenario);
    }

    [Theory]
    [InlineData("abc")]
    [InlineData("-1")]
    [InlineData("99")]
    public void InvalidScenario_IsIgnored_AndDoesNotEnableDevModeOnItsOwn(string value)
    {
        var options = DevOptions.Parse(["app.exe", "--simulate", value], allowed: true);

        Assert.False(options.Enabled);
        Assert.Null(options.Scenario);
    }

    [Fact]
    public void SimulateWithoutAValue_IsIgnored() =>
        Assert.Equal(DevOptions.None, DevOptions.Parse(["app.exe", "--simulate"], allowed: true));

    [Fact]
    public void Flags_AreCaseInsensitive() =>
        Assert.True(DevOptions.Parse(["app.exe", "--DEV"], allowed: true).Enabled);

    // The guarantee that matters: a published build passes allowed: false, so no flag can ever enable developer features.
    [Theory]
    [InlineData("--dev")]
    [InlineData("--simulate")]
    public void WhenNotAllowed_NothingEnablesIt(string flag)
    {
        var options = DevOptions.Parse(["app.exe", "--dev", flag, "0", "--simulate", "0"], allowed: false);

        Assert.Equal(DevOptions.None, options);
        Assert.False(options.Enabled);
        Assert.Null(options.Scenario);
    }
}
