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
	$(PY) -m susurro.doctor

run:
	$(PY) -m susurro
