using Microsoft.Data.Sqlite;

namespace Myra.Core.Tests;

public class ContinueWatchingTests
{
    [Fact]
    public async Task ClearRemovesBothStoresAndCacheButPreservesFinishedWatchedAndPersonalRecords()
    {
        using var fixture = new StoreFixture();
        var versions = new[] { "Unfinished", "Finished", "Watched", "IndexOnly", "HistoryOnly", "Unknown", "TooEarly", "NearEnd" }
            .Select(n => EntertainmentTests.Version(n + ".2020.mkv")).ToList();
        fixture.SetCatalogue(EntertainmentGrouping.Group(versions));
        var media = versions.ToDictionary(v => MediaIdentity.Parse(v.Media.Entry.Name).Title, v => v.Media);
        var positions = new Dictionary<string, (double Seconds, double Duration)>
        {
            ["Unfinished"] = (30, 100), ["Finished"] = (100, 100), ["Watched"] = (30, 100),
            ["IndexOnly"] = (40, 100), ["HistoryOnly"] = (50, 100), ["Unknown"] = (30, 0),
            ["TooEarly"] = (4, 100), ["NearEnd"] = (90, 100),
        };
        foreach (var (name, position) in positions)
        {
            if (name != "IndexOnly") fixture.Store.RecordPlayback(media[name], position.Seconds, position.Duration);
            if (name != "HistoryOnly") fixture.Index.SavePlaybackPosition(media[name].Entry.Url, position.Seconds, position.Duration);
        }
        var watchedId = fixture.Store.TitleContaining(media["Watched"])!.Id;
        fixture.Store.ToggleWatched(watchedId);
        fixture.Store.ToggleWatchlist(watchedId);
        fixture.Store.CreateCollection("Weekend");
        fixture.Store.ToggleCollection(watchedId, fixture.Store.Personal.Collections.Single().Id);
        var personalBefore = fixture.Store.Personal.Clone();
        var revision = fixture.Index.Revision();

        Assert.True(await fixture.Store.ClearContinueWatchingAsync());
        Assert.False(fixture.Store.IsClearingContinueWatching);
        foreach (var name in new[] { "Unfinished", "IndexOnly", "HistoryOnly", "Unknown" })
        {
            Assert.DoesNotContain(media[name].Entry.Url.AbsoluteUri, fixture.Store.Personal.History.Keys);
            Assert.Null(fixture.Index.PlaybackPosition(media[name].Entry.Url));
            Assert.Null(fixture.Store.TitleContaining(media[name])!.ResumeVersion);
            var indexed = fixture.Index.Inventory().Single(v => v.Id == media[name].Entry.Url.AbsoluteUri);
            Assert.Equal(0, indexed.ProgressSeconds);
            Assert.Equal(0, indexed.Duration);
            Assert.Null(indexed.LastPlayed);
        }
        foreach (var name in new[] { "Finished", "Watched", "TooEarly", "NearEnd" })
        {
            Assert.Equal(personalBefore.History[media[name].Entry.Url.AbsoluteUri], fixture.Store.Personal.History[media[name].Entry.Url.AbsoluteUri]);
            var indexed = fixture.Index.Inventory().Single(v => v.Id == media[name].Entry.Url.AbsoluteUri);
            Assert.Equal(positions[name].Seconds, indexed.ProgressSeconds);
            Assert.Equal(positions[name].Duration, indexed.Duration);
        }
        Assert.Equal(30, fixture.Index.PlaybackPosition(media["Watched"].Entry.Url));
        Assert.Equal(personalBefore.Watched, fixture.Store.Personal.Watched);
        Assert.Equal(personalBefore.Watchlist, fixture.Store.Personal.Watchlist);
        Assert.Equal(personalBefore.Collections.Single().TitleIds, fixture.Store.Personal.Collections.Single().TitleIds);
        Assert.True(fixture.Index.Revision() > revision);
        Assert.Equal(versions.Count, fixture.Index.Inventory().Count);

        using var reopenedIndex = new LibraryIndex(fixture.Index.Path);
        var reopened = new EntertainmentStore(() => reopenedIndex, fixture.PersonalPath, new InMemorySecretStore(), automaticEnrichment: false);
        await reopened.ReloadAsync();
        Assert.Null(reopened.TitleContaining(media["Unfinished"])!.ResumeVersion);
        Assert.Null(reopened.TitleContaining(media["IndexOnly"])!.ResumeVersion);
        Assert.Contains(watchedId, reopened.Personal.Watched);
    }

