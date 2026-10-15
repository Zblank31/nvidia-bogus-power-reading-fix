# Shortcuts for working on the repository (none of this is needed to use the fix).

.PHONY: tools check

# gpuload and sondeclk, the measurement tools (a C compiler is enough)
tools:
	$(MAKE) -C tools

# syntax-check every shell script, then run the simulated test bench of research/reload-trials.sh
check:
	@for f in scripts/*.sh tools/*.sh research/*.sh research/tests/*.sh; do bash -n "$$f" || exit 1; done
	@echo "shell syntax ok"
	@research/tests/run-sim.sh
