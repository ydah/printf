RUBY ?= ruby
CLANG ?= clang
CLANG_FIXTURE_SPECS := \
	2:samples/clang/optimized_smoke.c:samples/clang/optimized_smoke.ll \
	0:samples/clang/optimized_smoke.c:samples/clang/optimized_smoke_O0.ll \
	1:samples/clang/optimized_smoke.c:samples/clang/optimized_smoke_O1.ll \
	2:samples/clang/optimized_smoke.c:samples/clang/optimized_smoke_O2.ll \
	z:samples/clang/optimized_smoke.c:samples/clang/optimized_smoke_Oz.ll \
	0:samples/clang/branch_loop.c:samples/clang/branch_loop_O0.ll \
	2:samples/clang/branch_loop.c:samples/clang/branch_loop_O2.ll \
	0:samples/clang/struct_array.c:samples/clang/struct_array_O0.ll \
	2:samples/clang/struct_array.c:samples/clang/struct_array_O2.ll \
	0:samples/clang/pointer_alias.c:samples/clang/pointer_alias_O0.ll \
	2:samples/clang/pointer_alias.c:samples/clang/pointer_alias_O2.ll \
	0:samples/clang/memory_intrinsics.c:samples/clang/memory_intrinsics_O0.ll \
	2:samples/clang/memory_intrinsics.c:samples/clang/memory_intrinsics_O2.ll \
	0:samples/clang/printf_formats.c:samples/clang/printf_formats_O0.ll \
	2:samples/clang/printf_formats.c:samples/clang/printf_formats_O2.ll \
	0:samples/clang/internal_call.c:samples/clang/internal_call_O0.ll \
	2:samples/clang/internal_call.c:samples/clang/internal_call_O2.ll

.PHONY: test fixtures fixtures-check
test:
	$(RUBY) -Ilib:test test/all_test.rb

fixtures:
	@if command -v "$(CLANG)" >/dev/null 2>&1; then \
		for spec in $(CLANG_FIXTURE_SPECS); do \
			opt="$${spec%%:*}"; \
			rest="$${spec#*:}"; \
			source="$${rest%%:*}"; \
			fixture="$${rest#*:}"; \
			CLANG="$(CLANG)" $(RUBY) script/generate_clang_fixture.rb --opt="$$opt" "$$source" "$$fixture" || exit $$?; \
		done; \
	else \
		echo "skip fixtures: $(CLANG) not found"; \
	fi

fixtures-check:
	@if command -v "$(CLANG)" >/dev/null 2>&1; then \
		"$(CLANG)" --version | sed -n '1p'; \
		mkdir -p out/fixture-diagnostics; \
		status=0; \
		for spec in $(CLANG_FIXTURE_SPECS); do \
			opt="$${spec%%:*}"; \
			rest="$${spec#*:}"; \
			source="$${rest%%:*}"; \
			fixture="$${rest#*:}"; \
			report="out/fixture-diagnostics/$$(basename "$$fixture").stale.json"; \
			rm -f "$$report"; \
			CLANG="$(CLANG)" $(RUBY) script/generate_clang_fixture.rb --check --diagnostic-json="$$report" --opt="$$opt" "$$source" "$$fixture" || status=1; \
			$(RUBY) -Ilib bin/pfc llvm-capabilities --check "$$fixture" >/dev/null || status=1; \
		done; \
		exit $$status; \
	else \
		echo "skip fixtures-check: $(CLANG) not found"; \
	fi
