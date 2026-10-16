using System.Globalization;
using LibreMonitor.Core;

namespace LibreMonitor.Core.Tests;

public class GlucoseUnitsTests
{
    private static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;

    [Theory]
    [InlineData(70, "3.9")]
    [InlineData(100, "5.5")]
    [InlineData(180, "10.0")]
    [InlineData(54, "3.0")]
    [InlineData(400, "22.2")]
    public void Mmol_IsOneDecimal(double mgPerDl, string expected) =>
        Assert.Equal(expected, GlucoseUnits.Format(mgPerDl, GlucoseUnit.MmolPerL, Invariant));

    [Theory]
    [InlineData(112, "112")]
    [InlineData(111.6, "112")]
    public void MgPerDl_IsWholeNumber(double mgPerDl, string expected) =>
        Assert.Equal(expected, GlucoseUnits.Format(mgPerDl, GlucoseUnit.MgPerDl, Invariant));

    [Fact]
    public void Format_UsesTheCallersDecimalSeparator() =>
        Assert.Equal("5,5", GlucoseUnits.Format(100, GlucoseUnit.MmolPerL, new CultureInfo("pt-PT")));

    [Fact]
    public void Labels_AreConventional()
    {
        Assert.Equal("mg/dL", GlucoseUnit.MgPerDl.Label());
        Assert.Equal("mmol/L", GlucoseUnit.MmolPerL.Label());
    }
}
