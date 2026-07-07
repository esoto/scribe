PY := .venv/bin/python

venv:
	python3 -m venv .venv && $(PY) -m pip install -q -e '.[dev]'

test:
	$(PY) -m pytest -q -m 'not models'

cov:
	$(PY) -m pytest -q -m 'not models' --cov --cov-report=term-missing

test-models:
	$(PY) -m pytest -q -m models tests_models

eval:
	$(PY) tests_models/run_eval.py

doctor:
	$(PY) -m scribe.doctor

run:
	$(PY) -m scribe

probe:
	$(PY) scripts/probe_hotkey.py

AGENT := $(HOME)/Library/LaunchAgents/dev.esoto.scribe.plist
STATE := $(HOME)/.local/state/scribe

install-agent:
	mkdir -p $(STATE) $(HOME)/Library/LaunchAgents
	sed -e 's|__PYTHON__|$(abspath .venv/bin/python)|' -e 's|__STATE__|$(STATE)|' \
	  resources/dev.esoto.scribe.plist.template > $(AGENT)
	launchctl bootstrap gui/$$(id -u) $(AGENT) || launchctl kickstart -k gui/$$(id -u)/dev.esoto.scribe

uninstall-agent:
	launchctl bootout gui/$$(id -u)/dev.esoto.scribe || true
	rm -f $(AGENT)
