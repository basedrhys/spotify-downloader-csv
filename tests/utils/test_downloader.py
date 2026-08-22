"""
Tests for the downloader utils.
"""

from unittest.mock import patch

from spotdl.providers.audio import YouTubeMusic
from spotdl.utils.downloader import check_ytmusic_connection


def test_check_ytmusic_connection_uses_real_search_options():
    """
    The connection check must query YouTube Music the same way the download path
    does, i.e. with a `filter` set.

    An unfiltered search returns mostly artist/album/playlist cards, which
    `get_results` discards because they carry no `videoId`. That yields an empty
    list and a false "you are blocked by YouTube Music" verdict even though the
    API is perfectly reachable.
    """

    calls = []

    def fake_get_results(_self, _search_term, **kwargs):
        calls.append(kwargs)

        # Mimic the real API: unfiltered searches return nothing usable,
        # filtered ones return songs.
        return ["result"] if kwargs.get("filter") else []

    with patch.object(YouTubeMusic, "__init__", lambda self, *a, **k: None):
        with patch.object(YouTubeMusic, "get_results", fake_get_results):
            connected = check_ytmusic_connection()

    assert any(call.get("filter") for call in calls), (
        "connection check never passed a search filter, so it cannot tell a "
        f"block apart from a filtered-out result set (calls: {calls})"
    )
    assert connected is True
