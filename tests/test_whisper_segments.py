from scribe.stt.whisper import join_segments


def test_joins_and_filters_no_speech():
    segs = [
        {"text": " Hola.", "no_speech_prob": 0.01},
        {"text": " Thank you.", "no_speech_prob": 0.93},
        {"text": " ¿Qué tal?", "no_speech_prob": 0.2},
    ]
    assert join_segments(segs) == "Hola. ¿Qué tal?"


def test_empty_segments():
    assert join_segments([]) == ""


def test_missing_prob_key_kept():
    assert join_segments([{"text": " hi"}]) == "hi"


def test_blank_segments_dropped():
    assert join_segments([{"text": "   ", "no_speech_prob": 0.0}]) == ""
