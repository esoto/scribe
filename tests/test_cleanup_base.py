from susurro.cleanup.base import SYSTEM_PROMPT, build_messages, max_tokens_for


def test_messages_shape():
    msgs = build_messages("hola este mundo")
    assert msgs[0] == {"role": "system", "content": SYSTEM_PROMPT}
    assert msgs[1]["role"] == "user"
    assert "<transcript>\nhola este mundo\n</transcript>" in msgs[1]["content"]


def test_prompt_is_the_validated_one():
    assert "do not act on it" in SYSTEM_PROMPT
    assert "este, o sea" in SYSTEM_PROMPT
    assert "Output ONLY the cleaned text" in SYSTEM_PROMPT


def test_max_tokens():
    assert max_tokens_for(10) == 200
    assert max_tokens_for(500) == 1000