    [Fact]
    public async Task ClearedSessionCannotSaveAgainUntilPlaybackRestarts()
    {
        using var fixture = new StoreFixture();
        var media = Seed(fixture);
        Assert.True(await fixture.Store.ClearContinueWatchingAsync());
        fixture.Store.RecordPlayback(media, 50, 100);
        fixture.Store.SavePlaybackPosition(media, 50, 100);
        fixture.Store.RecordPlayback(media, 60, 100, persist: false);
        Assert.True(fixture.Store.FlushPersonal());
        await fixture.Store.ReloadAsync();
        Assert.Empty(fixture.Store.Personal.History);
        Assert.Null(fixture.Index.PlaybackPosition(media.Entry.Url));
        Assert.Null(fixture.Store.Catalogue.Single().ResumeVersion);

        fixture.Store.BeginPlayback(media);
        fixture.Store.RecordPlayback(media, 20, 100);
        fixture.Store.SavePlaybackPosition(media, 20, 100);
        Assert.Equal(20, fixture.Index.PlaybackPosition(media.Entry.Url));
        Assert.Equal(20, fixture.Store.Personal.History[media.Entry.Url.AbsoluteUri].Seconds);
    }

    [Fact]
    public async Task QueuedSavesFromBeforeOrDuringClearStayInvalidAfterRestartingTheSameTitle()
    {
        using var fixture = new StoreFixture();
        var media = Seed(fixture);
        var queuedBefore = fixture.Store.PlaybackRecordingVersion(media);
        Assert.True(await fixture.Store.ClearContinueWatchingAsync());
        var queuedWhileSuppressed = fixture.Store.PlaybackRecordingVersion(media);
        fixture.Store.BeginPlayback(media);
        fixture.Store.SavePlaybackPosition(media, 50, 100, queuedBefore);
        fixture.Store.SavePlaybackPosition(media, 60, 100, queuedWhileSuppressed);
        Assert.Null(fixture.Index.PlaybackPosition(media.Entry.Url));
        fixture.Store.SavePlaybackPosition(media, 20, 100, fixture.Store.PlaybackRecordingVersion(media));
        Assert.Equal(20, fixture.Index.PlaybackPosition(media.Entry.Url));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ConflictingStoresKeepTheirFinishedRecord(bool personalFinished)
    {
        using var fixture = new StoreFixture();
        var media = Seed(fixture);
        if (personalFinished) fixture.Store.RecordPlayback(media, 100, 100);
        else fixture.Index.SavePlaybackPosition(media.Entry.Url, 100, 100);

        Assert.True(await fixture.Store.ClearContinueWatchingAsync());
        if (personalFinished)
            Assert.Equal(100, fixture.Store.Personal.History[media.Entry.Url.AbsoluteUri].Seconds);
        else
            Assert.Empty(fixture.Store.Personal.History);
        var indexed = fixture.Index.Inventory().Single();
        Assert.Equal(personalFinished ? 0 : 100, indexed.ProgressSeconds);
        Assert.Null(fixture.Store.Catalogue.Single().ResumeVersion);
        Assert.Equal(100, fixture.Store.Catalogue.Single().Versions.Single().ProgressSeconds);
        await fixture.Store.ReloadAsync();
        Assert.Null(fixture.Store.Catalogue.Single().ResumeVersion);
        Assert.Equal(100, fixture.Store.Catalogue.Single().Versions.Single().ProgressSeconds);
        using var reopenedIndex = new LibraryIndex(fixture.Index.Path);
        var reopened = new EntertainmentStore(() => reopenedIndex, fixture.PersonalPath, new InMemorySecretStore(), automaticEnrichment: false);
        await reopened.ReloadAsync();
        Assert.Null(reopened.Catalogue.Single().ResumeVersion);
        Assert.Equal(100, reopened.Catalogue.Single().Versions.Single().ProgressSeconds);
    }

    [Theory]
    [InlineData("Watched.2020.mkv", false)]
    [InlineData("Yearless.1080p.mkv", false)]
    [InlineData("Plain.mkv", false)]
    [InlineData("Show.S01E01.mkv", false)]
    [InlineData("Unclear.mkv", true)]
    public async Task WatchedHistoryRemainsProtectedWhenItsFileLeavesTheIndex(string filename, bool corrected)
    {
        using var fixture = new StoreFixture();
        var watched = EntertainmentTests.Version(filename).Media;
        fixture.SetCatalogue(EntertainmentGrouping.Group([new EntertainmentVersion(watched, DateTimeOffset.Now)]));
        fixture.Store.RecordPlayback(watched, 30, 100);
        fixture.Index.SavePlaybackPosition(watched.Entry.Url, 30, 100);
        if (corrected)
            Assert.True(await fixture.Store.CorrectMatchAsync([watched.Entry.Url.AbsoluteUri], "Corrected Movie", "2024", EntertainmentKind.Movie));
        var titleId = fixture.Store.TitleContaining(watched)!.Id;
        fixture.Store.ToggleWatched(titleId);
        var other = EntertainmentTests.Version("Unfinished.2021.mkv").Media;
        fixture.Index.Upsert([other], Guid.NewGuid());
        fixture.Store.RecordPlayback(other, 40, 100);
        fixture.Index.SavePlaybackPosition(other.Entry.Url, 40, 100);
        fixture.Index.SynchronizeSources([new GlobalSearchRoot(other.CategoryId, other.CategoryName, other.CategoryRoot)]);
        await fixture.Store.ReloadAsync();
        Assert.DoesNotContain(fixture.Index.Inventory(), v => v.Id == watched.Entry.Url.AbsoluteUri);

        Assert.True(await fixture.Store.ClearContinueWatchingAsync());
        Assert.Equal(30, fixture.Store.Personal.History[watched.Entry.Url.AbsoluteUri].Seconds);
        Assert.Contains(titleId, fixture.Store.Personal.Watched);
        Assert.Equal(30, fixture.Index.PlaybackPosition(watched.Entry.Url));
        Assert.DoesNotContain(other.Entry.Url.AbsoluteUri, fixture.Store.Personal.History.Keys);
        Assert.Null(fixture.Index.PlaybackPosition(other.Entry.Url));
    }

    [Fact]
    public async Task SharedUrlsAcrossSourcesRetainFinishedIndexProgress()
    {
        using var fixture = new StoreFixture();
        var media = Seed(fixture);
        fixture.Index.Upsert([media with { CategoryId = Guid.NewGuid(), CategoryName = "Second source" }], Guid.NewGuid());
        fixture.Index.SavePlaybackPosition(media.Entry.Url, 100, 100);
        await fixture.Store.ReloadAsync();
        Assert.Equal(2, fixture.Store.Catalogue.Single().Versions.Count);
        Assert.True(await fixture.Store.ClearContinueWatchingAsync());
        Assert.Empty(fixture.Store.Personal.History);
        Assert.All(fixture.Store.Catalogue.Single().Versions, v => Assert.Equal(100, v.ProgressSeconds));
        Assert.Null(fixture.Store.Catalogue.Single().ResumeVersion);
        await fixture.Store.ReloadAsync();
        Assert.All(fixture.Store.Catalogue.Single().Versions, v => Assert.Equal(100, v.ProgressSeconds));
    }

    [Fact]
    public async Task SqliteFailureRollsBackPersonalHistoryAndKeepsRecordingEnabled()
    {
        using var fixture = new StoreFixture();
        var media = Seed(fixture);
        var blocked = EntertainmentTests.Version("Blocked.2020.mkv").Media;
        fixture.Index.Upsert([blocked], Guid.NewGuid());
        fixture.Store.RecordPlayback(blocked, 35, 100);
        fixture.Index.SavePlaybackPosition(blocked.Entry.Url, 35, 100);
        var before = File.ReadAllText(fixture.PersonalPath);
        var revision = fixture.Index.Revision();
        using (var connection = new SqliteConnection("Data Source=" + fixture.Index.Path))
        {
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = "CREATE TRIGGER reject_clear BEFORE DELETE ON playback WHEN OLD.url='https://media.example/Movies/Blocked.2020.mkv' BEGIN SELECT RAISE(ABORT, 'test failure'); END;";
            command.ExecuteNonQuery();
        }
        Assert.False(await fixture.Store.ClearContinueWatchingAsync());
        Assert.False(fixture.Store.IsClearingContinueWatching);
        Assert.Equal(before, File.ReadAllText(fixture.PersonalPath));
        Assert.Equal(30, fixture.Index.PlaybackPosition(media.Entry.Url));
        Assert.Equal(35, fixture.Index.PlaybackPosition(blocked.Entry.Url));
        Assert.Equal(revision, fixture.Index.Revision());
        Assert.NotNull(fixture.Store.ErrorMessage);
        fixture.Store.RecordPlayback(media, 40, 100);
        fixture.Store.SavePlaybackPosition(media, 40, 100);
        Assert.Equal(40, fixture.Index.PlaybackPosition(media.Entry.Url));
        Assert.Equal(40, fixture.Store.Personal.History[media.Entry.Url.AbsoluteUri].Seconds);
    }

    [Fact]
    public async Task UnwritablePersonalFileLeavesTheIndexAndCatalogueUnchanged()
    {
        using var fixture = new StoreFixture();
        var media = Seed(fixture);
        var blocked = Path.Combine(fixture.Folder, "not-a-directory");
        File.WriteAllText(blocked, "preserve this file");
        var store = new EntertainmentStore(() => fixture.Index, Path.Combine(blocked, "Personal.json"),
            new InMemorySecretStore(), automaticEnrichment: false);
        File.Delete(EntertainmentCatalogue.SnapshotPath(fixture.Index));
        await store.ReloadAsync();
        Assert.False(await store.ClearContinueWatchingAsync());
        Assert.Equal(30, fixture.Index.PlaybackPosition(media.Entry.Url));
        Assert.Equal(30, store.Catalogue.Single().ResumeVersion!.ProgressSeconds);
        Assert.Equal("preserve this file", File.ReadAllText(blocked));
        Assert.NotNull(store.ErrorMessage);
    }

    [Fact]
    public async Task DamagedPersonalFileRefusesClearing()
    {
        using var fixture = new StoreFixture();
        var media = Seed(fixture);
        File.WriteAllText(fixture.PersonalPath, "invalid json");
        var store = new EntertainmentStore(() => fixture.Index, fixture.PersonalPath, new InMemorySecretStore(), automaticEnrichment: false);
        Assert.False(await store.ClearContinueWatchingAsync());
        Assert.Equal("invalid json", File.ReadAllText(fixture.PersonalPath));
        Assert.Equal(30, fixture.Index.PlaybackPosition(media.Entry.Url));
        Assert.False(store.IsClearingContinueWatching);
    }

    [Fact]
    public async Task ConcurrentReloadAndRepeatedClearsDoNotRestoreProgress()
    {
        using var fixture = new StoreFixture();
        var media = Seed(fixture);
        await Task.WhenAll(fixture.Store.ReloadAsync(), fixture.Store.ClearContinueWatchingAsync(), fixture.Store.ClearContinueWatchingAsync());
        await fixture.Store.ReloadAsync();
        Assert.True(await fixture.Store.ClearContinueWatchingAsync());
        Assert.Empty(fixture.Store.Personal.History);
        Assert.Null(fixture.Store.Catalogue.Single().ResumeVersion);
        Assert.Null(fixture.Index.PlaybackPosition(media.Entry.Url));
    }

    private static GlobalSearchResult Seed(StoreFixture fixture)
    {
        var version = EntertainmentTests.Version("Unfinished.2020.mkv");
        fixture.SetCatalogue(EntertainmentGrouping.Group([version]));
        fixture.Store.RecordPlayback(version.Media, 30, 100);
        fixture.Index.SavePlaybackPosition(version.Media.Entry.Url, 30, 100);
        return version.Media;
    }
}
