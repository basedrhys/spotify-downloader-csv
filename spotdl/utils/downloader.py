"""
Module for functions related to downloading songs.
"""

from spotdl.providers.audio import YouTubeMusic

__all__ = ["check_ytmusic_connection"]


def check_ytmusic_connection() -> bool:
    """
    Check if we can connect to YouTube Music API

    ### Returns
    - `True` if we can connect to YouTube Music API
    - `False` if we can't connect to YouTube Music API
    """

    # Check if we are getting results from YouTube Music.
    # Search the same way the download path does - an unfiltered search returns
    # mostly artist/album/playlist cards, which `get_results` discards because
    # they carry no `videoId`. That looks identical to being blocked.
    ytm = YouTubeMusic()
    for search_options in ytm.GET_RESULTS_OPTS:
        if len(ytm.get_results("a", **search_options)) > 0:
            return True

    return False
